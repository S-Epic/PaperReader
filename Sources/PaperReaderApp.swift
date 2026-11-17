import AppKit
import SwiftUI

@main
struct PaperReaderApp: App {
    @StateObject private var model = TranslationModel()

    var body: some Scene {
        Window("论文译读", id: "reader") {
            ReaderWindow(model: model)
                .frame(minWidth: 760, minHeight: 540)
                .onOpenURL { model.importPDF($0) }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.cancelTranslation()
                }
        }
        .defaultSize(width: 1220, height: 850)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开 PDF…") { model.openDocument() }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .saveItem) {
                Button("导出双语 PDF…") { model.exportBilingual() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(!model.canExport)
            }
        }
    }
}
