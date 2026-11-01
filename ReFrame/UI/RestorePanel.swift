import ReFrameCore
import ReFrameEngine
import SwiftUI

/// 右侧修复设置与批处理面板
struct RestorePanel: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            batchSection
            outputSection
            restoreSection
            timestampSection
            advancedSection
        }
        .formStyle(.grouped)
    }

    // MARK: - 批处理

    private var batchSection: some View {
        Section("批量修复") {
            if let status = state.modelStatus, !(status.superResolution && status.face) {
                Label(status.superResolution ? "未找到人脸修复模型，将跳过人脸修复"
                                             : "未找到 AI 模型，将使用普通放大（请使用正式安装包）",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
            if state.batch.isRunning {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: state.batch.fraction) {
                        Text(state.batch.isPaused ? "已暂停" : "正在修复 \(state.batch.done)/\(state.batch.total)")
                    } currentValueLabel: {
                        Text(state.batch.currentName ?? "")
                            .lineLimit(1).truncationMode(.middle)
                    }
                    if let eta = state.batch.etaSeconds, !state.batch.isPaused {
                        Text("预计剩余 \(AppState.duration(eta))").font(.caption).foregroundStyle(.secondary)
                    }
                    if let note = state.batch.note {
                        Text(note).font(.caption).foregroundStyle(.orange)
                    }
                    HStack {
                        Button(state.batch.isPaused ? "继续" : "暂停") { state.pauseOrResume() }
                        Button("取消", role: .destructive) { state.cancelBatch() }
                    }
                }
                Text("处理期间电脑不会自动睡眠，可以合上屏幕前先接上电源。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    Button {
                        state.startBatch()
                    } label: {
                        Label("修复全部（\(state.items.count) 张）", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.items.isEmpty)
                    if state.selection.count > 1 {
                        Button("只修选中的 \(state.selection.count) 张") { state.startBatch(onlySelected: true) }
                    }
                }
                if let summary = state.batch.lastSummary {
                    Text(summary).font(.callout)
                }
                if let estimate = diskEstimate {
                    Text(estimate).font(.caption).foregroundStyle(.secondary)
                }
            }
            if !state.batch.failures.isEmpty {
                DisclosureGroup("失败 \(state.batch.failures.count) 张") {
                    ForEach(state.batch.failures, id: \.self) { Text($0).font(.caption) }
                }
            }
        }
    }

    private var diskEstimate: String? {
        guard let first = state.items.first, let size = ImageFiles.pixelSize(of: first.url) else { return nil }
        let bytes = OutputPlanner.estimatedBytes(count: state.items.count, inputWidth: size.width,
                                                 inputHeight: size.height, settings: state.settings)
        let s = state.settings.scale.rawValue
        return "输出 \(size.width * s)×\(size.height * s)，预计占用约 \(AppState.bytes(bytes))"
    }

    // MARK: - 输出

    private var outputSection: some View {
        Section("输出") {
            VStack(alignment: .leading, spacing: 4) {
                Text(state.outputDirectory?.path ?? "尚未选择")
                    .font(.caption)
                    .foregroundStyle(state.outputDirectory == nil ? .secondary : .primary)
                    .lineLimit(2).truncationMode(.middle)
                    .textSelection(.enabled)
                HStack {
                    Button("选择文件夹…") { state.chooseOutputDirectory() }
                    Button("在访达中显示") { state.revealOutput() }.disabled(state.outputDirectory == nil)
                }
            }
            .disabled(state.batch.isRunning)
            Picker("格式", selection: $state.settings.format) {
                ForEach(RestoreSettings.OutputFormat.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if state.settings.format != .png {
                LabeledSlider(title: "质量", value: $state.settings.jpegQuality, range: 0.6...1, format: "%.0f%%", scale: 100)
            }
            TextField("文件名", text: $state.settings.nameTemplate, prompt: Text("{name}_{scale}"))
                .help("{name} 原文件名，{scale} 放大倍数，{index} 序号")
            Picker("已存在时", selection: $state.settings.conflictPolicy) {
                ForEach(RestoreSettings.ConflictPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        }
        .disabled(state.batch.isRunning)
    }

    // MARK: - 修复

    private var restoreSection: some View {
        Section("修复") {
            Picker("放大", selection: $state.settings.scale) {
                ForEach(RestoreSettings.Scale.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Toggle("人脸修复（GFPGAN）", isOn: $state.settings.faceRestore)
            if state.settings.faceRestore {
                LabeledSlider(title: "人脸修复强度", value: $state.settings.faceStrength, range: 0...1,
                              format: "%.0f%%", scale: 100)
                Text("越高越清晰，但越可能\"不像本人\"。建议 50%～80%。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            LabeledSlider(title: "去色偏", value: $state.settings.whiteBalance, range: 0...1, format: "%.0f%%", scale: 100)
            Toggle("自动拉开明暗（去灰蒙蒙）", isOn: $state.settings.autoLevels)
            Toggle("偏暗时自动提亮", isOn: $state.settings.autoBrightness)
            LabeledSlider(title: "锐化", value: $state.settings.sharpen, range: 0...1, format: "%.0f%%", scale: 100)
            HStack {
                Button {
                    state.renderPreview()
                } label: {
                    Label("试修当前图", systemImage: "eye")
                }
                .disabled(state.focusedItem == nil || state.previewBusy)
                if state.previewBusy || state.analyzing { ProgressView().controlSize(.small) }
            }
        }
        .disabled(state.batch.isRunning)
    }

    // MARK: - 时间水印

    private var timestampSection: some View {
        Section("时间水印") {
            Picker("处理方式", selection: $state.settings.timestampMode) {
                ForEach(RestoreSettings.TimestampMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(timestampHelp).font(.caption).foregroundStyle(.secondary)
            if let info = state.contextInfo {
                Text(info).font(.caption)
            }
        }
        .disabled(state.batch.isRunning)
    }

    private var timestampHelp: String {
        switch state.settings.timestampMode {
        case .remove: return "自动找到摄像头叠加的时间文字，用整批画面合成的背景补上。"
        case .keep: return "修复时保护时间文字不被\"修\"成乱码，最后把原来的文字放大贴回。"
        case .ignore: return "当作普通画面一起修（数字可能会变形）。"
        }
    }

    // MARK: - 高级

    private var advancedSection: some View {
        Section("高级") {
            Picker("计算单元", selection: $state.settings.computeUnits) {
                ForEach(RestoreSettings.ComputeUnits.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Text("流程：去水印 → 去色偏/拉明暗（整批统一参数，不闪烁）→ Real-ESRGAN ×4 → GFPGAN 人脸修复 → ×2 → 锐化")
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(state.batch.isRunning)
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: String = "%.2f"
    var scale: Double = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value * scale)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
        }
    }
}
