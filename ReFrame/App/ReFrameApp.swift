import SwiftUI

@main
struct ReFrameApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("ReFrame") {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 1100, minHeight: 680)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开图片…") { state.presentOpenFiles() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("打开文件夹…") { state.presentOpenFolder() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("清空素材") { state.clearLibrary() }
                    .disabled(state.items.isEmpty || state.batch.isRunning)
            }
            CommandMenu("修复") {
                Button("试修当前图") { state.renderPreview() }
                    .keyboardShortcut("t", modifiers: .command)
                    .disabled(state.focusedItem == nil)
                Button("开始批量修复") { state.startBatch() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(state.items.isEmpty || state.batch.isRunning)
            }
        }
    }
}
