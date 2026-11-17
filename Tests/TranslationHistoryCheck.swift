import Foundation
import PDFKit

private struct HistoryCheckFailure: LocalizedError {
    let errorDescription: String?
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw HistoryCheckFailure(errorDescription: message) }
}

@MainActor
private func waitFor(_ message: String, until condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !condition() {
        try require(ContinuousClock.now < deadline, message)
        try await Task.sleep(for: .milliseconds(20))
    }
}

private let documentName = "翻译历史 RSIHub.pdf"
private let bash = URL(fileURLWithPath: "/bin/bash")

@MainActor
private func reopenedHistory(in scratch: URL, entryID: UUID) async throws {
    let model = TranslationModel(
        engine: TranslationEngine(python: bash, bridge: scratch.appendingPathComponent("unexpected.sh")),
        jobsRoot: scratch.appendingPathComponent("history")
    )
    try require(model.history.map(\.id) == [entryID], "A fresh process should load only the completed record")
    guard let entry = model.history.first else {
        throw HistoryCheckFailure(errorDescription: "No completed translation in a fresh process")
    }
    let files = FileManager.default
    let original = scratch.appendingPathComponent("moved-original.pdf")
    let mono = scratch.appendingPathComponent("fixture-mono.pdf")
    let dual = scratch.appendingPathComponent("fixture-dual.pdf")
    try require(!files.fileExists(atPath: scratch.appendingPathComponent(documentName).path), "Original should have been moved")
    try require(entry.documentName == documentName, "Preserve the original filename in history")
    try require(entry.pageCount == PDFDocument(url: original)?.pageCount, "Store the source page count")

    model.openHistory(entry)
    try require(model.activeHistoryID == entryID, "Reopening should activate the saved translation")
    try require(model.documentName == documentName, "Reopened document should display the original filename")
    try require(!model.isTranslating && model.canExport, "Reopening should immediately enable bilingual export")
    guard let archived = model.sourceURL, let translated = model.translatedURL else {
        throw HistoryCheckFailure(errorDescription: "Reopening did not load both reading panes")
    }
    try require(files.contentsEqual(atPath: original.path, andPath: archived.path), "Saved source must survive moving the original")
    try require(files.contentsEqual(atPath: mono.path, andPath: translated.path), "Reopening should use the saved Chinese PDF")
    let exported = scratch.appendingPathComponent("reopened-dual.pdf")
    try model.exportBilingual(to: exported)
    try require(files.contentsEqual(atPath: dual.path, andPath: exported.path), "Export should reuse the saved bilingual PDF")
    try require(!files.fileExists(atPath: scratch.appendingPathComponent("unexpected-call").path), "Reopening must not call a translation engine")
    print("PASS fresh process: reopened both panes and exported the same bilingual PDF after the original moved")
}

@MainActor
private func runHistoryCheck(source: URL, mono: URL, dual: URL) async throws {
    let files = FileManager.default
    let scratch = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        .appendingPathComponent("paperreader-history-" + UUID().uuidString, isDirectory: true)
    try files.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? files.removeItem(at: scratch) }

    let localSource = scratch.appendingPathComponent(documentName)
    try files.copyItem(at: source, to: localSource)
    try files.copyItem(at: mono, to: scratch.appendingPathComponent("fixture-mono.pdf"))
    try files.copyItem(at: dual, to: scratch.appendingPathComponent("fixture-dual.pdf"))

    let resultScript = """
    dir="${0%/*}"
    cp "$dir/fixture-mono.pdf" "$2/mono.pdf"
    cp "$dir/fixture-dual.pdf" "$2/dual.pdf"
    printf '{"type":"result","mono_path":"%s/mono.pdf","dual_path":"%s/dual.pdf"}\n' "$2" "$2"
    """
    let scripts = [
        "success": """
        set -e
        printf '{"type":"progress","progress":0.25,"stage":"fixture"}\n'
        sleep 0.2
        """ + "\n" + resultScript,
        "fail": """
        printf '{"type":"error","message":"fixture failure"}\n'
        exit 1
        """,
        "cancel": "set -e\ntrap 'exit 0' TERM\n" + resultScript + "\n" + """
        : > "${0%/*}/result-sent"
        sleep 0.8
        """,
        "unexpected": """
        : > "${0%/*}/unexpected-call"
        exit 1
        """,
    ]
    let history = scratch.appendingPathComponent("history")
    for (name, body) in scripts {
        try body.write(to: scratch.appendingPathComponent("\(name).sh"), atomically: true, encoding: .utf8)
    }
    func model(using fixture: String) -> TranslationModel {
        TranslationModel(
            engine: TranslationEngine(python: bash, bridge: scratch.appendingPathComponent("\(fixture).sh")),
            jobsRoot: history
        )
    }

    let successful = model(using: "success")
    successful.importPDF(localSource)
    try require(successful.isTranslating && successful.sourceURL != nil, "Original should be readable while translation runs")
    try require(successful.history.isEmpty, "In-progress translation must not appear in history")
    try await waitFor("Translation fixture did not complete") { !successful.isTranslating }
    try require(successful.errorMessage == nil, successful.errorMessage ?? "Translation unexpectedly failed")
    guard successful.history.count == 1, let entry = successful.history.first else {
        throw HistoryCheckFailure(errorDescription: "Successful translation must create exactly one history record")
    }
    try require(entry.completedAt <= Date(), "History should record a completion date")
    try files.moveItem(at: localSource, to: scratch.appendingPathComponent("moved-original.pdf"))
    print("PASS completed job: saved a persistent record and a local copy of the source")

    let movedSource = scratch.appendingPathComponent("moved-original.pdf")
    let failed = model(using: "fail")
    failed.importPDF(movedSource)
    try await waitFor("Failed fixture did not finish") { !failed.isTranslating }
    try require(failed.errorMessage != nil && failed.history.map(\.id) == [entry.id], "Failed job must leave history unchanged")

    let cancelled = model(using: "cancel")
    cancelled.importPDF(movedSource)
    try await waitFor("Cancellation fixture did not send a result") {
        files.fileExists(atPath: scratch.appendingPathComponent("result-sent").path)
    }
    cancelled.cancelTranslation()
    try require(!cancelled.isTranslating && cancelled.history.map(\.id) == [entry.id], "Cancelled job must leave history unchanged")
    try await Task.sleep(for: .seconds(1))
    print("PASS failed and cancelled jobs were excluded from history")

    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    child.arguments = ["--reopen", scratch.path, entry.id.uuidString]
    try child.run()
    child.waitUntilExit()
    try require(child.terminationStatus == 0, "History did not reopen in a fresh process")
}

@main
struct TranslationHistoryCheck {
    @MainActor
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 3 else {
            fputs("Usage: TranslationHistoryCheck SOURCE.pdf CHINESE.pdf BILINGUAL.pdf\n", stderr)
            exit(2)
        }
        do {
            if args[0] == "--reopen", let entryID = UUID(uuidString: args[2]) {
                try await reopenedHistory(in: URL(fileURLWithPath: args[1]), entryID: entryID)
            } else {
                try await runHistoryCheck(
                    source: URL(fileURLWithPath: args[0]),
                    mono: URL(fileURLWithPath: args[1]),
                    dual: URL(fileURLWithPath: args[2])
                )
            }
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
