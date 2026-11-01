import CoreGraphics
import Foundation
import ImageIO
import Vision

/// 只找人脸位置（不修复），用于"一键放大到人脸"。
public enum FaceLocator {
    /// 返回归一化矩形（0...1，左上角原点），按从左到右排序。正向和倒置各找一遍。
    public static func locate(in image: CGImage) -> [CGRect] {
        var faces: [CGRect] = []
        for orientation in [CGImagePropertyOrientation.up, .down] {
            let request = VNDetectFaceRectanglesRequest()
            let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
            guard (try? handler.perform([request])) != nil else { continue }
            for observation in request.results ?? [] {
                let b = observation.boundingBox   // 左下角原点
                let rect = orientation == .down
                    ? CGRect(x: 1 - b.maxX, y: b.minY, width: b.width, height: b.height)
                    : CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
                if faces.contains(where: { overlap($0, rect) > 0.3 }) { continue }
                faces.append(rect)
            }
        }
        return faces.sorted { $0.minX < $1.minX }
    }

    private static func overlap(_ a: CGRect, _ b: CGRect) -> Double {
        let i = a.intersection(b)
        guard !i.isNull else { return 0 }
        let inter = i.width * i.height
        return Double(inter / (a.width * a.height + b.width * b.height - inter))
    }
}
