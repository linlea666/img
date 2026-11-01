import AppKit
import ReFrameCore
import SwiftUI

/// 图片序列播放器：选几张或整个文件夹，单次 / 循环 / 往返，可调帧率，可并排对比，可全屏
struct PlayerView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var player: PlayerModel
    @Binding var columnVisibility: NavigationSplitViewVisibility
    @Binding var showInspector: Bool

    @State private var scope: AppState.PlayScope = .all
    @State private var source: AppState.PlaySource = .restored
    @State private var immersive = false
    @StateObject private var zoom = ZoomController()
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if !immersive { sourceBar; Divider() }
            canvas
            Divider()
            controls
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        // 快捷键只在播放器获得焦点时生效，不影响在输入框里打字
        .onKeyPress(.space) { player.togglePlay(); return .handled }
        .onKeyPress(.leftArrow) { player.step(-1); return .handled }
        .onKeyPress(.rightArrow) { player.step(1); return .handled }
        .onKeyPress(.escape) {
            guard immersive else { return .ignored }
            toggleImmersive()
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "fF")) { _ in toggleImmersive(); return .handled }
        .onAppear { reload(); focused = true; zoom.startMonitoring() }
        .onChange(of: scope) { _, _ in reload() }
        .onChange(of: source) { _, _ in reload() }
        .onChange(of: state.batch.isRunning) { _, running in if !running { reload() } }
        .onChange(of: state.settings.orientation) { _, _ in reload() }
        .onDisappear { player.pause(); zoom.stopMonitoring() }
    }

    // MARK: - 来源

    private var sourceBar: some View {
        HStack(spacing: 16) {
            Picker("范围", selection: $scope) {
                ForEach(AppState.PlayScope.allCases) { Text($0.title).tag($0) }
            }
            .frame(width: 220)
            Picker("画面", selection: $source) {
                ForEach(AppState.PlaySource.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 260)
            .disabled(scope == .outputFolder)
            Button { reload() } label: { Label("刷新", systemImage: "arrow.clockwise") }
            Spacer()
            Text("\(player.frames.count) 张").foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func reload() {
        let list = state.playlist(scope: scope, source: source)
        // 原图按"画面方向"放正显示；修复结果写出时已经放正
        let originalOrientation = state.settings.orientation
        let primaryIsOriginal = scope != .outputFolder && source == .original
        player.load(frames: list.primary, compare: list.compare,
                    primaryOrientation: primaryIsOriginal ? originalOrientation : .identity,
                    compareOrientation: originalOrientation)
    }

    // MARK: - 画面

    private var canvas: some View {
        ZStack {
            Color.black
            if player.frames.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "play.rectangle").font(.system(size: 40))
                    Text(emptyMessage).multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
            } else if let compare = player.currentCompare {
                HStack(spacing: 2) {
                    frameImage(compare, caption: "原图", smooth: false)
                    frameImage(player.current, caption: "修复后", smooth: true)
                }
            } else {
                frameImage(player.current, caption: nil, smooth: true)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { toggleImmersive() }
        .onTapGesture { focused = true }
    }

    private var emptyMessage: String {
        switch (scope, source) {
        case (.outputFolder, _): return state.outputDirectory == nil ? "还没有选择输出文件夹" : "输出文件夹里还没有图片"
        case (_, .original): return "没有素材，请先打开图片或文件夹"
        default: return "还没有修复结果。\n先批量修复，或切换到「原图」播放。"
        }
    }

    private func frameImage(_ image: CGImage?, caption: String?, smooth: Bool) -> some View {
        ZoomableFrame(image: image, caption: caption, smooth: smooth, zoom: zoom)
    }

    // MARK: - 控制条

    private var controls: some View {
        VStack(spacing: 6) {
            if player.frames.count > 1 {
                Slider(value: Binding(get: { Double(player.index) },
                                      set: { player.seek(to: Int($0.rounded())) }),
                       in: 0...Double(player.frames.count - 1))
            }
            HStack(spacing: 14) {
                Button { player.step(-1) } label: { Image(systemName: "backward.frame.fill") }
                    .help("上一帧（←）")
                Button { player.togglePlay() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 20)
                }
                .help("播放 / 暂停（空格）")
                Button { player.step(1) } label: { Image(systemName: "forward.frame.fill") }
                    .help("下一帧（→）")

                Picker("", selection: $player.mode) {
                    ForEach(LoopMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 170)

                HStack(spacing: 4) {
                    Text("帧率")
                    Slider(value: $player.fps, in: 1...60, step: 1).frame(width: 130)
                    Text("\(Int(player.fps)) fps").monospacedDigit().frame(width: 52, alignment: .leading)
                    Menu("常用") {
                        ForEach([10, 12, 15, 24, 25, 30], id: \.self) { v in
                            Button("\(v) fps") { player.fps = Double(v) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 50)
                }

                Spacer()
                Text(player.frames.isEmpty ? "" : "\(player.index + 1)/\(player.frames.count)  \(player.currentName)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                ZoomControls(zoom: zoom)
                    .disabled(player.frames.isEmpty)
                Button { state.showExport = true } label: { Image(systemName: "film") }
                    .help("导出为视频")
                    .disabled(player.frames.isEmpty)
                Button { toggleImmersive() } label: {
                    Image(systemName: immersive ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .help("全屏（F 或双击画面，Esc 退出）")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .disabled(player.frames.isEmpty && !immersive)
    }

    /// 全屏：隐藏侧栏和设置面板，窗口进入全屏
    private func toggleImmersive() {
        immersive.toggle()
        columnVisibility = immersive ? .detailOnly : .all
        showInspector = !immersive
        if let window = NSApp.keyWindow {
            let isFull = window.styleMask.contains(.fullScreen)
            if isFull != immersive { window.toggleFullScreen(nil) }
        }
    }
}

/// 播放器里可缩放的一帧：放大后拖动平移；并排对比时两个画面共用同一个缩放状态，保持同步。
/// 放大后继续播放，可以盯住一张脸看它在连续帧里是否稳定。
struct ZoomableFrame: View {
    let image: CGImage?
    let caption: String?
    let smooth: Bool
    @ObservedObject var zoom: ZoomController
    @State private var lastTranslation: CGSize = .zero
    /// 按住 ⌥ 拖动时的框选区域
    @State private var selection: CGRect?
    @State private var selecting: Bool?

    var body: some View {
        GeometryReader { geo in
            if let image {
                let r = zoom.displayRect(in: geo.size, image: CGSize(width: image.width, height: image.height))
                ZStack(alignment: .topLeading) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(smooth ? .high : .medium)
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                    if let caption {
                        Text(caption).font(.caption.bold()).padding(4)
                            .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(.white).padding(6)
                    }
                    if let sel = selection { SelectionBox(rect: sel) }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .clipped()
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p):
                        // 并排时两个画面尺寸相同，记下当前画面的尺寸和指针位置
                        _ = zoom.displayRect(in: geo.size, image: CGSize(width: image.width, height: image.height))
                        zoom.hover = p
                    case .ended:
                        zoom.hover = nil
                    }
                }
                .gesture(DragGesture(minimumDistance: 2)
                    .onChanged { g in
                        if selecting == nil { selecting = NSEvent.modifierFlags.contains(.option) }
                        if selecting == true {
                            // 按住 ⌥ 拖动：框选任意区域放大
                            selection = CGRect(x: min(g.startLocation.x, g.location.x),
                                               y: min(g.startLocation.y, g.location.y),
                                               width: abs(g.location.x - g.startLocation.x),
                                               height: abs(g.location.y - g.startLocation.y))
                            return
                        }
                        guard zoom.isZoomed else { return }
                        zoom.pan(dx: g.translation.width - lastTranslation.width,
                                 dy: g.translation.height - lastTranslation.height)
                        lastTranslation = g.translation
                    }
                    .onEnded { _ in
                        if let sel = selection, sel.width > 6, sel.height > 6, r.width > 0, r.height > 0 {
                            let x0 = max(0, (sel.minX - r.minX) / r.width), y0 = max(0, (sel.minY - r.minY) / r.height)
                            let x1 = min(1, (sel.maxX - r.minX) / r.width), y1 = min(1, (sel.maxY - r.minY) / r.height)
                            if x1 > x0, y1 > y0 {
                                zoom.focus(on: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0), fill: 0.95)
                            }
                        }
                        selection = nil
                        selecting = nil
                        lastTranslation = .zero
                    })
            } else {
                ProgressView().frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }
}
