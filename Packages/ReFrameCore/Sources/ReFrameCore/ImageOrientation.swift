import Foundation

/// 旋转角度（顺时针）
public enum ImageRotation: Int, Codable, CaseIterable, Sendable {
    case none = 0
    case clockwise90 = 90
    case upsideDown = 180
    case counterClockwise90 = 270

    public var title: String {
        switch self {
        case .none: return "不转"
        case .clockwise90: return "顺时针 90°"
        case .upsideDown: return "180°（倒着的）"
        case .counterClockwise90: return "逆时针 90°"
        }
    }

    public var swapsDimensions: Bool { self == .clockwise90 || self == .counterClockwise90 }
}

/// 画面方向：先旋转，再（可选）左右镜像。
///
/// 只作用在输出和预览上：AI 按原方向处理（人脸修复本身会把脸摆正），写文件时再转正。
/// 旋转 90° 的整数倍只是重新排列像素，不损失画质。
public struct ImageOrientation: Codable, Equatable, Hashable, Sendable {
    public var rotation: ImageRotation
    public var flipHorizontal: Bool

    public init(rotation: ImageRotation = .none, flipHorizontal: Bool = false) {
        self.rotation = rotation
        self.flipHorizontal = flipHorizontal
    }

    public static let identity = ImageOrientation()

    public var isIdentity: Bool { rotation == .none && !flipHorizontal }

    /// 稳定的短描述，用于配方和缓存键
    public var key: String { "r\(rotation.rawValue)\(flipHorizontal ? "f" : "")" }

    public func outputSize(width: Int, height: Int) -> (width: Int, height: Int) {
        rotation.swapsDimensions ? (height, width) : (width, height)
    }
}

extension PixelRect {
    /// 把矩形按"离哪个角近就贴着哪个角"搬到另一尺寸的画面里（保持到边缘的距离）。
    /// 用于原样保留时间水印：画面转正后，水印仍然正着放在原来的角上（例如右下角）。
    public func reanchored(inWidth w: Int, height h: Int, toWidth nw: Int, height nh: Int) -> PixelRect {
        let nx: Int
        if x + width / 2 > w / 2 {
            nx = nw - (w - maxX) - width
        } else {
            nx = x
        }
        let ny: Int
        if y + height / 2 > h / 2 {
            ny = nh - (h - maxY) - height
        } else {
            ny = y
        }
        let cx = min(max(nx, 0), max(0, nw - width))
        let cy = min(max(ny, 0), max(0, nh - height))
        return PixelRect(x: cx, y: cy, width: min(width, nw), height: min(height, nh))
    }
}
