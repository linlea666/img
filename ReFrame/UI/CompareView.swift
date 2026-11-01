import AppKit
import ReFrameEngine
import SwiftUI

/// 原图 / 修复图对比：拖动分隔线左右对比；滚轮、捏合、双击局部放大；放大镜；一键放大到人脸
struct CompareView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var zoom = ZoomController()
    @State private var split: CGFloat = 0.5
    @State private var pixelated = false
    @State private var showOriginal = false
    @State private var loupeOn = false
    @State private var loupePoint: CGPoint?
    @State private var dragMode: DragMode?
    @State private var lastTranslation: CGSize = .zero
    @State private var faces: [CGRect] = []
    @State private var faceIndex = -1
    @State private var faceKey = ""
    @State private var faceNote: String?
    @State private var selectMode = false
    @State private var selection: CGRect?

    private enum DragMode { case split, pan, select }

    var body: some View {
        VStack(spacing: 0) {
            if let pair = state.compare {
                GeometryReader { geo in
                    canvas(pair, size: geo.size)
                }
                Divider()
                bottomBar(pair)
            } else {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "rectangle.split.2x1").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("在左侧选择一张图").foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear { zoom.startMonitoring() }
        .onDisappear { zoom.stopMonitoring() }
    }

    // MARK: - 画面

    private func canvas(_ pair: ComparePair, size: CGSize) -> some View {
        let display = pair.after ?? pair.before
        let r = zoom.displayRect(in: size, image: CGSize(width: display.width, height: display.height))
        let dividerX = size.width * split
        return ZStack(alignment: .topLeading) {
            Color.black
            positioned(display, in: r, smooth: pair.after != nil || !pixelated)
            if pair.after != nil {
                ZStack(alignment: .topLeading) {
                    positioned(pair.before, in: r, smooth: !pixelated)
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .mask(alignment: .leading) {
                    Rectangle().frame(width: showOriginal ? size.width : dividerX)
                }
                Rectangle().fill(.white).frame(width: 2, height: size.height)
                    .shadow(radius: 2)
                    .offset(x: dividerX - 1)
                    .opacity(showOriginal ? 0 : 1)
                tag("原图").offset(x: 10, y: 10)
                tag("修复后").offset(x: size.width - 70, y: 10)
            }
            if let sel = selection {
                SelectionBox(rect: sel)
            }
            if loupeOn, let p = loupePoint {
                loupe(pair, displayRect: r, at: p)
            }
            if zoom.isZoomed {
                ZoomNavigator(image: display, displayRect: r, viewSize: size, zoom: zoom)
                    .position(x: size.width - 90, y: size.height - 12 - 80 * CGFloat(display.height) / CGFloat(max(display.width, 1)))
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let p):
                zoom.hover = p
                if loupeOn { loupePoint = p }
            case .ended:
                zoom.hover = nil
                loupePoint = nil
            }
        }
        .gesture(dragGesture(dividerX: dividerX, width: size.width, hasAfter: pair.after != nil, displayRect: r))
        .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { v in zoom.toggle(at: v.location) })
    }

    private func positioned(_ image: CGImage, in r: CGRect, smooth: Bool) -> some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(smooth ? .high : .none)
            .frame(width: r.width, height: r.height)
            .offset(x: r.minX, y: r.minY)
    }

    private func tag(_ text: String) -> some View {
        Text(text).font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 3)
            .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(.white)
    }

    /// 拖动：
    /// - 框选模式或按住 ⌥：拖出一个框，松手后把框里的区域放大到铺满画面
    /// - 放大后：分隔线附近拖动调分隔线，其他地方拖动平移
    /// - 未放大：拖动调分隔线
    private func dragGesture(dividerX: CGFloat, width: CGFloat, hasAfter: Bool, displayRect r: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { g in
                if dragMode == nil {
                    if selectMode || NSEvent.modifierFlags.contains(.option) {
                        dragMode = .select
                    } else {
                        let nearDivider = abs(g.startLocation.x - dividerX) < 16
                        dragMode = hasAfter && (!zoom.isZoomed || nearDivider) ? .split : .pan
                    }
                    lastTranslation = .zero
                }
                switch dragMode {
                case .select:
                    selection = CGRect(x: min(g.startLocation.x, g.location.x), y: min(g.startLocation.y, g.location.y),
                                       width: abs(g.location.x - g.startLocation.x),
                                       height: abs(g.location.y - g.startLocation.y))
                case .split:
                    guard width > 0 else { return }
                    split = min(max(g.location.x / width, 0), 1)
                case .pan:
                    zoom.pan(dx: g.translation.width - lastTranslation.width,
                             dy: g.translation.height - lastTranslation.height)
                    lastTranslation = g.translation
                case nil:
                    break
                }
            }
            .onEnded { _ in
                if dragMode == .select, let sel = selection {
                    zoomToSelection(sel, displayRect: r)
                    selectMode = false
                }
                selection = nil
                dragMode = nil
            }
    }

    private func zoomToSelection(_ sel: CGRect, displayRect r: CGRect) {
        guard sel.width > 6, sel.height > 6, r.width > 0, r.height > 0 else { return }
        let x0 = max(0, (sel.minX - r.minX) / r.width), y0 = max(0, (sel.minY - r.minY) / r.height)
        let x1 = min(1, (sel.maxX - r.minX) / r.width), y1 = min(1, (sel.maxY - r.minY) / r.height)
        guard x1 > x0, y1 > y0 else { return }
        zoom.focus(on: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0), fill: 0.95)
        faceNote = nil
    }

    /// 放大镜：指针处放大 3 倍，左半边原图、右半边修复后
    private func loupe(_ pair: ComparePair, displayRect r: CGRect, at p: CGPoint) -> some View {
        let d: CGFloat = 230, m: CGFloat = 3
        let big = CGSize(width: r.width * m, height: r.height * m)
        let offset = CGPoint(x: d / 2 - (p.x - r.minX) * m, y: d / 2 - (p.y - r.minY) * m)
        return ZStack(alignment: .topLeading) {
            Color.black
            loupeLayer(pair.after ?? pair.before, smooth: true, size: big, offset: offset, diameter: d)
            if pair.after != nil {
                loupeLayer(pair.before, smooth: !pixelated, size: big, offset: offset, diameter: d)
                    .mask(alignment: .leading) { Rectangle().frame(width: d / 2) }
                Rectangle().fill(Color.white.opacity(0.8)).frame(width: 1, height: d).offset(x: d / 2)
                Text("原图").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    .shadow(radius: 2).offset(x: d / 2 - 44, y: d - 30)
                Text("修复后").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    .shadow(radius: 2).offset(x: d / 2 + 8, y: d - 30)
            }
        }
        .frame(width: d, height: d)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white, lineWidth: 2))
        .shadow(radius: 8)
        .offset(x: p.x - d / 2, y: p.y - d / 2)
        .allowsHitTesting(false)
    }

    private func loupeLayer(_ image: CGImage, smooth: Bool, size: CGSize, offset: CGPoint, diameter d: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Image(decorative: image, scale: 1).resizable().interpolation(smooth ? .high : .none)
                .frame(width: size.width, height: size.height)
                .offset(x: offset.x, y: offset.y)
        }
        .frame(width: d, height: d, alignment: .topLeading)
        .clipped()
    }

    // MARK: - 人脸

    private func nextFace(_ pair: ComparePair) {
        let key = "\(pair.itemID)-\(pair.after?.width ?? 0)-\(pair.note ?? "")"
        if key != faceKey {
            faceKey = key
            faces = []
            faceIndex = -1
            faceNote = "正在找人脸…"
            let image = pair.after ?? pair.before
            Task {
                let found = await Task.detached(priority: .userInitiated) { FaceLocator.locate(in: image) }.value
                guard faceKey == key else { return }
                faces = found
                if found.isEmpty {
                    faceNote = "没有检测到人脸（脸太小、太糊或角度太偏时找不到）"
                } else {
                    focusFace(0)
                }
            }
            return
        }
        guard !faces.isEmpty else { return }
        focusFace((faceIndex + 1) % faces.count)
    }

    private func focusFace(_ i: Int) {
        faceIndex = i
        zoom.focus(on: faces[i], fill: 0.55)
        faceNote = faces.count > 1 ? "第 \(i + 1)/\(faces.count) 张脸，再点一次看下一张" : "已放大到人脸"
    }

    // MARK: - 底部工具条

    private func bottomBar(_ pair: ComparePair) -> some View {
        HStack(spacing: 10) {
            Button {
                state.renderPreview()
            } label: {
                Label("试修当前图", systemImage: "eye")
            }
            .disabled(state.previewBusy)
            if state.previewBusy || state.analyzing {
                ProgressView().controlSize(.small)
                Text(state.analyzing ? "正在分析整批画面…" : "正在修复…").font(.caption)
            } else if let note = faceNote ?? pair.note {
                Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    .help(note)
            }
            Spacer(minLength: 8)
            ZoomControls(zoom: zoom)
            Toggle(isOn: $selectMode) { Label("框选", systemImage: "rectangle.dashed") }
                .toggleStyle(.button)
                .help("框选放大：在画面上拖出一个框，放大框里的任意区域（也可以按住 ⌥ 直接拖）")
            Toggle(isOn: $loupeOn) { Label("放大镜", systemImage: "magnifyingglass.circle") }
                .toggleStyle(.button)
                .help("鼠标所在位置放大 3 倍：左半边原图、右半边修复后")
            Button { nextFace(pair) } label: { Label("人脸", systemImage: "face.smiling") }
                .help("放大到检测到的人脸；多张脸时依次切换")
            Toggle("像素", isOn: $pixelated).toggleStyle(.checkbox)
                .help("原图关闭平滑，看清原图到底有多少信息")
            if pair.after != nil {
                Label("按住看原图", systemImage: "eye.slash")
                    .labelStyle(.iconOnly)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(showOriginal ? Color.accentColor.opacity(0.3) : Color.secondary.opacity(0.15),
                                in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                    .onLongPressGesture(minimumDuration: 0, pressing: { showOriginal = $0 }, perform: {})
                    .help("按住看原图")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onChange(of: state.compare?.itemID) { _, _ in faceNote = nil }
    }
}
