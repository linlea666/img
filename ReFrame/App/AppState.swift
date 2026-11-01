import AppKit
import ReFrameCore
import ReFrameEngine
import SwiftUI
import UniformTypeIdentifiers

/// 素材库里的一张图
struct LibraryItem: Identifiable, Hashable {
    enum Status: Hashable { case pending, processing, done, failed }

    let id = UUID()
    let url: URL
    var status: Status = .pending
    var name: String { url.lastPathComponent }
}

/// 批处理状态
struct BatchState {
    var isRunning = false
    var isPaused = false
    var total = 0
    var done = 0
    var skipped = 0
    var currentName: String?
    var etaSeconds: Double?
    var failures: [String] = []
    var note: String?
    var lastSummary: String?

    var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }
}

/// 对比视图的内容
struct ComparePair {
    let itemID: UUID
    let before: CGImage
    var after: CGImage?
    var note: String?
}

enum DetailTab: Hashable { case compare, player }

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var items: [LibraryItem] = []
    @Published var selection: Set<UUID> = []
    @Published var focusedID: UUID? { didSet { if focusedID != oldValue { loadCompare() } } }
    @Published var settings: RestoreSettings { didSet { settingsChanged(from: oldValue) } }
    @Published var outputDirectory: URL? { didSet { persistOutputDirectory(); refreshStatuses(); loadCompare() } }
    @Published var batch = BatchState()
    @Published var compare: ComparePair?
    @Published var previewBusy = false
    @Published var contextInfo: String?
    @Published var analyzing = false
    @Published var modelStatus: RestorationEngine.ModelStatus?
    @Published var alertMessage: String?
    @Published var detailTab: DetailTab = .compare
    @Published var showExport = false

    let player = PlayerModel()
    let engine: RestorationEngine

    private var batchContext: BatchContext?
    private var contextTask: Task<BatchContext?, Error>?
    private var contextGeneration = 0
    private var batchTask: Task<Void, Never>?
    private var activity: NSObjectProtocol?

    private static let settingsKey = "restoreSettings.v1"
    private static let outputKey = "outputDirectory"

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.settingsKey),
           let saved = try? JSONDecoder().decode(RestoreSettings.self, from: data) {
            settings = saved
        } else {
            settings = RestoreSettings()
        }
        if let path = defaults.string(forKey: Self.outputKey) {
            outputDirectory = URL(fileURLWithPath: path, isDirectory: true)
        }
        let models = Bundle.main.resourceURL?.appendingPathComponent("Models", isDirectory: true)
        engine = RestorationEngine(modelsDirectory: models)
        Task { modelStatus = await engine.modelStatus() }
    }

    var focusedItem: LibraryItem? { items.first { $0.id == focusedID } }
    var selectedItems: [LibraryItem] { items.filter { selection.contains($0.id) } }

    // MARK: - 导入

    func presentOpenFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.message = "选择要修复的图片（原图不会被修改）"
        let box = attachUpsideDownOption(to: panel)
        if panel.runModal() == .OK {
            setUpsideDown(box.state == .on)
            add(urls: panel.urls)
        }
    }

    func presentOpenFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "选择包含图片的文件夹"
        let box = attachUpsideDownOption(to: panel)
        if panel.runModal() == .OK, let url = panel.url {
            setUpsideDown(box.state == .on)
            addFolder(url)
        }
    }

    /// 打开对话框底部的勾选框：这批图片是倒着的
    private func attachUpsideDownOption(to panel: NSOpenPanel) -> NSButton {
        let box = NSButton(checkboxWithTitle: "这批图片是倒着的（修复后旋转 180° 放正）", target: nil, action: nil)
        box.state = settings.orientation.rotation == .upsideDown ? .on : .off
        box.sizeToFit()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: box.frame.width + 40, height: box.frame.height + 20))
        box.frame.origin = NSPoint(x: 20, y: 10)
        container.addSubview(box)
        panel.accessoryView = container
        panel.isAccessoryViewDisclosed = true
        return box
    }

    func setUpsideDown(_ on: Bool) {
        if on {
            settings.orientation.rotation = .upsideDown
        } else if settings.orientation.rotation == .upsideDown {
            settings.orientation.rotation = .none
        }
    }

    func addFolder(_ folder: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                                   options: [.skipsHiddenFiles])) ?? []
        add(urls: files)
        if outputDirectory == nil {
            // 默认输出到同级的"<文件夹名>_修复"
            outputDirectory = folder.deletingLastPathComponent()
                .appendingPathComponent(folder.lastPathComponent + "_修复", isDirectory: true)
        }
    }

    /// 拖拽进来的可能是文件也可能是文件夹
    func addDropped(_ urls: [URL]) {
        for url in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                addFolder(url)
            } else {
                add(urls: [url])
            }
        }
    }

    func add(urls: [URL]) {
        guard !batch.isRunning else { return }
        let existing = Set(items.map { $0.url.standardizedFileURL.path })
        let new = urls.filter { SupportedImage.isSupported($0) && !existing.contains($0.standardizedFileURL.path) }
        guard !new.isEmpty else { return }
        let all = items.map(\.url) + new
        let sorted = NaturalSort.sorted(all)
        var byPath = Dictionary(uniqueKeysWithValues: items.map { ($0.url.standardizedFileURL.path, $0) })
        items = sorted.map { url in byPath.removeValue(forKey: url.standardizedFileURL.path) ?? LibraryItem(url: url) }
        if focusedID == nil { focusedID = items.first?.id }
        invalidateContext()
        refreshStatuses()
    }

    func clearLibrary() {
        guard !batch.isRunning else { return }
        items = []
        selection = []
        focusedID = nil
        compare = nil
        invalidateContext()
    }

    func removeSelected() {
        guard !batch.isRunning else { return }
        items.removeAll { selection.contains($0.id) }
        selection = []
        if let f = focusedID, !items.contains(where: { $0.id == f }) { focusedID = items.first?.id }
        invalidateContext()
    }

    // MARK: - 选择

    func click(_ item: LibraryItem) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
        } else if flags.contains(.shift), let anchor = focusedID,
                  let a = items.firstIndex(where: { $0.id == anchor }),
                  let b = items.firstIndex(where: { $0.id == item.id }) {
            selection = Set(items[min(a, b)...max(a, b)].map(\.id))
        } else {
            selection = [item.id]
        }
        focusedID = item.id
    }

    func selectAll() { selection = Set(items.map(\.id)) }

    // MARK: - 输出

    func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        panel.message = "修复后的图片保存到这里（建议与原图分开的文件夹）"
        if let dir = outputDirectory?.deletingLastPathComponent() { panel.directoryURL = dir }
        if panel.runModal() == .OK, let url = panel.url { outputDirectory = url }
    }

    func revealOutput() {
        guard let dir = outputDirectory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    private func persistOutputDirectory() {
        UserDefaults.standard.set(outputDirectory?.path, forKey: Self.outputKey)
    }

    func planner() -> OutputPlanner? {
        guard let dir = outputDirectory else { return nil }
        return OutputPlanner(outputDirectory: dir, settings: settings, sources: items.map(\.url))
    }

    /// 某张图对应的修复结果（存在才返回）
    func existingOutput(for item: LibraryItem) -> URL? {
        guard let planner = planner(), let index = items.firstIndex(where: { $0.id == item.id }) else { return nil }
        let url = planner.intendedURL(for: item.url, index: index)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func refreshStatuses() {
        guard batch.isRunning == false else { return }
        for i in items.indices where items[i].status != .failed {
            items[i].status = existingOutput(for: items[i]) != nil ? .done : .pending
        }
    }

    private func setStatus(_ id: UUID, _ status: LibraryItem.Status) {
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].status = status }
    }

    // MARK: - 设置

    private func settingsChanged(from old: RestoreSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.settingsKey)
        }
        if old.timestampMode != settings.timestampMode || old.whiteBalance != settings.whiteBalance
            || old.autoLevels != settings.autoLevels || old.autoBrightness != settings.autoBrightness {
            invalidateContext()
        }
        if old.orientation != settings.orientation {
            loadCompare()
        }
        if old.nameTemplate != settings.nameTemplate || old.format != settings.format || old.scale != settings.scale {
            refreshStatuses()
            loadCompare()
        }
    }

    // MARK: - 整批分析（水印、底图、色彩）

    private func invalidateContext() {
        contextTask?.cancel()
        contextTask = nil
        contextGeneration += 1
        batchContext = nil
        contextInfo = nil
    }

    func ensureContext() async throws -> BatchContext? {
        if let ctx = batchContext { return ctx }
        if let task = contextTask { return try await task.value }
        let urls = items.map(\.url)
        let settings = self.settings
        let engine = self.engine
        analyzing = true
        let generation = contextGeneration
        let task = Task { try await engine.buildContext(urls: urls, settings: settings) }
        contextTask = task
        defer { analyzing = false }
        let ctx = try await task.value
        if generation == contextGeneration {
            batchContext = ctx
            contextInfo = describe(ctx)
        }
        return ctx
    }

    private func describe(_ ctx: BatchContext?) -> String {
        guard let ctx else { return "无法分析画面" }
        var parts = ["画面 \(ctx.width)×\(ctx.height)，背景底图来自 \(min(ctx.frameCount, 160)) 张"]
        if let r = ctx.timestampRect {
            parts.append("检测到时间水印（x \(r.x), y \(r.y), \(r.width)×\(r.height)）")
        } else if settings.timestampMode != .ignore {
            parts.append("未检测到时间水印")
        }
        return parts.joined(separator: "；")
    }

    // MARK: - 对比 / 试修

    func loadCompare() {
        guard let item = focusedItem else { compare = nil; return }
        let output = existingOutput(for: item)
        let id = item.id
        let orientation = settings.orientation
        Task {
            // 原图按设置的方向显示，与修复结果对齐
            let before = (try? ImageFiles.loadCGImage(item.url)).map { ImageFiles.apply(orientation, to: $0) }
            let after = output.flatMap { try? ImageFiles.loadCGImage($0) }
            guard focusedID == id, let before else { return }
            compare = ComparePair(itemID: id, before: before, after: after,
                                  note: after != nil ? "右侧为已保存的修复结果" : "还没有修复结果，点「试修当前图」预览效果")
        }
    }

    func renderPreview() {
        guard let item = focusedItem, !previewBusy else { return }
        previewBusy = true
        let id = item.id
        let settings = self.settings
        Task {
            defer { previewBusy = false }
            do {
                let ctx = try await ensureContext()
                let start = Date()
                let result = try await engine.restore(url: item.url, settings: settings, context: ctx)
                let seconds = Date().timeIntervalSince(start)
                guard focusedID == id else { return }
                let before: CGImage
                if let current = compare, current.itemID == id {
                    before = current.before
                } else {
                    before = try ImageFiles.apply(settings.orientation, to: ImageFiles.loadCGImage(item.url))
                }
                var note = String(format: "试修预览（未保存）：用时 %.1f 秒", seconds)
                note += result.facesRestored > 0 ? "，修复了 \(result.facesRestored) 张脸" : "，未检测到可修复的人脸"
                if !result.usedSuperResolutionModel { note += "；未找到超分模型，使用了普通放大" }
                compare = ComparePair(itemID: id, before: before, after: result.image, note: note)
            } catch {
                alertMessage = "试修失败：\(error.localizedDescription)"
            }
        }
    }

    // MARK: - 批处理

    func startBatch(onlySelected: Bool = false) {
        guard !batch.isRunning, !items.isEmpty else { return }
        if outputDirectory == nil { chooseOutputDirectory() }
        guard let out = outputDirectory else { return }
        let targets = onlySelected && !selection.isEmpty ? selectedItems : items

        do {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        } catch {
            alertMessage = "无法创建输出文件夹：\(error.localizedDescription)"
            return
        }
        // 磁盘空间预估
        if let size = ImageFiles.pixelSize(of: targets[0].url),
           let free = try? out.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage {
            let need = OutputPlanner.estimatedBytes(count: targets.count, inputWidth: size.width,
                                                    inputHeight: size.height, settings: settings)
            if need > free {
                alertMessage = "磁盘空间可能不够：预计需要 \(Self.bytes(need))，剩余 \(Self.bytes(free))。可以改用 HEIC 或 JPG 格式。"
                return
            }
        }

        batch = BatchState(isRunning: true, total: targets.count)
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                         reason: "批量修复图片")
        batchTask = Task { await runBatch(targets, output: out) }
    }

    func pauseOrResume() { if batch.isRunning { batch.isPaused.toggle() } }

    func cancelBatch() {
        batchTask?.cancel()
        batch.isPaused = false
    }

    private func runBatch(_ targets: [LibraryItem], output: URL) async {
        let settings = self.settings
        let planner = OutputPlanner(outputDirectory: output, settings: settings, sources: items.map(\.url))
        let indexOf = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.id, $0) })
        batch.note = "正在分析整批画面（时间水印、背景底图、色彩）…"
        let ctx: BatchContext?
        do {
            ctx = try await ensureContext()
        } catch {
            alertMessage = "分析画面失败：\(error.localizedDescription)"
            finishBatch(summary: "已停止")
            return
        }
        batch.note = nil
        var manifest = BatchManifest(startedAt: Date(), settings: settings, timestampRegion: ctx?.timestampRect,
                                     colorCorrection: ctx?.correction)
        var durations: [Double] = []

        for item in targets {
            if Task.isCancelled { break }
            while batch.isPaused && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            if Task.isCancelled { break }
            await coolDownIfNeeded()

            batch.currentName = item.name
            setStatus(item.id, .processing)
            do {
                switch try planner.decide(for: item.url, index: indexOf[item.id] ?? 0) {
                case .skip(let url):
                    setStatus(item.id, .done)
                    batch.skipped += 1
                    manifest.entries.append(.init(source: item.name, output: url.lastPathComponent, status: .skipped))
                case .write(let url, let replacing):
                    let start = Date()
                    let result = try await engine.restore(url: item.url, settings: settings, context: ctx)
                    let image = result.image
                    try await Task.detached(priority: .userInitiated) {
                        try ImageFiles.write(image, to: url, format: settings.format, quality: settings.jpegQuality,
                                             replacing: replacing)
                    }.value
                    let seconds = Date().timeIntervalSince(start)
                    durations.append(seconds)
                    setStatus(item.id, .done)
                    manifest.entries.append(.init(source: item.name, output: url.lastPathComponent, status: .done,
                                                  seconds: seconds))
                    if focusedID == item.id { loadCompare() }
                }
            } catch {
                setStatus(item.id, .failed)
                batch.failures.append("\(item.name)：\(error.localizedDescription)")
                manifest.entries.append(.init(source: item.name, output: nil, status: .failed,
                                              error: error.localizedDescription))
            }
            batch.done += 1
            let recent = durations.suffix(10)
            if !recent.isEmpty {
                batch.etaSeconds = recent.reduce(0, +) / Double(recent.count) * Double(batch.total - batch.done)
            }
            if batch.done % 10 == 0 { try? manifest.write(to: output) }
        }
        manifest.finishedAt = Date()
        try? manifest.write(to: output)
        let processed = batch.done - batch.skipped - batch.failures.count
        var summary = Task.isCancelled ? "已取消。" : "完成。"
        summary += "修复 \(processed) 张，跳过 \(batch.skipped) 张"
        if !batch.failures.isEmpty { summary += "，失败 \(batch.failures.count) 张" }
        finishBatch(summary: summary)
    }

    /// 无风扇的 MacBook Air 持续满载会发热降频：过热时主动歇一会儿
    private func coolDownIfNeeded() async {
        switch ProcessInfo.processInfo.thermalState {
        case .serious:
            batch.note = "电脑较热，已自动放慢速度"
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        case .critical:
            batch.note = "电脑过热，暂停几秒降温"
            try? await Task.sleep(nanoseconds: 8_000_000_000)
        default:
            if batch.note != nil, !analyzing { batch.note = nil }
        }
    }

    private func finishBatch(summary: String) {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        batchTask = nil
        let failures = batch.failures
        batch = BatchState(failures: failures, lastSummary: summary)
        refreshStatuses()
    }

    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) 秒" }
        if s < 3600 { return "\(s / 60) 分 \(s % 60) 秒" }
        return "\(s / 3600) 小时 \(s % 3600 / 60) 分"
    }

    // MARK: - 播放 / 导出

    enum PlayScope: String, CaseIterable, Identifiable {
        case selected, all, outputFolder
        var id: String { rawValue }
        var title: String {
            switch self {
            case .selected: return "选中的图"
            case .all: return "全部素材"
            case .outputFolder: return "输出文件夹"
            }
        }
    }

    enum PlaySource: String, CaseIterable, Identifiable {
        case restored, original, sideBySide
        var id: String { rawValue }
        var title: String {
            switch self {
            case .restored: return "修复后"
            case .original: return "原图"
            case .sideBySide: return "并排对比"
            }
        }
    }

    /// 按范围和画面生成播放列表。并排对比时返回（原图, 修复后）成对的列表
    func playlist(scope: PlayScope, source: PlaySource) -> (primary: [URL], compare: [URL]?) {
        if scope == .outputFolder {
            guard let dir = outputDirectory,
                  let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil,
                                                                           options: [.skipsHiddenFiles]) else {
                return ([], nil)
            }
            return (NaturalSort.sorted(files.filter(SupportedImage.isSupported)), nil)
        }
        let chosen = scope == .selected && !selection.isEmpty ? selectedItems : items
        switch source {
        case .original:
            return (chosen.map(\.url), nil)
        case .restored:
            return (chosen.compactMap { existingOutput(for: $0) }, nil)
        case .sideBySide:
            let pairs = chosen.compactMap { item in existingOutput(for: item).map { (item.url, $0) } }
            return (pairs.map(\.1), pairs.map(\.0))
        }
    }
}
