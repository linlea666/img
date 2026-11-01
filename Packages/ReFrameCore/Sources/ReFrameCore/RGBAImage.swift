import Foundation

/// 左上角为原点的整数矩形（像素坐标）。
public struct PixelRect: Codable, Equatable, Hashable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Int { x + width }
    public var maxY: Int { y + height }
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    public func contains(x px: Int, y py: Int) -> Bool {
        px >= x && px < maxX && py >= y && py < maxY
    }

    /// 向四周扩展 `amount` 像素，并限制在 `width × height` 的画面内
    public func expanded(by amount: Int, within w: Int, _ h: Int) -> PixelRect {
        let nx = max(0, x - amount), ny = max(0, y - amount)
        let nmx = min(w, maxX + amount), nmy = min(h, maxY + amount)
        return PixelRect(x: nx, y: ny, width: max(0, nmx - nx), height: max(0, nmy - ny))
    }

    public func scaled(by factor: Int) -> PixelRect {
        PixelRect(x: x * factor, y: y * factor, width: width * factor, height: height * factor)
    }
}

/// 简单的 8 位 RGBA 位图（非预乘、行优先、第一行是画面顶部）。
/// 原始帧只有 240×135，许多处理直接在 CPU 上做既简单又可测试。
public struct RGBAImage: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height * 4, "像素数量与尺寸不符")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public init(width: Int, height: Int, fill: (r: UInt8, g: UInt8, b: UInt8) = (0, 0, 0)) {
        self.width = width
        self.height = height
        var p = [UInt8](repeating: 255, count: width * height * 4)
        var i = 0
        while i < p.count {
            p[i] = fill.r; p[i + 1] = fill.g; p[i + 2] = fill.b
            i += 4
        }
        self.pixels = p
    }

    @inline(__always) public func offset(_ x: Int, _ y: Int) -> Int { (y * width + x) * 4 }

    public func pixel(_ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let o = offset(x, y)
        return (pixels[o], pixels[o + 1], pixels[o + 2])
    }

    public mutating func setPixel(_ x: Int, _ y: Int, _ c: (r: UInt8, g: UInt8, b: UInt8)) {
        let o = offset(x, y)
        pixels[o] = c.r; pixels[o + 1] = c.g; pixels[o + 2] = c.b; pixels[o + 3] = 255
    }

    /// 裁剪；超出画面的部分用最近的边缘像素填充（便于分块推理时补边）
    public func cropClamped(_ rect: PixelRect) -> RGBAImage {
        var out = [UInt8](repeating: 255, count: rect.width * rect.height * 4)
        for row in 0..<rect.height {
            let sy = min(max(rect.y + row, 0), height - 1)
            for col in 0..<rect.width {
                let sx = min(max(rect.x + col, 0), width - 1)
                let s = offset(sx, sy)
                let d = (row * rect.width + col) * 4
                out[d] = pixels[s]; out[d + 1] = pixels[s + 1]; out[d + 2] = pixels[s + 2]; out[d + 3] = 255
            }
        }
        return RGBAImage(width: rect.width, height: rect.height, pixels: out)
    }

    /// 把 `source` 中 `sourceRect` 区域贴到本图 (x, y)，超出部分自动忽略
    public mutating func paste(_ source: RGBAImage, from sourceRect: PixelRect? = nil, atX x: Int, y: Int) {
        let src = sourceRect ?? PixelRect(x: 0, y: 0, width: source.width, height: source.height)
        for row in 0..<src.height {
            let dy = y + row, sy = src.y + row
            guard dy >= 0, dy < height, sy >= 0, sy < source.height else { continue }
            for col in 0..<src.width {
                let dx = x + col, sx = src.x + col
                guard dx >= 0, dx < width, sx >= 0, sx < source.width else { continue }
                let s = source.offset(sx, sy), d = offset(dx, dy)
                pixels[d] = source.pixels[s]
                pixels[d + 1] = source.pixels[s + 1]
                pixels[d + 2] = source.pixels[s + 2]
                pixels[d + 3] = 255
            }
        }
    }

    /// 用另一张同尺寸图片替换矩形区域
    public mutating func replace(_ rect: PixelRect, from other: RGBAImage) {
        precondition(other.width == width && other.height == height, "尺寸不一致")
        paste(other, from: rect, atX: rect.x, y: rect.y)
    }

    /// 平均亮度（0...255）
    public var meanLuma: Double {
        var sum = 0.0
        var i = 0
        while i < pixels.count {
            sum += 0.299 * Double(pixels[i]) + 0.587 * Double(pixels[i + 1]) + 0.114 * Double(pixels[i + 2])
            i += 4
        }
        return sum / Double(max(1, width * height))
    }
}
