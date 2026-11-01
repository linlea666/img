import AppKit
import ImageIO
import ReFrameCore
import SwiftUI

/// 解码缓存：后台解码并预读后面几帧，播放时不卡顿。
/// 1080p 一帧约 8MB，缓存上限 24 帧（约 200MB），照顾 8GB 内存。
actor FrameCache {
    private var images: [URL: CGImage] = [:]
    private var order: [URL] = []
    private let limit = 24

    func image(for url: URL) -> CGImage? {
        if let hit = images[url] {
            touch(url)
            return hit
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        images[url] = image
        touch(url)
        while order.count > limit {
            let old = order.removeFirst()
            images[old] = nil
        }
        return image
    }

    func prefetch(_ urls: [URL]) {
        for url in urls where images[url] == nil { _ = image(for: url) }
    }

    func clear() {
        images = [:]
        order = []
    }

    private func touch(_ url: URL) {
        order.removeAll { $0 == url }
        order.append(url)
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

    private var sequencer = PlaybackSequencer(count: 0, mode: .loop)
    private var loop: Task<Void, Never>?
    private let cache = FrameCache()

    var currentName: String { frames.indices.contains(index) ? frames[index].lastPathComponent : "" }

    func load(frames: [URL], compare: [URL]?) {
        pause()
        self.frames = frames
        self.compareFrames = compare
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
        let image = await cache.image(for: url)
        var compareImage: CGImage?
        if let compareURL { compareImage = await cache.image(for: compareURL) }
        index = i
        current = image
        currentCompare = compareImage
        // 预读接下来几帧（按当前方向）
        let dir = sequencer.direction
        var upcoming: [URL] = []
        for k in 1...6 {
            var j = i + k * dir
            if mode != .once { j = (j % frames.count + frames.count) % frames.count }
            guard frames.indices.contains(j) else { break }
            upcoming.append(frames[j])
            if let c = compareFrames, c.indices.contains(j) { upcoming.append(c[j]) }
        }
        let cache = self.cache
        Task.detached(priority: .utility) { await cache.prefetch(upcoming) }
    }
}
