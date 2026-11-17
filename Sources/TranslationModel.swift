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
    @Published private(set) var sourceURL: URL?
    @Published private(set) var translatedURL: URL?
    @Published private(set) var bilingualURL: URL?
    @Published private(set) var isTranslating = false
    @Published private(set) var progress = 0.0
    @Published private(set) var status = "拖入英文论文以开始"
    @Published var errorMessage: String?

    private let engine: TranslationEngine
    private let jobsRoot: URL?
    private var runningJob: (id: UUID, task: Process)?
    private var sourceAccess: URL?
    private var chooserOpen = false

    init(engine: TranslationEngine = .bundled, jobsRoot: URL? = nil) {
        self.engine = engine
        self.jobsRoot = jobsRoot
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
        translatedURL = nil
        bilingualURL = nil
        errorMessage = nil
        status = "准备翻译"
        progress = 0
        isTranslating = true

        let id = UUID()
        do {
            let output = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            ).appendingPathComponent("PaperReader/Translations", isDirectory: true)
            let job = (jobsRoot ?? output).appendingPathComponent(id.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(
                at: job, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
            try startEngine(id: id, input: url, output: job)
        } catch {
            isTranslating = false
            status = "翻译无法启动"
            errorMessage = "无法启动本机翻译引擎，请重新打开 App 后再试。"
        }
    }

    func cancelTranslation() {
        guard let job = runningJob else { return }
        runningJob = nil
        if job.task.isRunning { job.task.terminate() }
        isTranslating = false
        status = "翻译已取消"
    }

    func exportBilingual() {
        guard let sourceURL, canExport, !chooserOpen else { return }
        chooserOpen = true
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = sourceURL.deletingPathExtension().lastPathComponent + ".zh-CN.dual.pdf"
        panel.prompt = "导出"
        panel.begin { [weak self] result in
            guard let self else { return }
            self.chooserOpen = false
            guard result == .OK, let url = panel.url else { return }
            do {
                try self.exportBilingual(to: url)
                self.status = "已导出双语 PDF"
            } catch {
                self.errorMessage = "无法写入所选位置，请换一个导出位置后再试。"
            }
        }
    }

    func exportBilingual(to destination: URL) throws {
        guard let bilingualURL else { throw CocoaError(.fileNoSuchFile) }
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
        runningJob = (id, task)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let reader = events.fileHandleForReading
            defer { try? reader.close() }
            var pending = Data()
            while let part = try? reader.read(upToCount: 16_384), !part.isEmpty {
                pending.append(part)
                while let newline = pending.firstIndex(of: 10) {
                    let line = Data(pending[..<newline])
                    pending.removeSubrange(...newline)
                    if let event = try? JSONDecoder().decode(EngineEvent.self, from: line) {
                        DispatchQueue.main.async { [weak self] in
                            self?.receive(event, jobID: id, output: output)
                        }
                    }
                }
            }
            task.waitUntilExit()
            DispatchQueue.main.async { [weak self] in self?.engineExited(jobID: id) }
        }
    }

    private func receive(_ event: EngineEvent, jobID: UUID, output: URL) {
        guard runningJob?.id == jobID else { return }
        switch event.type {
        case "progress":
            progress = max(progress, min(1, event.progress ?? 0))
            if let stage = event.stage, !stage.isEmpty { status = stage }
        case "result":
            guard let mono = outputFile(event.mono_path, in: output),
                  let dual = outputFile(event.dual_path, in: output) else {
                errorMessage = "翻译结束，但没有生成可用的中文和双语 PDF。"
                return
            }
            translatedURL = mono
            bilingualURL = dual
            progress = 1
            status = "翻译完成"
            isTranslating = false
        case "error":
            errorMessage = event.message ?? "翻译失败。"
            status = "翻译失败"
            isTranslating = false
        default:
            break
        }
    }

    private func outputFile(_ path: String?, in output: URL) -> URL? {
        guard let path else { return nil }
        let file = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let folder = output.resolvingSymlinksInPath().path
        return file.path.hasPrefix(folder + "/") && FileManager.default.isReadableFile(atPath: file.path) ? file : nil
    }

    private func engineExited(jobID: UUID) {
        guard runningJob?.id == jobID else { return }
        runningJob = nil
        isTranslating = false
        if translatedURL == nil {
            status = "翻译失败"
            if errorMessage == nil { errorMessage = "翻译任务提前退出，请检查网络后重新打开 PDF。" }
        }
    }
}
