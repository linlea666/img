import AppKit
import ReFrameCore
import SwiftUI

/// 局部放大控制器：保存缩放状态，处理滚轮 / 触控板捏合 / 触控板平移。
///
/// - 鼠标滚轮：以指针为中心放大缩小
/// - 触控板双指捏合：放大缩小；双指滑动：放大后平移（按住 ⌘ 滑动则为缩放）
/// - 原图和修复图、并排的两个画面共用同一个控制器，保持同步
@MainActor
final class ZoomController: ObservableObject {
    @Published var state = ZoomState()
    /// 最近一次绘制时的视图 / 图片尺寸（不发布，避免循环刷新）
    private(set) var viewSize: CGSize = .zero
    private(set) var imageSize: CGSize = .zero
    /// 指针在画面上的位置（不在画面上时为 nil，此时不拦截滚轮）
    var hover: CGPoint?
    private var monitor: Any?

    var isZoomed: Bool { state.isZoomed }

    private var geometry: ZoomGeometry {
        ZoomGeometry(viewWidth: viewSize.width, viewHeight: viewSize.height,
                     imageWidth: imageSize.width, imageHeight: imageSize.height)
    }

    private var backingScale: Double { Double(NSScreen.main?.backingScaleFactor ?? 2) }

    /// 计算图片显示位置，并记住尺寸供事件处理使用
    func displayRect(in size: CGSize, image: CGSize) -> CGRect {
        viewSize = size
        imageSize = image
        let r = state.displayRect(in: geometry)
        return CGRect(x: r.x, y: r.y, width: r.width, height: r.height)
    }

    var percentText: String {
        guard geometry.isValid else { return "适应" }
        if !isZoomed { return "适应" }
        return "\(Int((state.pixelRatio(backingScale: backingScale, in: geometry) * 100).rounded()))%"
    }

    private var defaultPoint: CGPoint { hover ?? CGPoint(x: viewSize.width / 2, y: viewSize.height / 2) }

    func zoom(by factor: Double, at point: CGPoint? = nil) {
        let p = point ?? defaultPoint
        state = state.zoomed(by: factor, atX: p.x, y: p.y, in: geometry)
    }

    func zoomIn() { zoom(by: 1.5, at: CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)) }
    func zoomOut() { zoom(by: 1 / 1.5, at: CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)) }
    func fit() { state = ZoomState() }

    /// 按实际像素显示（1 = 100%，一个图片像素对应一个屏幕像素）
    func actualPixels(_ ratio: Double, at point: CGPoint? = nil) {
        guard geometry.isValid else { return }
        let target = ZoomState.zoom(forPixelRatio: ratio, backingScale: backingScale, in: geometry)
        zoom(by: target / state.zoom, at: point ?? CGPoint(x: viewSize.width / 2, y: viewSize.height / 2))
    }

    func pan(dx: Double, dy: Double) {
        state = state.panned(dx: dx, dy: dy, in: geometry)
    }

    func center(atNormalizedX x: Double, y: Double) {
        state = state.centered(atX: x, y: y, in: geometry)
    }

    /// 放大到某个区域（归一化矩形，左上角原点）
    func focus(on rect: CGRect, fill: Double = 0.5) {
        state = ZoomState.focusing(on: .init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height),
                                   fill: fill, in: geometry)
    }

    /// 双击：没放大时放大到 100%（若 100% 还不够大则 3 倍），已放大则恢复适应窗口
    func toggle(at point: CGPoint) {
        if isZoomed {
            fit()
        } else {
            let target = max(ZoomState.zoom(forPixelRatio: 1, backingScale: backingScale, in: geometry), 3)
            zoom(by: target, at: point)
        }
    }

    // MARK: - 滚轮 / 触控板

    func startMonitoring() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
            guard let self else { return event }
            let type = event.type
            let magnification = Double(event.magnification)
            let dx = Double(event.scrollingDeltaX), dy = Double(event.scrollingDeltaY)
            let precise = event.hasPreciseScrollingDeltas
            let command = event.modifierFlags.contains(.command)
            let consumed = MainActor.assumeIsolated {
                self.handle(type: type, magnification: magnification, dx: dx, dy: dy, precise: precise, command: command)
            }
            return consumed ? nil : event
        }
    }

    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(type: NSEvent.EventType, magnification: Double, dx: Double, dy: Double,
                        precise: Bool, command: Bool) -> Bool {
        guard hover != nil, geometry.isValid else { return false }
        switch type {
        case .magnify:
            zoom(by: 1 + magnification)
            return true
        case .scrollWheel:
            if precise && !command {
                // 触控板双指滑动：放大后用来平移
                guard isZoomed else { return false }
                pan(dx: dx, dy: dy)
                return true
            }
            guard dy != 0 else { return false }
            zoom(by: exp(dy * (precise ? 0.01 : 0.08)))
            return true
        default:
            return false
        }
    }
}

