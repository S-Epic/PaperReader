import AppKit
import Foundation
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

private struct CheckFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw CheckFailure(message: message)
    }
}

@MainActor
private func waitUntil(_ message: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        try require(Date() < deadline, message)
        try await Task.sleep(for: .milliseconds(50))
    }
}

@MainActor
private func pdfViews(in view: NSView) -> [ReaderPDFView] {
    if let pdfView = view as? ReaderPDFView {
        return [pdfView]
    }
    return view.subviews.flatMap { pdfViews(in: $0) }
}

@MainActor
private func checkSynchronization(_ english: ReaderPDFView, _ chinese: ReaderPDFView) async throws {
    // The reader queues a layout pass when the second PDF becomes visible.
    try await Task.sleep(for: .milliseconds(300))
    try await waitUntil("Both PDF panes should expose a viewport") {
        english.viewportAnchor() != nil && chinese.viewportAnchor() != nil
    }
    for (leader, follower, name) in [
        (english, chinese, "English to Chinese"),
        (chinese, english, "Chinese to English"),
    ] {
        let before = leader.viewportAnchor()!
        guard let scrollView = leader.scrollView() else {
            throw CheckFailure(message: "\(name): native PDF scroll view not found")
        }
        let clipView = scrollView.contentView
        var target = clipView.bounds
        target.origin.y += 225
        target = clipView.constrainBoundsRect(target)
        clipView.scroll(to: target.origin)
        scrollView.reflectScrolledClipView(clipView)
        do {
            try await waitUntil("\(name): vertical scroll did not update both panes") {
                guard let a = leader.viewportAnchor(), let b = follower.viewportAnchor() else { return false }
                let leaderMoved = before.pageIndex != a.pageIndex || abs(before.y - a.y) > 0.08
                return leaderMoved && a.pageIndex == b.pageIndex && abs(a.y - b.y) < 0.10
            }
        } catch {
            fputs("Scroll diagnostic: prior \(before), leading \(String(describing: leader.viewportAnchor())), following \(String(describing: follower.viewportAnchor())), clip \(clipView.bounds), target \(target)\n", stderr)
            throw error
        }
        print("PASS \(name): native scroll synchronized")

        let leaderScale = leader.scaleFactor
        let followerScale = follower.scaleFactor
        let isFirstPane = leader === english
        let multiplier: CGFloat = isFirstPane ? 1.25 : 0.8
        leader.autoScales = false
        leader.scaleFactor = leaderScale * multiplier
        try await waitUntil("\(name): zoom did not update both panes") {
            let leadingRatio = leader.scaleFactor / leaderScale
            let followingRatio = follower.scaleFactor / followerScale
            return abs(leadingRatio - 1) > 0.12 && abs(leadingRatio - followingRatio) < 0.09
        }
        print("PASS \(name): native PDF zoom synchronized")
        fflush(stdout)
    }
}

@MainActor
private func makeWindow() -> NSWindow {
    let window = NSWindow(
        contentRect: CGRect(x: 120, y: 120, width: 1140, height: 700),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
    )
    window.title = "PDF Reader Validation"
    window.isReleasedWhenClosed = false
    return window
}

@MainActor
private func offlineCheck(source: URL, translated: URL) async throws {
    let sync = ReaderSync()
    let window = makeWindow()
    let panes = NSView(frame: CGRect(x: 0, y: 0, width: 1140, height: 700))
    let english = ReaderPDFView(frame: CGRect(x: 0, y: 0, width: 569, height: 700))
    let chinese = ReaderPDFView(frame: CGRect(x: 570, y: 0, width: 569, height: 700))
    panes.addSubview(english)
    panes.addSubview(chinese)
    window.contentView = panes
    window.makeKeyAndOrderFront(nil)
    defer { window.close() }
    sync.attach(english, side: .english)
    sync.attach(chinese, side: .chinese)
    sync.load(url: source, into: english)
    sync.load(url: translated, into: chinese)
    try require(english.document?.pageCount == 19, "Original RSIHub should contain 19 pages")
    try require(chinese.document?.pageCount == 19, "Translated RSIHub should contain 19 pages")
    try await checkSynchronization(english, chinese)
}

@MainActor
private func liveCheck(source: URL, python: URL, bridge: URL, output: URL) async throws {
    let model = TranslationModel(
        engine: TranslationEngine(python: python, bridge: bridge),
        jobsRoot: output.deletingLastPathComponent().appendingPathComponent("validation-jobs", isDirectory: true)
    )
    let window = makeWindow()
    let reader = ReaderWindow(model: model)
    let host = NSHostingView(rootView: reader)
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    let provider = NSItemProvider(item: source as NSURL, typeIdentifier: UTType.fileURL.identifier)
    try require(reader.acceptDrop([provider]), "ReaderWindow should accept a dropped file URL")
    defer {
        if model.isTranslating { model.cancelTranslation() }
        window.close()
    }
    try await waitUntil("Original PDF view did not load during background translation") {
        pdfViews(in: host).contains { $0.document?.pageCount == 19 }
            && model.sourceURL != nil && model.isTranslating && model.translatedURL == nil
    }
    print("PASS actual ReaderWindow: source opened while full translation ran in background")
    fflush(stdout)
    guard let original = pdfViews(in: host).first(where: { $0.document?.pageCount == 19 }) else {
        throw CheckFailure(message: "Original PDF view disappeared")
    }
    try await Task.sleep(for: .milliseconds(300))
    original.scroll(to: ReaderAnchor(pageIndex: 3, x: 0.5, y: 0.5))
    try await waitUntil("Original should navigate to page 4 before translation completes") {
        original.viewportAnchor()?.pageIndex == 3
    }
    try await waitUntil("Full translation did not finish within 20 minutes", timeout: 1200) {
        model.errorMessage != nil || (!model.isTranslating && model.bilingualURL != nil)
    }
    try require(model.errorMessage == nil, "Translation failed: \(model.errorMessage ?? "")")
    try require(model.canExport, "Full translation should enable export")
    try await waitUntil("ReaderWindow did not mount the translated pane") {
        pdfViews(in: host).filter { $0.document?.pageCount == 19 }.count == 2
    }
    let views = pdfViews(in: host)
        .filter { $0.document?.pageCount == 19 }
        .sorted { $0.convert(.zero, to: host).x < $1.convert(.zero, to: host).x }
    try await waitUntil("Show the second pane without resetting the reading position") {
        views[0].viewportAnchor()?.pageIndex == 3 && views[1].viewportAnchor()?.pageIndex == 3
    }
    print("PASS comparison reveal: reading position stayed on page 4")
    try await checkSynchronization(views[0], views[1])
    try model.exportBilingual(to: output)
    try require(PDFDocument(url: output)?.pageCount == 19, "Exported PDF should contain all 19 pages")
    print("PASS real export: 19 bilingual pages")
}

@main
struct ReaderSyncCheck {
    @MainActor
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 2 || (args.count == 5 && args[1] == "--live") else {
            fputs("Usage: ReaderSyncCheck SOURCE MONO | SOURCE --live PYTHON BRIDGE EXPORTED_DUAL\n", stderr)
            exit(2)
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                let source = URL(fileURLWithPath: args[0])
                if args.count == 2 {
                    try await offlineCheck(source: source, translated: URL(fileURLWithPath: args[1]))
                } else {
                    try await liveCheck(
                        source: source,
                        python: URL(fileURLWithPath: args[2]),
                        bridge: URL(fileURLWithPath: args[3]),
                        output: URL(fileURLWithPath: args[4])
                    )
                }
                exit(0)
            } catch {
                fputs("FAIL: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        application.run()
    }
}
