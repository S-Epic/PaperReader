import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

struct TranslationEngine {
    let python: URL
    let bridge: URL
    var runtime: URL? = nil

    static var bundled: TranslationEngine {
        let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        let runtime = resources.appendingPathComponent("Engine", isDirectory: true)
        return TranslationEngine(
            python: runtime.appendingPathComponent("python/bin/python3.12"),
            bridge: runtime.appendingPathComponent("engine_bridge.py"),
            runtime: runtime
        )
    }

    func process(source: URL, output: URL) -> Process {
        let task = Process()
        task.executableURL = python
        task.arguments = ["-u", bridge.path, source.path, output.path]
        if let runtime {
            var environment = ProcessInfo.processInfo.environment
            environment["PYTHONPATH"] = runtime.appendingPathComponent("site-packages").path
            environment.removeValue(forKey: "PYTHONHOME")
            environment["PYTHONNOUSERSITE"] = "1"
            environment["PYTHONDONTWRITEBYTECODE"] = "1"
            task.environment = environment
        }
        return task
    }
}

private struct EngineEvent: Decodable {
    let type: String
    let progress: Double?
    let stage: String?
    let mono_path: String?
    let dual_path: String?
    let message: String?
}

@MainActor
final class TranslationModel: ObservableObject {
    private struct ActiveJob {
        let id: UUID
        let documentName: String
        let pageCount: Int
        var task: Process?
    }

    @Published private(set) var sourceURL: URL?
    @Published private(set) var translatedURL: URL?
    @Published private(set) var bilingualURL: URL?
    @Published private(set) var documentName: String?
    @Published private(set) var history: [TranslationHistoryEntry]
    @Published private(set) var activeHistoryID: UUID?
    @Published private(set) var isTranslating = false
    @Published private(set) var progress = 0.0
    @Published private(set) var status = "拖入英文论文以开始"
    @Published var errorMessage: String?

    private let engine: TranslationEngine
    private let historyStore: TranslationHistoryStore
    private var runningJob: ActiveJob?
    private var sourceAccess: URL?
    private var chooserOpen = false

    init(engine: TranslationEngine = .bundled, jobsRoot: URL? = nil) {
        self.engine = engine
        let root = jobsRoot ?? URL.homeDirectory
            .appendingPathComponent("Library/Application Support/PaperReader/Translations", isDirectory: true)
        let store = TranslationHistoryStore(root: root)
        self.historyStore = store
        self.history = store.entries()
    }

    var canExport: Bool { bilingualURL != nil }

    func openDocument() {
        guard !chooserOpen else { return }
        chooserOpen = true
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "打开"
        panel.begin { [weak self] response in
            guard let self else { return }
            self.chooserOpen = false
            if response == .OK, let url = panel.url { self.importPDF(url) }
        }
    }

