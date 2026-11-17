import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ReaderWindow: View {
    @ObservedObject var model: TranslationModel
    @StateObject private var sync = ReaderSync()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            reader
            Divider()
            statusBar
        }
        .frame(minWidth: 740, minHeight: 480)
        .overlay {
            if sync.isDropTarget {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [6, 5]))
                    .padding(4)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $sync.isDropTarget, perform: acceptDrop)
        .sheet(isPresented: $sync.isHistoryPresented) {
            historySheet
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button(action: model.openDocument) {
                Label("打开 PDF", systemImage: "folder")
            }
            .keyboardShortcut("o", modifiers: .command)
            .accessibilityIdentifier("OpenPDF")

            Button {
                sync.historyOpenError = nil
                sync.isHistoryPresented = true
            } label: {
                Label("翻译历史", systemImage: "clock.arrow.circlepath")
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            .accessibilityIdentifier("OpenTranslationHistory")

            Text(model.documentName ?? "")
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(model.documentName ?? "")
                .accessibilityIdentifier("DocumentName")
            Spacer()

            if model.sourceURL != nil {
                HStack(spacing: 6) {
                    Button { sync.goPage(delta: -1) } label: {
                        Image(systemName: "chevron.up")
                    }
                    .help("上一页")
                    .accessibilityLabel("上一页")
                    .accessibilityIdentifier("PreviousPage")
                    .disabled(sync.currentPage <= 1)

                    Text("\(sync.currentPage) / \(sync.pageCount)")
                        .monospacedDigit()
                        .accessibilityIdentifier("PageNumber")

                    Button { sync.goPage(delta: 1) } label: {
                        Image(systemName: "chevron.down")
                    }
                    .help("下一页")
                    .accessibilityLabel("下一页")
                    .accessibilityIdentifier("NextPage")
                    .disabled(sync.currentPage >= sync.pageCount)
                    Divider().frame(height: 17).padding(.horizontal, 4)

                    Button { sync.zoom(by: 1 / 1.2) } label: {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    .keyboardShortcut("-", modifiers: .command)
                    .help("缩小")
                    .accessibilityLabel("缩小")
                    .accessibilityIdentifier("ZoomOut")

                    Button(action: sync.fit) {
                        Text("\(Int((sync.scale * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(minWidth: 40)
                    }
                    .help("适合宽度")
                    .accessibilityLabel("适合宽度")
                    .accessibilityValue("\(Int((sync.scale * 100).rounded()))%")
                    .accessibilityIdentifier("FitWidth")

                    Button { sync.zoom(by: 1.2) } label: {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    .keyboardShortcut("+", modifiers: .command)
                    .help("放大")
                    .accessibilityLabel("放大")
                    .accessibilityIdentifier("ZoomIn")
                }
                .buttonStyle(.borderless)
            }

            Button(action: model.exportBilingual) {
                Label("导出双语 PDF", systemImage: "square.and.arrow.up")
            }
            .disabled(!model.canExport)
            .accessibilityIdentifier("ExportBilingual")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var historySheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("翻译历史")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("关闭") { sync.isHistoryPresented = false }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("CloseTranslationHistory")
            }
            .padding(16)

            Divider()

            if model.history.isEmpty {
                VStack(spacing: 8) {
                    Text("暂无翻译记录")
                        .font(.headline)
                    Text("完成翻译的文献会自动出现在这里。")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("TranslationHistoryEmpty")
            } else {
                List(model.history) { entry in
                    Button { openHistory(entry) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "doc.text")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.documentName)
                                    .font(.body.weight(.medium))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text("\(entry.completedAt.formatted(date: .abbreviated, time: .shortened)) · \(entry.pageCount) 页")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.activeHistoryID == entry.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                                    .accessibilityLabel("当前打开")
                            }
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isTranslating)
                    .help(entry.documentName)
                    .accessibilityHint("打开原文和译文")
                    .accessibilityIdentifier("TranslationHistoryEntry")
                }
                .accessibilityIdentifier("TranslationHistoryList")
            }

            if let error = sync.historyOpenError {
                historyNotice(error)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("TranslationHistoryError")
            } else if model.isTranslating && !model.history.isEmpty {
                historyNotice("本次翻译完成或取消后，可以打开历史记录。")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 520, height: 400)
        .accessibilityIdentifier("TranslationHistory")
    }

    private func historyNotice(_ message: String) -> some View {
        Text(message)
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
    }

    private func openHistory(_ entry: TranslationHistoryEntry) {
        model.openHistory(entry)
        if model.activeHistoryID == entry.id, model.errorMessage == nil {
            sync.isHistoryPresented = false
        } else {
            sync.historyOpenError = model.errorMessage
        }
    }

    private var reader: some View {
        HStack(spacing: 0) {
            if let source = model.sourceURL {
                pane(title: "英文原文", url: source, side: .english)
                if let translated = model.translatedURL {
                    Divider()
                    pane(title: "简体中文", url: translated, side: .chinese)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "doc.richtext")
                        .font(.system(size: 38, weight: .light))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("拖入英文论文 PDF")
                        .font(.title2.weight(.semibold))
                    Text("可以立即阅读原文，全文翻译在后台进行。")
                        .foregroundStyle(.secondary)
                    Button("选择 PDF", action: model.openDocument)
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
    }

    private func pane(title: String, url: URL, side: ReaderSide) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            ReaderPDFPane(url: url, side: side, sync: sync)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusBar: some View {
        HStack(spacing: 9) {
            if model.isTranslating {
                ProgressView(value: model.progress)
                    .frame(width: 96)
                    .accessibilityLabel("翻译进度")
                    .accessibilityIdentifier("TranslationProgress")
            }

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("TranslationError")
            } else {
                Text(model.status)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("TranslationStatus")
            }
            Spacer()

            if model.isTranslating {
                Button("取消翻译", action: model.cancelTranslation)
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("CancelTranslation")
            }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }) else { return false }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?
            if let fileURL = item as? URL {
                url = fileURL
            } else if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else {
                url = nil
            }
            guard let url, url.isFileURL else { return }
            Task { @MainActor in model.importPDF(url) }
        }
        return true
    }
}

