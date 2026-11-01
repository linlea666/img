import AppKit
import ImageIO
import ReFrameCore
import ReFrameEngine
import SwiftUI

/// 解码缓存：后台解码并预读后面几帧，播放时不卡顿。
/// 1080p 一帧约 8MB，缓存上限 24 帧（约 200MB），照顾 8GB 内存。
actor FrameCache {
    struct Key: Hashable, Sendable {
        let url: URL
        let orientation: ImageOrientation
    }

    private var images: [Key: CGImage] = [:]
    private var order: [Key] = []
    private let limit = 24

    func image(for key: Key) -> CGImage? {
        if let hit = images[key] {
            touch(key)
            return hit
        }
        guard let source = CGImageSourceCreateWithURL(key.url as CFURL, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        let image = ImageFiles.apply(key.orientation, to: decoded)
        images[key] = image
        touch(key)
        while order.count > limit {
            let old = order.removeFirst()
            images[old] = nil
        }
        return image
    }

    func prefetch(_ keys: [Key]) {
        for key in keys where images[key] == nil { _ = image(for: key) }
    }

    func clear() {
        images = [:]
        order = []
    }

    private func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}

/// 图片序列播放器
@MainActor
final class PlayerModel: ObservableObject {
    @Published private(set) var frames: [URL] = []
    /// 并排对比时与 frames 一一对应的原图
    @Published private(set) var compareFrames: [URL]?
    @Published private(set) var index = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var current: CGImage?
    @Published private(set) var currentCompare: CGImage?
    @Published var fps: Double = 15
    @Published var mode: LoopMode = .loop { didSet { sequencer.mode = mode } }
    /// 主画面 / 对比画面的显示方向（原图需要按设置放正，修复结果已经是正的）
    private(set) var primaryOrientation: ImageOrientation = .identity
    private(set) var compareOrientation: ImageOrientation = .identity

    private var sequencer = PlaybackSequencer(count: 0, mode: .loop)
    private var loop: Task<Void, Never>?
    private let cache = FrameCache()

    var currentName: String { frames.indices.contains(index) ? frames[index].lastPathComponent : "" }

    func load(frames: [URL], compare: [URL]?, primaryOrientation: ImageOrientation = .identity,
              compareOrientation: ImageOrientation = .identity) {
        pause()
        self.frames = frames
        self.compareFrames = compare
        self.primaryOrientation = primaryOrientation
        self.compareOrientation = compareOrientation
        sequencer = PlaybackSequencer(count: frames.count, mode: mode)
        index = 0
        current = nil
        currentCompare = nil
        Task {
            await cache.clear()
            await show(0)
        }
    }

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard frames.count > 0, !isPlaying else { return }
        if mode == .once && index == frames.count - 1 { sequencer.seek(to: 0) }
        isPlaying = true
        loop = Task { [weak self] in
            while let self, self.isPlaying, !Task.isCancelled {
                let start = Date()
                if !self.sequencer.advance() {
                    self.isPlaying = false
                    break
                }
                await self.show(self.sequencer.index)
                let interval = 1.0 / max(self.fps, 1)
                let wait = interval - Date().timeIntervalSince(start)
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            }
        }
    }

    func pause() {
        isPlaying = false
        loop?.cancel()
        loop = nil
    }

    func step(_ delta: Int) {
        pause()
        if delta > 0 { sequencer.stepForward() } else { sequencer.stepBack() }
        Task { await show(sequencer.index) }
    }

    func seek(to i: Int) {
        sequencer.seek(to: i)
        Task { await show(sequencer.index) }
    }

    private func show(_ i: Int) async {
        guard frames.indices.contains(i) else { return }
        let url = frames[i]
        let compareURL = compareFrames.flatMap { $0.indices.contains(i) ? $0[i] : nil }
        let image = await cache.image(for: .init(url: url, orientation: primaryOrientation))
        var compareImage: CGImage?
        if let compareURL { compareImage = await cache.image(for: .init(url: compareURL, orientation: compareOrientation)) }
        index = i
        current = image
        currentCompare = compareImage
        // 预读接下来几帧（按当前方向）
        let dir = sequencer.direction
        var upcoming: [FrameCache.Key] = []
        for k in 1...6 {
            var j = i + k * dir
            if mode != .once { j = (j % frames.count + frames.count) % frames.count }
            guard frames.indices.contains(j) else { break }
            upcoming.append(.init(url: frames[j], orientation: primaryOrientation))
            if let c = compareFrames, c.indices.contains(j) {
                upcoming.append(.init(url: c[j], orientation: compareOrientation))
            }
        }
        let cache = self.cache
        Task.detached(priority: .utility) { await cache.prefetch(upcoming) }
    }
}