    func importPDF(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        guard url.isFileURL,
              url.pathExtension.caseInsensitiveCompare("pdf") == .orderedSame,
              let document = PDFDocument(url: url), !document.isLocked, document.pageCount > 0 else {
            if scoped { url.stopAccessingSecurityScopedResource() }
            errorMessage = "无法打开此文件。请选择未加密的 PDF。"
            return
        }

        cancelTranslation()
        sourceAccess?.stopAccessingSecurityScopedResource()
        sourceAccess = scoped ? url : nil
        sourceURL = url
        documentName = url.lastPathComponent
        translatedURL = nil
        bilingualURL = nil
        activeHistoryID = nil
        errorMessage = nil
        status = "准备翻译"
        progress = 0
        isTranslating = true

        let id = UUID()
        runningJob = ActiveJob(id: id, documentName: url.lastPathComponent, pageCount: document.pageCount)
        let store = historyStore
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let input = try store.prepare(id: id, source: url)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.runningJob?.id == id else {
                        store.discardIncomplete(id: id)
                        return
                    }
                    do {
                        try self.startEngine(id: id, input: input, output: store.directory(for: id))
                    } catch {
                        self.failJob(id: id, message: "无法启动本机翻译引擎，请重新打开 App 后再试。")
                    }
                }
            } catch {
                store.discardIncomplete(id: id)
                DispatchQueue.main.async { [weak self] in
                    self?.failJob(id: id, message: "无法保存原文副本，请检查磁盘空间和文件访问权限。")
                }
            }
        }
    }

    func cancelTranslation() {
        guard let job = runningJob else { return }
        runningJob = nil
        if let task = job.task, task.isRunning { task.terminate() }
        isTranslating = false
        status = "翻译已取消"
    }

    func openHistory(_ entry: TranslationHistoryEntry) {
        guard runningJob == nil, history.contains(where: { $0.id == entry.id }) else { return }
        do {
            let documents = try historyStore.documents(for: entry)
            guard [documents.source, documents.translated, documents.bilingual].allSatisfy({ url in
                guard let pdf = PDFDocument(url: url), !pdf.isLocked else { return false }
                return pdf.pageCount == entry.pageCount
            }) else { throw CocoaError(.fileReadCorruptFile) }

            sourceAccess?.stopAccessingSecurityScopedResource()
            sourceAccess = nil
            documentName = entry.documentName
            sourceURL = documents.source
            translatedURL = documents.translated
            bilingualURL = documents.bilingual
            activeHistoryID = entry.id
            progress = 1
            status = "已从历史记录打开"
            errorMessage = nil
        } catch {
            errorMessage = "无法打开此记录，保存的 PDF 可能已被移动或损坏。"
            history = historyStore.entries()
        }
    }

    func exportBilingual() {
        guard let documentName, let exportSource = bilingualURL, !chooserOpen else { return }
        chooserOpen = true
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (documentName as NSString).deletingPathExtension + ".zh-CN.dual.pdf"
        panel.prompt = "导出"
        panel.begin { [weak self] result in
            guard let self else { return }
            self.chooserOpen = false
            guard result == .OK, let url = panel.url else { return }
            do {
                try self.copyBilingual(from: exportSource, to: url)
                self.status = "已导出双语 PDF"
            } catch {
                self.errorMessage = "无法写入所选位置，请换一个导出位置后再试。"
            }
        }
    }

    func exportBilingual(to destination: URL) throws {
        guard let bilingualURL else { throw CocoaError(.fileNoSuchFile) }
        try copyBilingual(from: bilingualURL, to: destination)
    }

    private func copyBilingual(from bilingualURL: URL, to destination: URL) throws {
        if bilingualURL.standardizedFileURL == destination.standardizedFileURL { return }
        let destinationAccess = destination.startAccessingSecurityScopedResource()
        defer { if destinationAccess { destination.stopAccessingSecurityScopedResource() } }
        let files = FileManager.default
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".paper-reader-" + UUID().uuidString)
        defer { try? files.removeItem(at: staging) }
        try files.copyItem(at: bilingualURL, to: staging)
        if files.fileExists(atPath: destination.path) {
            _ = try files.replaceItemAt(destination, withItemAt: staging)
        } else {
            try files.moveItem(at: staging, to: destination)
        }
    }

    private func startEngine(id: UUID, input: URL, output: URL) throws {
        let task = engine.process(source: input, output: output)
        let events = Pipe()
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = events
        task.standardError = FileHandle.nullDevice
        try task.run()
        runningJob?.task = task

        let store = historyStore
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let reader = events.fileHandleForReading
            defer { try? reader.close() }
            var pending = Data()
            var terminalEvent: EngineEvent?
            while let part = try? reader.read(upToCount: 16_384), !part.isEmpty {
                pending.append(part)
                while let newline = pending.firstIndex(of: 10) {
                    let line = Data(pending[..<newline])
                    pending.removeSubrange(...newline)
                    if let event = try? JSONDecoder().decode(EngineEvent.self, from: line) {
                        if event.type == "result" || event.type == "error" {
                            terminalEvent = event
                        } else if event.type == "progress" {
                            DispatchQueue.main.async { [weak self] in
                                self?.updateProgress(event, jobID: id)
                            }
                        }
                    }
                }
            }
            task.waitUntilExit()
            let result = terminalEvent
            let exitStatus = task.terminationStatus
            DispatchQueue.main.async { [weak self] in
                guard let self, self.runningJob?.id == id else {
                    store.discardIncomplete(id: id)
                    return
                }
                self.finishEngine(jobID: id, output: output, result: result, exitStatus: exitStatus)
            }
        }
    }

    private func updateProgress(_ event: EngineEvent, jobID: UUID) {
        guard runningJob?.id == jobID else { return }
        progress = max(progress, min(1, event.progress ?? 0))
        if let stage = event.stage, !stage.isEmpty { status = stage }
    }

    private func finishEngine(jobID: UUID, output: URL, result: EngineEvent?, exitStatus: Int32) {
        guard let job = runningJob, job.id == jobID else { return }
        guard exitStatus == 0, result?.type == "result",
              let mono = outputFile(result?.mono_path, in: output),
              let dual = outputFile(result?.dual_path, in: output) else {
            failJob(id: jobID, message: result?.message ?? "翻译未完成，请检查网络后重新打开 PDF。")
            return
        }

        runningJob = nil
        translatedURL = mono
        bilingualURL = dual
        progress = 1
        status = "翻译完成"
        isTranslating = false
        do {
            try historyStore.record(
                id: jobID, documentName: job.documentName, pageCount: job.pageCount,
                translated: mono, bilingual: dual
            )
            history = historyStore.entries()
            activeHistoryID = jobID
        } catch {
            errorMessage = "译文已就绪并可导出，但本次未能保存到翻译历史。"
        }
    }

    private func outputFile(_ path: String?, in output: URL) -> URL? {
        guard let path else { return nil }
        let file = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let folder = output.resolvingSymlinksInPath().path
        return file.path.hasPrefix(folder + "/") && FileManager.default.isReadableFile(atPath: file.path) ? file : nil
    }

    private func failJob(id: UUID, message: String) {
        guard runningJob?.id == id else { return }
        runningJob = nil
        isTranslating = false
        historyStore.discardIncomplete(id: id)
        status = "翻译失败"
        errorMessage = message
    }
}
