import Foundation

/// 背景底图：固定机位下，把多帧逐像素取中位数，走动的人物被"投票"去掉，噪点和压缩块被平均掉。
public enum BackgroundPlate {
    /// 逐像素中位数。帧数较多时均匀抽样到 `maxFrames` 张。
    public static func median(of frames: [RGBAImage], maxFrames: Int = 160) -> RGBAImage? {
        guard let first = frames.first else { return nil }
        let w = first.width, h = first.height
        var usable = frames.filter { $0.width == w && $0.height == h }
        guard !usable.isEmpty else { return nil }
        if usable.count > maxFrames {
            let step = Double(usable.count) / Double(maxFrames)
            usable = (0..<maxFrames).map { usable[Int(Double($0) * step)] }
        }
        let n = usable.count
        var out = [UInt8](repeating: 255, count: w * h * 4)
        var values = [UInt8](repeating: 0, count: n)
        for i in 0..<(w * h) {
            let o = i * 4
            for c in 0..<3 {
                for f in 0..<n { values[f] = usable[f].pixels[o + c] }
                out[o + c] = medianValue(&values)
            }
        }
        return RGBAImage(width: w, height: h, pixels: out)
    }

    /// 计数法求中位数（值域 0...255，比排序快）
    static func medianValue(_ values: inout [UInt8]) -> UInt8 {
        var hist = [Int](repeating: 0, count: 256)
        for v in values { hist[Int(v)] += 1 }
        let half = (values.count - 1) / 2
        var acc = 0
        for (v, c) in hist.enumerated() {
            acc += c
            if acc > half { return UInt8(v) }
        }
        return 255
    }

    /// 用周围像素平滑补全矩形区域（拉普拉斯插值，迭代求解）。
    /// 时间水印下面的背景在任何一帧都看不到，只能根据周围推断；墙面等平坦区域效果很好。
    public static func inpaint(_ image: RGBAImage, rect: PixelRect, iterations: Int = 400) -> RGBAImage {
        let r = rect.expanded(by: 0, within: image.width, image.height)
        guard !r.isEmpty else { return image }
        var result = image
        let w = r.width, h = r.height

        for c in 0..<3 {
            // 工作区：矩形外扩 1 像素作为固定边界
            func sample(_ x: Int, _ y: Int) -> Double {
                let cx = min(max(x, 0), image.width - 1), cy = min(max(y, 0), image.height - 1)
                return Double(image.pixels[image.offset(cx, cy) + c])
            }
            // 初值：上下边界按行线性插值，收敛更快
            var grid = [Double](repeating: 0, count: w * h)
            for yy in 0..<h {
                for xx in 0..<w {
                    let left = sample(r.x - 1, r.y + yy), right = sample(r.maxX, r.y + yy)
                    let top = sample(r.x + xx, r.y - 1), bottom = sample(r.x + xx, r.maxY)
                    let tx = Double(xx + 1) / Double(w + 1), ty = Double(yy + 1) / Double(h + 1)
                    grid[yy * w + xx] = 0.5 * ((1 - tx) * left + tx * right) + 0.5 * ((1 - ty) * top + ty * bottom)
                }
            }
            func value(_ xx: Int, _ yy: Int) -> Double {
                if xx < 0 || yy < 0 || xx >= w || yy >= h { return sample(r.x + xx, r.y + yy) }
                return grid[yy * w + xx]
            }
            for _ in 0..<iterations {
                var next = grid
                for yy in 0..<h {
                    for xx in 0..<w {
                        next[yy * w + xx] = 0.25 * (value(xx - 1, yy) + value(xx + 1, yy) + value(xx, yy - 1) + value(xx, yy + 1))
                    }
                }
                grid = next
            }
            for yy in 0..<h {
                for xx in 0..<w {
                    let o = result.offset(r.x + xx, r.y + yy) + c
                    result.pixels[o] = UInt8(min(max(grid[yy * w + xx].rounded(), 0), 255))
                }
            }
        }
        return result
    }
}
