import Foundation

/// 二维点（不依赖 CoreGraphics，方便在纯逻辑包里测试）
public struct Point2: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
}

/// 相似变换（旋转 + 等比缩放 + 平移）：
///     x' = a·x − b·y + tx
///     y' = b·x + a·y + ty
public struct SimilarityTransform: Equatable, Sendable {
    public var a: Double
    public var b: Double
    public var tx: Double
    public var ty: Double

    public init(a: Double, b: Double, tx: Double, ty: Double) {
        self.a = a; self.b = b; self.tx = tx; self.ty = ty
    }

    public func apply(_ p: Point2) -> Point2 {
        Point2(a * p.x - b * p.y + tx, b * p.x + a * p.y + ty)
    }

    public var scale: Double { (a * a + b * b).squareRoot() }

    public var inverse: SimilarityTransform {
        let d = a * a + b * b
        let ia = a / d, ib = -b / d
        // 逆变换：p = R⁻¹ (p' − t)
        return SimilarityTransform(a: ia, b: ib, tx: -(ia * tx - ib * ty), ty: -(ib * tx + ia * ty))
    }

    /// 最小二乘拟合：把 `source` 点映射到 `target` 点
    public static func fit(from source: [Point2], to target: [Point2]) -> SimilarityTransform? {
        guard source.count == target.count, source.count >= 2 else { return nil }
        let n = Double(source.count)
        let msx = source.map(\.x).reduce(0, +) / n, msy = source.map(\.y).reduce(0, +) / n
        let mtx = target.map(\.x).reduce(0, +) / n, mty = target.map(\.y).reduce(0, +) / n
        var sxx = 0.0, sab = 0.0, sba = 0.0
        for (s, t) in zip(source, target) {
            let sx = s.x - msx, sy = s.y - msy, tx = t.x - mtx, ty = t.y - mty
            sxx += sx * sx + sy * sy
            sab += sx * tx + sy * ty
            sba += sx * ty - sy * tx
        }
        guard sxx > 1e-9 else { return nil }
        let a = sab / sxx, b = sba / sxx
        return SimilarityTransform(a: a, b: b, tx: mtx - (a * msx - b * msy), ty: mty - (b * msx + a * msy))
    }
}

/// GFPGAN / FFHQ 使用的 512×512 人脸模板（左上角为原点）：左眼、右眼、鼻尖、左嘴角、右嘴角
/// （"左"指画面左侧）
public enum FaceTemplate {
    public static let size = 512.0
    public static let points: [Point2] = [
        Point2(192.98138, 239.94708),
        Point2(318.90277, 240.19360),
        Point2(256.63416, 314.01935),
        Point2(201.26117, 371.41043),
        Point2(313.08905, 371.15118),
    ]

    /// 左下角为原点的版本（Core Image / Vision 的坐标系）
    public static var pointsBottomLeft: [Point2] {
        points.map { Point2($0.x, size - $0.y) }
    }
}
