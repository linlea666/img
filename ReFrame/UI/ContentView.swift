import ReFrameCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showInspector = true

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            LibraryView()
                .navigationSplitViewColumnWidth(min: 250, ideal: 330, max: 520)
        } detail: {
            VStack(spacing: 0) {
                Picker("", selection: $state.detailTab) {
                    Text("对比").tag(DetailTab.compare)
                    Text("播放").tag(DetailTab.player)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
                .padding(.vertical, 8)
                Divider()
                switch state.detailTab {
                case .compare: CompareView()
                case .player: PlayerView(player: state.player, columnVisibility: $columnVisibility,
                                         showInspector: $showInspector)
                }
            }
        }
        .inspector(isPresented: $showInspector) {
            RestorePanel()
                .inspectorColumnWidth(min: 300, ideal: 330, max: 440)
        }
        .toolbar { toolbar }
        .alert("提示", isPresented: Binding(get: { state.alertMessage != nil },
                                          set: { if !$0 { state.alertMessage = nil } })) {
            Button("好") { state.alertMessage = nil }
        } message: {
            Text(state.alertMessage ?? "")
        }
        .sheet(isPresented: $state.showExport) {
            ExportSheet(player: state.player)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { state.presentOpenFiles() } label: { Label("打开图片", systemImage: "photo.badge.plus") }
                .help("打开图片（⌘O）")
            Button { state.presentOpenFolder() } label: { Label("打开文件夹", systemImage: "folder.badge.plus") }
                .help("打开文件夹（⇧⌘O）")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if state.batch.isRunning {
                Button { state.pauseOrResume() } label: {
                    Label(state.batch.isPaused ? "继续" : "暂停",
                          systemImage: state.batch.isPaused ? "play.fill" : "pause.fill")
                }
                Button(role: .destructive) { state.cancelBatch() } label: { Label("取消", systemImage: "stop.fill") }
            } else {
                Button { state.startBatch() } label: { Label("批量修复", systemImage: "wand.and.stars") }
                    .disabled(state.items.isEmpty)
                    .help("修复全部素材（⌘R）")
            }
            Button { state.showExport = true } label: { Label("导出视频", systemImage: "film") }
                .help("把播放器里的序列导出为视频")
            Button { showInspector.toggle() } label: { Label("修复设置", systemImage: "sidebar.right") }
        }
    }
}