enum ReaderSide: Equatable {
    case english
    case chinese
}

struct ReaderAnchor {
    let pageIndex: Int
    let x: CGFloat
    let y: CGFloat
}

@MainActor
final class ReaderSync: ObservableObject {
    @Published var isDropTarget = false
    @Published var isHistoryPresented = false
    @Published var historyOpenError: String?
    @Published private(set) var currentPage = 1
    @Published private(set) var pageCount = 0
    @Published private(set) var scale: CGFloat = 1

    private weak var english: ReaderPDFView?
    private weak var chinese: ReaderPDFView?
    private var activeSide: ReaderSide = .english
    private var lastAnchor: ReaderAnchor?
    private var applyingChange = false
    private var fitWidth = true
    private var pendingLayout = false

    func attach(_ view: ReaderPDFView, side: ReaderSide) {
        if side == .english {
            english = view
        } else {
            chinese = view
        }
        view.onPositionChange = { [weak self] view in self?.changed(view, side: side) }
        view.onScaleChange = { [weak self] view in self?.changedScale(view, side: side) }
        view.onResize = { [weak self] _ in self?.queueLayout() }
    }

    func load(url: URL?, into view: ReaderPDFView) {
        guard view.loadedURL != url else { return }
        let wasEnglish = view === english
        if wasEnglish {
            fitWidth = true
            activeSide = .english
            lastAnchor = url == nil ? nil : ReaderAnchor(pageIndex: 0, x: 0.5, y: 1)
        } else if lastAnchor == nil {
            lastAnchor = english?.viewportAnchor()
        }
        applyingChange = true
        view.loadedURL = url
        view.document = url.flatMap(PDFDocument.init(url:))
        applyingChange = false
        queueLayout()
    }

    func zoom(by multiplier: CGFloat) {
        guard let view = activeView else { return }
        fitWidth = false
        let anchor = view.viewportAnchor() ?? lastAnchor
        apply(scale: view.scaleFactor * multiplier, anchor: anchor)
    }

    func fit() {
        fitWidth = true
        lastAnchor = activeView?.viewportAnchor() ?? lastAnchor
        finishLayout()
    }

