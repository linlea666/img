import AppKit
import ReFrameCore
import ReFrameEngine
import SwiftUI
import UniformTypeIdentifiers

/// 把播放器当前的序列导出为视频
struct ExportSheet: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var player: PlayerModel
    @Environment(\.dismiss) private var dismiss

    @State private var fps: Double = 15
    @State private var mode: LoopMode = .once
    @State private var repeats = 1
    @State private var codec: VideoExporter.Codec = .hevc
    @State private var quality: VideoExporter.Quality = .high
    @State private var progress: Double?
    @State private var task: Task<Void, Never>?
    @State private var message: String?

    private var order: [Int] {
        PlaybackSequencer.exportOrder(count: player.frames.count, mode: mode, repeats: repeats)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("导出视频").font(.title2.bold())
            if player.frames.isEmpty {
                Text("播放器里还没有图片。请先在「播放」页选择要导出的范围。").foregroundStyle(.secondary)
            } else {
                if player.compareFrames != nil {
                    Text("当前为并排对比模式，导出的是修复后的画面。").font(.caption).foregroundStyle(.secondary)
                }
                Form {
                    LabeledContent("图片", value: "\(player.frames.count) 张（与播放器当前列表相同）")
                    HStack {
                        Text("帧率")
                        Slider(value: $fps, in: 1...60, step: 1)
                        Text("\(Int(fps)) fps").monospacedDigit().frame(width: 52)
                    }
                    Picker("播放方式", selection: $mode) {
                        ForEach(LoopMode.allCases, id: \.self) { m in
                            Text(m == .once ? "正放一遍" : m == .loop ? "重复" : "往返（正放再倒放）").tag(m)
                        }
                    }
                    if mode != .once {
                        Stepper("重复 \(repeats) 次", value: $repeats, in: 1...50)
                    }
                    Picker("编码", selection: $codec) {
                        ForEach(VideoExporter.Codec.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("画质", selection: $quality) {
                        ForEach(VideoExporter.Quality.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    LabeledContent("时长", value: String(format: "%.1f 秒（%ld 帧）", Double(order.count) / fps, order.count))
                }
                .formStyle(.grouped)
                .disabled(progress != nil)
            }
            if let progress {
                ProgressView(value: progress) { Text("正在导出…") }
            }
            if let message { Text(message).font(.callout) }
            HStack {
                Spacer()
                if progress != nil {
                    Button("取消导出", role: .cancel) { task?.cancel() }
                } else {
                    Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("导出…") { startExport() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(player.frames.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { fps = player.fps; mode = player.mode == .pingPong ? .pingPong : .once }
    }

    private func startExport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
        panel.nameFieldStringValue = "ReFrame-\(Int(fps))fps.mp4"
        if let dir = state.outputDirectory { panel.directoryURL = dir }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let frames = order.map { player.frames[$0] }
        let options = VideoExporter.Options(frames: frames, fps: Int(fps), codec: codec, quality: quality, outputURL: url,
                                            orientation: player.primaryOrientation)
        progress = 0
        message = nil
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                             reason: "导出视频")
        task = Task {
            defer { ProcessInfo.processInfo.endActivity(activity) }
            do {
                try await VideoExporter.export(options) { value in
                    Task { @MainActor in progress = value }
                }
                progress = nil
                message = "已导出：\(url.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch is CancellationError {
                progress = nil
                message = "已取消"
            } catch {
                progress = nil
                message = "导出失败：\(error.localizedDescription)"
            }
        }
    }
}