/// 缩放按钮组：− 百分比 +，带 ⌘- ⌘0 ⌘1 ⌘= 快捷键
struct ZoomControls: View {
    @ObservedObject var zoom: ZoomController

    var body: some View {
        HStack(spacing: 2) {
            Button { zoom.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                .keyboardShortcut("-", modifiers: .command)
                .help("缩小（⌘-）")
            Menu(zoom.percentText) {
                Button("适应窗口（⌘0）") { zoom.fit() }
                Button("实际像素 100%（⌘1）") { zoom.actualPixels(1) }
                Button("200%") { zoom.actualPixels(2) }
                Button("400%") { zoom.actualPixels(4) }
                Button("800%") { zoom.actualPixels(8) }
            }
            .menuStyle(.borderlessButton)
            .frame(width: 62)
            .help("缩放比例（滚轮或双指捏合也可以缩放，双击切换）")
            Button { zoom.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                .keyboardShortcut("=", modifiers: .command)
                .help("放大（⌘=）")
        }
        .background {
            // 菜单项里的快捷键只在菜单打开时有效，单独放两个不可见按钮承载 ⌘0 / ⌘1
            Group {
                Button("") { zoom.fit() }.keyboardShortcut("0", modifiers: .command)
                Button("") { zoom.actualPixels(1) }.keyboardShortcut("1", modifiers: .command)
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
    }
}

/// 放大后右下角的导航小图：黄框是当前看到的区域，点击或拖动跳转
struct ZoomNavigator: View {
    let image: CGImage
    let displayRect: CGRect
    let viewSize: CGSize
    @ObservedObject var zoom: ZoomController

    var body: some View {
        let mw: CGFloat = 160
        let mh = mw * CGFloat(image.height) / CGFloat(max(image.width, 1))
        let vx = max(0, -displayRect.minX / displayRect.width)
        let vy = max(0, -displayRect.minY / displayRect.height)
        let vw = min(1, viewSize.width / displayRect.width)
        let vh = min(1, viewSize.height / displayRect.height)
        ZStack(alignment: .topLeading) {
            Image(decorative: image, scale: 1).resizable().interpolation(.medium)
            Rectangle().stroke(Color.yellow, lineWidth: 1.5)
                .frame(width: max(4, vw * mw), height: max(4, vh * mh))
                .offset(x: vx * mw, y: vy * mh)
        }
        .frame(width: mw, height: mh)
        .clipped()
        .overlay(Rectangle().stroke(Color.white.opacity(0.7), lineWidth: 1))
        .shadow(radius: 4)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
            zoom.center(atNormalizedX: Double(g.location.x / mw), y: Double(g.location.y / mh))
        })
        .help("导航：点击或拖动跳到对应位置")
    }
}

/// 框选时的虚线框
struct SelectionBox: View {
    let rect: CGRect

    var body: some View {
        Rectangle()
            .fill(Color.yellow.opacity(0.12))
            .overlay(Rectangle().stroke(Color.yellow, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
            .allowsHitTesting(false)
    }
}
