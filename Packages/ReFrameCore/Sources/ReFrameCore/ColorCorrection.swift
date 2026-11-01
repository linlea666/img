import Foundation

/// 色彩校正参数：白平衡增益 + 色阶拉伸 + 伽马。
///
/// 对一组连续帧只估计一次（用背景底图或整批统计），然后对每帧套用同一组参数，
/// 避免逐帧各自校正导致亮度、颜色忽明忽暗（循环播放时会闪）。
public struct ColorCorrection: Codable, Equatable, Sendable {
    public var gainR: Double
    public var gainG: Double
    public var gainB: Double
    /// 色阶：把 [black, white] 拉伸到 [0, 255]
    public var black: Double
    public var white: Double
    /// 伽马（<1 提亮暗部）
    public var gamma: Double

    public init(gainR: Double = 1, gainG: Double = 1, gainB: Double = 1,
                black: Double = 0, white: Double = 255, gamma: Double = 1) {
        self.gainR = gainR
        self.gainG = gainG
        self.gainB = gainB
        self.black = black
        self.white = white
        self.gamma = gamma
    }

    public static let identity = ColorCorrection()

    public var isIdentity: Bool { self == .identity }

    /// 估计校正参数。
    /// - Parameters:
    ///   - whiteBalance: 白平衡强度 0...1（灰度世界假设：整体平均颜色应为中性灰）
    ///   - autoLevels: 是否按亮度 0.5% / 99.5% 分位拉伸色阶
    ///   - autoBrightness: 拉伸后仍偏暗时，用伽马提亮暗部
    ///   - excluding: 统计时忽略的区域（例如时间水印）
    public static func estimate(from image: RGBAImage, whiteBalance: Double, autoLevels: Bool,
                                autoBrightness: Bool, excluding: PixelRect? = nil) -> ColorCorrection {
        var sumR = 0.0, sumG = 0.0, sumB = 0.0
        var count = 0
        var histogram = [Int](repeating: 0, count: 256)
        for y in 0..<image.height {
            for x in 0..<image.width {
                if let ex = excluding, ex.contains(x: x, y: y) { continue }
                let p = image.pixel(x, y)
                let r = Double(p.r), g = Double(p.g), b = Double(p.b)
                sumR += r; sumG += g; sumB += b
                count += 1
                histogram[Int((0.299 * r + 0.587 * g + 0.114 * b).rounded())] += 1
            }
        }
        guard count > 0 else { return .identity }
        let mr = max(sumR / Double(count), 1), mg = max(sumG / Double(count), 1), mb = max(sumB / Double(count), 1)
        let gray = (mr + mg + mb) / 3
        let strength = min(max(whiteBalance, 0), 1)
        func gain(_ m: Double) -> Double {
            let g = 1 + (gray / m - 1) * strength
            return min(max(g, 0.6), 1.6)
        }
        var c = ColorCorrection(gainR: gain(mr), gainG: gain(mg), gainB: gain(mb))

        if autoLevels {
            let lo = percentile(histogram, total: count, fraction: 0.005)
            let hi = percentile(histogram, total: count, fraction: 0.995)
            // 拉伸幅度设上限，避免噪点被过度放大
            if hi - lo >= 24 {
                c.black = min(Double(lo), 60)
                c.white = max(Double(hi), 170)
            }
        }
        if autoBrightness {
            // 估计校正后的平均亮度，偏暗则用伽马提亮，目标约 0.42
            let meanLuma = (0.299 * mr * c.gainR + 0.587 * mg * c.gainG + 0.114 * mb * c.gainB)
            let normalized = min(max((meanLuma - c.black) / max(c.white - c.black, 1), 0.01), 0.99)
            if normalized < 0.38 {
                let g = log(0.42) / log(normalized)
                c.gamma = min(max(g, 0.55), 1.0)
            }
        }
        return c
    }

    static func percentile(_ histogram: [Int], total: Int, fraction: Double) -> Int {
        let target = Int(Double(total) * fraction)
        var acc = 0
        for (value, n) in histogram.enumerated() {
            acc += n
            if acc > target { return value }
        }
        return 255
    }

    /// 生成查找表：每个通道 256 个值
    public func lookupTables() -> (r: [UInt8], g: [UInt8], b: [UInt8]) {
        func table(_ gain: Double) -> [UInt8] {
            (0..<256).map { v in
                var x = Double(v) * gain
                x = (x - black) / max(white - black, 1)
                x = min(max(x, 0), 1)
                if gamma != 1 { x = pow(x, gamma) }
                return UInt8((x * 255).rounded())
            }
        }
        return (table(gainR), table(gainG), table(gainB))
    }

    public func apply(to image: inout RGBAImage) {
        guard !isIdentity else { return }
        let t = lookupTables()
        var i = 0
        while i < image.pixels.count {
            image.pixels[i] = t.r[Int(image.pixels[i])]
            image.pixels[i + 1] = t.g[Int(image.pixels[i + 1])]
            image.pixels[i + 2] = t.b[Int(image.pixels[i + 2])]
            i += 4
        }
    }
}
