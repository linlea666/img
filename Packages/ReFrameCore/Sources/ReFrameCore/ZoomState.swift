import Foundation

/// 视图与图片的尺寸（点 / 像素）
public struct ZoomGeometry: Equatable, Sendable {
    public var viewWidth: Double
    public var viewHeight: Double
    public var imageWidth: Double
    public var imageHeight: Double

    public init(viewWidth: Double, viewHeight: Double, imageWidth: Double, imageHeight: Double) {
        self.viewWidth = viewWidth
        self.viewHeight = viewHeight
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
    }

    public var isValid: Bool { viewWidth > 0 && viewHeight > 0 && imageWidth > 0 && imageHeight > 0 }

    /// "适应窗口"时图片显示的大小
    public var fitWidth: Double { imageWidth * fitScale }
    public var fitHeight: Double { imageHeight * fitScale }
    var fitScale: Double { min(viewWidth / imageWidth, viewHeight / imageHeight) }
}

/// 局部放大的缩放 / 平移状态。
///
/// `zoom` 是相对"适应窗口"的倍数（1 = 整张图刚好放进窗口）；
/// `centerX/centerY` 是视图中心对准的图片位置（0...1，左上角为原点）。
/// 用归一化坐标表示，窗口大小变化、并排的两个画面都能共用同一个状态。
public struct ZoomState: Equatable, Sendable {
    public var zoom: Double
    public var centerX: Double
    public var centerY: Double

    public static let maxZoom = 40.0

    public init(zoom: Double = 1, centerX: Double = 0.5, centerY: Double = 0.5) {
        self.zoom = zoom
        self.centerX = centerX
        self.centerY = centerY
    }

    public struct Rect: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    public var isZoomed: Bool { zoom > 1.001 }

    /// 图片在视图里的显示位置
    public func displayRect(in g: ZoomGeometry) -> Rect {
        let w = g.fitWidth * zoom, h = g.fitHeight * zoom
        return Rect(x: g.viewWidth / 2 - centerX * w, y: g.viewHeight / 2 - centerY * h, width: w, height: h)
    }

    /// 限制范围：不小于适应窗口；放大后不能拖出黑边
    public func clamped(in g: ZoomGeometry) -> ZoomState {
        guard g.isValid else { return ZoomState() }
        let z = min(max(zoom, 1), Self.maxZoom)
        let w = g.fitWidth * z, h = g.fitHeight * z
        func clamp(_ c: Double, view: Double, size: Double) -> Double {
            guard size > view else { return 0.5 }
            let half = view / 2 / size
            return min(max(c, half), 1 - half)
        }
        return ZoomState(zoom: z, centerX: clamp(centerX, view: g.viewWidth, size: w),
                         centerY: clamp(centerY, view: g.viewHeight, size: h))
    }

    /// 以视图上的某一点为中心缩放（该点下的图片内容保持不动）
    public func zoomed(by factor: Double, atX px: Double, y py: Double, in g: ZoomGeometry) -> ZoomState {
        guard g.isValid, factor > 0 else { return self }
        let r = displayRect(in: g)
        let u = (px - r.x) / r.width, v = (py - r.y) / r.height
        let z = min(max(zoom * factor, 1), Self.maxZoom)
        let w = g.fitWidth * z, h = g.fitHeight * z
        let ox = px - u * w, oy = py - v * h
        return ZoomState(zoom: z, centerX: (g.viewWidth / 2 - ox) / w, centerY: (g.viewHeight / 2 - oy) / h)
            .clamped(in: g)
    }

    /// 平移（视图坐标的位移，单位：点）
    public func panned(dx: Double, dy: Double, in g: ZoomGeometry) -> ZoomState {
        guard g.isValid else { return self }
        let r = displayRect(in: g)
        return ZoomState(zoom: zoom, centerX: centerX - dx / r.width, centerY: centerY - dy / r.height).clamped(in: g)
    }

    public func centered(atX x: Double, y: Double, in g: ZoomGeometry) -> ZoomState {
        ZoomState(zoom: zoom, centerX: x, centerY: y).clamped(in: g)
    }

    /// 1 个图片像素对应几个屏幕像素
    public func pixelRatio(backingScale: Double, in g: ZoomGeometry) -> Double {
        guard g.isValid else { return 0 }
        return g.fitWidth * zoom * backingScale / g.imageWidth
    }

    /// 达到指定像素比例所需的 zoom
    public static func zoom(forPixelRatio ratio: Double, backingScale: Double, in g: ZoomGeometry) -> Double {
        guard g.isValid else { return 1 }
        return ratio * g.imageWidth / backingScale / g.fitWidth
    }

    /// 放大到某个区域（归一化矩形，左上角原点），让它占视图的 `fill` 比例
    public static func focusing(on rect: Rect, fill: Double, in g: ZoomGeometry) -> ZoomState {
        guard g.isValid, rect.width > 0, rect.height > 0 else { return ZoomState() }
        let zw = fill * g.viewWidth / (rect.width * g.fitWidth)
        let zh = fill * g.viewHeight / (rect.height * g.fitHeight)
        return ZoomState(zoom: min(zw, zh), centerX: rect.x + rect.width / 2, centerY: rect.y + rect.height / 2)
            .clamped(in: g)
    }
}
