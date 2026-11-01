import SwiftUI

/// 原图 / 修复图对比：拖动中间分隔线，左边原图、右边修复后
struct CompareView: View {
    @EnvironmentObject var state: AppState
    @State private var split: CGFloat = 0.5
    @State private var pixelated = false
    @State private var showOriginal = false

    var body: some View {
        VStack(spacing: 0) {
            if let pair = state.compare {
                GeometryReader { geo in
                    let rect = fitted(pair.before, in: geo.size)
                    ZStack(alignment: .topLeading) {
                        Color.black
                        imageLayer(pair.after ?? pair.before, smooth: pair.after != nil || !pixelated)
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                        if pair.after != nil {
                            imageLayer(pair.before, smooth: !pixelated)
                                .frame(width: rect.width, height: rect.height)
                                .mask(alignment: .leading) {
                                    Rectangle().frame(width: rect.width * (showOriginal ? 1 : split))
                                }
                                .offset(x: rect.minX, y: rect.minY)
                            Rectangle().fill(.white).frame(width: 2, height: rect.height)
                                .shadow(radius: 2)
                                .offset(x: rect.minX + rect.width * split - 1, y: rect.minY)
                                .opacity(showOriginal ? 0 : 1)
                            label("原图", x: rect.minX + 10, y: rect.minY + 10)
                            label("修复后", x: rect.maxX - 70, y: rect.minY + 10)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                        guard rect.width > 0 else { return }
                        split = min(max((g.location.x - rect.minX) / rect.width, 0), 1)
                    })
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
    }

    private func imageLayer(_ image: CGImage, smooth: Bool) -> some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(smooth ? .high : .none)
    }

    private func label(_ text: String, x: CGFloat, y: CGFloat) -> some View {
        Text(text).font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 3)
            .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(.white)
            .offset(x: x, y: y)
    }

    private func fitted(_ image: CGImage, in size: CGSize) -> CGRect {
        let aspect = CGFloat(image.width) / CGFloat(max(image.height, 1))
        var w = size.width, h = w / aspect
        if h > size.height { h = size.height; w = h * aspect }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func bottomBar(_ pair: ComparePair) -> some View {
        HStack(spacing: 12) {
            Button {
                state.renderPreview()
            } label: {
                Label("试修当前图", systemImage: "eye")
            }
            .disabled(state.previewBusy)
            if state.previewBusy || state.analyzing {
                ProgressView().controlSize(.small)
                Text(state.analyzing ? "正在分析整批画面…" : "正在修复…").font(.caption)
            } else if let note = pair.note {
                Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Toggle("原图显示像素", isOn: $pixelated).toggleStyle(.checkbox)
                .help("关闭平滑，看清原图到底有多少信息")
            if pair.after != nil {
                Label("按住看原图", systemImage: "eye.slash")
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(showOriginal ? Color.accentColor.opacity(0.3) : Color.secondary.opacity(0.15),
                                in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                    .onLongPressGesture(minimumDuration: 0, pressing: { showOriginal = $0 }, perform: {})
            }
            if let after = pair.after {
                Text("\(pair.before.width)×\(pair.before.height) → \(after.width)×\(after.height)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
