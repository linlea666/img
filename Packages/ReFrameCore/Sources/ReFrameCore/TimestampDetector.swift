import Foundation

/// 检测摄像头叠加的时间水印（OSD 文字，常见为黄色/白色数字，位置固定）。
///
/// 思路：水印位置在整批帧里不变，而画面内容在变。统计每个像素"像水印颜色"的帧占比，
/// 占比高、且集中在画面下方或上方边缘的像素区域，就是水印。
public enum TimestampDetector {
    /// 像黄色 OSD 文字的像素
    @inline(__always) static func isOverlayYellow(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool {
        let r = Int(r), g = Int(g), b = Int(b)
        return r > 140 && g > 120 && b < 120 && r - b > 70 && g - b > 50
    }

    /// - Parameters:
    ///   - frames: 同尺寸的帧（建议抽样 20～60 张）
    ///   - minFraction: 像素在多少比例的帧里呈水印色才算水印
    /// - Returns: 水印所在矩形（已向外扩 2 像素），没检测到返回 nil
    public static func detect(in frames: [RGBAImage], minFraction: Double = 0.15) -> PixelRect? {
        guard let first = frames.first else { return nil }
        let w = first.width, h = first.height
        let usable = frames.filter { $0.width == w && $0.height == h }
        guard !usable.isEmpty else { return nil }

        var counts = [Int](repeating: 0, count: w * h)
        for frame in usable {
            for y in 0..<h {
                for x in 0..<w {
                    let p = frame.pixel(x, y)
                    if isOverlayYellow(p.r, p.g, p.b) { counts[y * w + x] += 1 }
                }
            }
        }
        let need = max(1, Int((Double(usable.count) * minFraction).rounded(.up)))

        // 只在画面上下各 30% 的边带里找（水印一般在角落或边缘）
        let band = max(1, Int(Double(h) * 0.3))
        var best: PixelRect?
        for region in [(0, band), (h - band, h)] {
            var minX = w, minY = h, maxX = -1, maxY = -1, n = 0
            for y in region.0..<region.1 {
                for x in 0..<w where counts[y * w + x] >= need {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                    n += 1
                }
            }
            // 至少要有一定数量的像素，且形状像一行文字（宽大于高）
            guard n >= 12, maxX >= minX else { continue }
            let rect = PixelRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
            guard rect.width >= rect.height else { continue }
            if best == nil || rect.width * rect.height > best!.width * best!.height { best = rect }
        }
        return best?.expanded(by: 2, within: w, h)
    }
}
