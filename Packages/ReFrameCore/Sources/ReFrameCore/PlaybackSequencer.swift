import Foundation

/// 播放方式
public enum LoopMode: String, Codable, CaseIterable, Sendable {
    case once, loop, pingPong

    public var title: String {
        switch self {
        case .once: return "单次"
        case .loop: return "循环"
        case .pingPong: return "往返"
        }
    }
}

/// 播放序列：决定下一帧是哪一张。
public struct PlaybackSequencer: Equatable, Sendable {
    public private(set) var count: Int
    public private(set) var index: Int
    public var mode: LoopMode
    /// +1 正向，-1 反向（往返模式下会切换）
    public private(set) var direction: Int = 1

    public init(count: Int, mode: LoopMode, index: Int = 0) {
        self.count = max(0, count)
        self.mode = mode
        self.index = count == 0 ? 0 : min(max(index, 0), count - 1)
    }

    /// 前进一帧；返回 false 表示播放结束（仅单次模式）
    @discardableResult
    public mutating func advance() -> Bool {
        guard count > 1 else { return mode != .once && count == 1 }
        switch mode {
        case .once:
            if index + 1 >= count { return false }
            index += 1
        case .loop:
            index = (index + 1) % count
        case .pingPong:
            var next = index + direction
            if next >= count || next < 0 {
                direction = -direction
                next = index + direction
            }
            index = next
        }
        return true
    }

    /// 逐帧后退（手动操作，不受模式影响，循环取模）
    public mutating func stepBack() {
        guard count > 0 else { return }
        index = (index - 1 + count) % count
    }

    public mutating func stepForward() {
        guard count > 0 else { return }
        index = (index + 1) % count
    }

    public mutating func seek(to i: Int) {
        guard count > 0 else { return }
        index = min(max(i, 0), count - 1)
    }

    /// 导出视频时的帧顺序：往返 = 正放后接倒放（不重复首尾帧），再重复 `repeats` 次
    public static func exportOrder(count: Int, mode: LoopMode, repeats: Int) -> [Int] {
        guard count > 0 else { return [] }
        var one = Array(0..<count)
        if mode == .pingPong && count > 2 {
            one += Array((1..<(count - 1)).reversed())
        }
        let times = mode == .once ? 1 : max(1, repeats)
        return Array((0..<times).map { _ in one }.joined())
    }
}