    func goPage(delta: Int) {
        guard let document = activeView?.document else { return }
        let index = min(max(currentPage - 1 + delta, 0), document.pageCount - 1)
        guard index >= 0 else { return }
        apply(scale: nil, anchor: ReaderAnchor(pageIndex: index, x: 0.5, y: 1))
    }

    private var activeView: ReaderPDFView? {
        if activeSide == .chinese, let chinese, chinese.document != nil {
            return chinese
        }
        return english
    }

    private var views: [ReaderPDFView] {
        [english, chinese].compactMap { $0 }.filter { $0.document != nil }
    }

    private func queueLayout() {
        guard !pendingLayout else { return }
        pendingLayout = true
        Task { @MainActor [weak self] in
            self?.finishLayout()
        }
    }

    private func finishLayout() {
        pendingLayout = false
        guard let view = activeView, view.document != nil else {
            publishPosition()
            return
        }
        let targetScale: CGFloat?
        if fitWidth {
            targetScale = views.compactMap { $0.widthFitScale() }.min()
        } else {
            targetScale = view.scaleFactor
        }
        apply(scale: targetScale, anchor: lastAnchor ?? view.viewportAnchor())
    }

    private func changed(_ view: ReaderPDFView, side: ReaderSide) {
        guard !applyingChange, !pendingLayout, let anchor = view.viewportAnchor() else { return }
        activeSide = side
        lastAnchor = anchor
        let target = side == .english ? chinese : english
        applyingChange = true
        target?.scroll(to: anchor)
        applyingChange = false
        publishPosition()
    }

    private func changedScale(_ view: ReaderPDFView, side: ReaderSide) {
        guard !applyingChange, !pendingLayout, view.document != nil else { return }
        activeSide = side
        fitWidth = false
        apply(scale: view.scaleFactor, anchor: view.viewportAnchor() ?? lastAnchor)
    }

    private func apply(scale newScale: CGFloat?, anchor: ReaderAnchor?) {
        applyingChange = true
        defer { applyingChange = false }
        for view in views {
            if let newScale {
                let limitedScale = min(max(newScale, view.minScaleFactor), view.maxScaleFactor)
                if abs(view.scaleFactor - limitedScale) > 0.0001 {
                    view.scaleFactor = limitedScale
                    view.layoutSubtreeIfNeeded()
                }
            }
            if let anchor {
                view.scroll(to: anchor)
            }
        }
        lastAnchor = activeView?.viewportAnchor() ?? anchor
        publishPosition()
    }

    private func publishPosition() {
        let nextCount = english?.document?.pageCount ?? 0
        let nextPage = (activeView?.viewportAnchor()?.pageIndex ?? 0) + 1
        let nextScale = activeView?.scaleFactor ?? 1
        if nextCount != pageCount { pageCount = nextCount }
        if nextPage != currentPage { currentPage = nextPage }
        if abs(nextScale - scale) > 0.0001 { scale = nextScale }
    }
}

@MainActor
final class ReaderPDFView: PDFView {
    var loadedURL: URL?
    var onPositionChange: ((ReaderPDFView) -> Void)?
    var onScaleChange: ((ReaderPDFView) -> Void)?
    var onResize: ((ReaderPDFView) -> Void)?
    private weak var observedClip: NSClipView?
    private var lastSize: NSSize = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        displayMode = .singlePageContinuous
        displayDirection = .vertical
        displayBox = .cropBox
        displaysPageBreaks = true
        pageBreakMargins = NSEdgeInsets(top: 9, left: 12, bottom: 9, right: 12)
        backgroundColor = .underPageBackgroundColor
        autoScales = false
        minScaleFactor = 0.15
        maxScaleFactor = 6
        NotificationCenter.default.addObserver(
            self, selector: #selector(scaleChanged),
            name: .PDFViewScaleChanged, object: self
        )
    }

    required init?(coder: NSCoder) {
        fatalError("ReaderPDFView is initialized programmatically")
    }

    override func setFrameSize(_ newSize: NSSize) {
        if frame.size != newSize {
            onResize?(self)
        }
        super.setFrameSize(newSize)
    }

    override func layout() {
        if bounds.size != lastSize {
            lastSize = bounds.size
            onResize?(self)
        }
        super.layout()
        if let clip = scrollView()?.contentView, observedClip !== clip {
            if let observedClip {
                NotificationCenter.default.removeObserver(
                    self, name: NSView.boundsDidChangeNotification, object: observedClip
                )
            }
            observedClip = clip
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(positionChanged),
                name: NSView.boundsDidChangeNotification, object: clip
            )
        }
    }

    @objc private func positionChanged() { onPositionChange?(self) }
    @objc private func scaleChanged() { onScaleChange?(self) }

    func scrollView() -> NSScrollView? {
        func find(in parent: NSView) -> NSScrollView? {
            for child in parent.subviews {
                if let scrollView = child as? NSScrollView { return scrollView }
                if let scrollView = find(in: child) { return scrollView }
            }
            return nil
        }
        return find(in: self)
    }

    func viewportAnchor() -> ReaderAnchor? {
        guard let document, let clip = scrollView()?.contentView,
              clip.bounds.width > 0, clip.bounds.height > 0 else { return nil }
        let center = NSPoint(x: clip.bounds.midX, y: clip.bounds.midY)
        let viewPoint = convert(center, from: clip)
        guard let page = page(for: viewPoint, nearest: true) else { return nil }
        let pageBounds = page.bounds(for: displayBox)
        guard pageBounds.width > 0, pageBounds.height > 0 else { return nil }
        let point = convert(viewPoint, to: page)
        return ReaderAnchor(
            pageIndex: document.index(for: page),
            x: min(max((point.x - pageBounds.minX) / pageBounds.width, 0), 1),
            y: min(max((point.y - pageBounds.minY) / pageBounds.height, 0), 1)
        )
    }

    func scroll(to anchor: ReaderAnchor) {
        guard let document, anchor.pageIndex >= 0, anchor.pageIndex < document.pageCount,
              let page = document.page(at: anchor.pageIndex),
              let scrollView = scrollView() else { return }
        let clip = scrollView.contentView
        let pageBounds = page.bounds(for: displayBox)
        let pagePoint = NSPoint(
            x: pageBounds.minX + anchor.x * pageBounds.width,
            y: pageBounds.minY + anchor.y * pageBounds.height
        )
        let point = clip.convert(convert(pagePoint, from: page), from: self)
        let desiredBounds = NSRect(
            origin: NSPoint(x: point.x - clip.bounds.width / 2, y: point.y - clip.bounds.height / 2),
            size: clip.bounds.size
        )
        let origin = clip.constrainBoundsRect(desiredBounds).origin
        if abs(origin.x - clip.bounds.origin.x) > 0.25 || abs(origin.y - clip.bounds.origin.y) > 0.25 {
            clip.scroll(to: origin)
            scrollView.reflectScrolledClipView(clip)
        }
    }

    func widthFitScale() -> CGFloat? {
        guard let document else { return nil }
        let width = (0..<document.pageCount).compactMap { index -> CGFloat? in
            guard let page = document.page(at: index) else { return nil }
            let bounds = page.bounds(for: displayBox)
            return page.rotation % 180 == 0 ? bounds.width : bounds.height
        }.max() ?? 0
        // PDFKit magnifies the clip view's bounds, so use the unscaled viewport size.
        let viewWidth = scrollView()?.contentView.frame.width ?? bounds.width
        guard width > 0, viewWidth > 36 else { return nil }
        return (viewWidth - 32) / width
    }
}

@MainActor
private struct ReaderPDFPane: NSViewRepresentable {
    let url: URL
    let side: ReaderSide
    let sync: ReaderSync

    func makeNSView(context: Context) -> ReaderPDFView {
        let view = ReaderPDFView(frame: .zero)
        view.setAccessibilityIdentifier(side == .english ? "OriginalPDFView" : "TranslatedPDFView")
        view.setAccessibilityLabel(side == .english ? "英文原文 PDF" : "简体中文 PDF")
        sync.attach(view, side: side)
        return view
    }

    func updateNSView(_ view: ReaderPDFView, context: Context) {
        sync.load(url: url, into: view)
    }
}
