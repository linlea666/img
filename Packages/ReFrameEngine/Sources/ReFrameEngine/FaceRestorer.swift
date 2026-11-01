import CoreImage
import CoreImage.CIFilterBuiltins
import CoreML
import Foundation
import ImageIO
import ReFrameCore
import Vision

/// 人脸修复：Vision 找脸和关键点 → 按 FFHQ 模板对齐裁出 512×512 → GFPGAN → 颜色匹配 → 柔和回贴。
///
/// 坐标统一用 Core Image / Vision 的左下角原点。
final class FaceRestorer {
    static let modelName = "GFPGANv14"
    static let size = 512

    private let model: MLModel
    private let context: CIContext

    init(modelURL: URL, computeUnits: MLComputeUnits, context: CIContext) throws {
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        model = try MLModel(contentsOf: modelURL, configuration: config)
        self.context = context
    }

    struct DetectedFace {
        /// 原图坐标（左下角原点）下的五个关键点：左眼、右眼、鼻尖、左嘴角、右嘴角
        var points: [Point2]
        var bounds: CGRect
        var eyeDistance: Double {
            let dx = points[1].x - points[0].x, dy = points[1].y - points[0].y
            return (dx * dx + dy * dy).squareRoot()
        }
    }

    /// 返回处理后的图像和修复的人脸数量
    func restore(_ image: CIImage, cgImage: CGImage, strength: Double) throws -> (CIImage, Int) {
        let faces = try detectFaces(cgImage)
        guard !faces.isEmpty, strength > 0 else { return (image, 0) }
        var result = image
        var count = 0
        for face in faces {
            // 眼距太小（原图里约 3 像素以下）的脸修了也只是"贴一张假脸"，跳过
            guard face.eyeDistance >= 12 else { continue }
            // 小脸降低强度
            let sizeFactor = min(1.0, max(0.4, (face.eyeDistance - 12) / 40 + 0.4))
            result = try restoreFace(face, in: result, strength: strength * sizeFactor)
            count += 1
        }
        return (result, count)
    }

    // MARK: - 检测

    func detectFaces(_ cgImage: CGImage) throws -> [DetectedFace] {
        let w = Double(cgImage.width), h = Double(cgImage.height)
        var faces: [DetectedFace] = []
        // 正向找一遍；人弯腰靠近镜头时脸可能是倒着的，再按倒置方向找一遍
        for orientation in [CGImagePropertyOrientation.up, .down] {
            let request = VNDetectFaceLandmarksRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
            try handler.perform([request])
            for observation in request.results ?? [] {
                guard let pts = keyPoints(observation, imageSize: CGSize(width: w, height: h)) else { continue }
                // 在"摆正后"的坐标里排好顺序，再映射回原图坐标
                let mapped: [Point2] = orientation == .down ? pts.map { Point2(w - $0.x, h - $0.y) } : pts
                let box = observation.boundingBox
                var rect = CGRect(x: box.minX * w, y: box.minY * h, width: box.width * w, height: box.height * h)
                if orientation == .down {
                    rect = CGRect(x: w - rect.maxX, y: h - rect.maxY, width: rect.width, height: rect.height)
                }
                // 与已找到的脸重叠则跳过
                if faces.contains(where: { iou($0.bounds, rect) > 0.3 }) { continue }
                faces.append(DetectedFace(points: mapped, bounds: rect))
            }
        }
        return faces
    }

    private func keyPoints(_ face: VNFaceObservation, imageSize: CGSize) -> [Point2]? {
        guard let lm = face.landmarks else { return nil }
        func centroid(_ region: VNFaceLandmarkRegion2D?) -> Point2? {
            guard let pts = region?.pointsInImage(imageSize: imageSize), !pts.isEmpty else { return nil }
            let sx = pts.reduce(0.0) { $0 + Double($1.x) }, sy = pts.reduce(0.0) { $0 + Double($1.y) }
            return Point2(sx / Double(pts.count), sy / Double(pts.count))
        }
        guard let e1 = centroid(lm.leftPupil) ?? centroid(lm.leftEye),
              let e2 = centroid(lm.rightPupil) ?? centroid(lm.rightEye),
              let nose = centroid(lm.nose) ?? centroid(lm.noseCrest),
              let lips = lm.outerLips?.pointsInImage(imageSize: imageSize), lips.count >= 2 else { return nil }
        let eyes = [e1, e2].sorted { $0.x < $1.x }
        guard let ml = lips.min(by: { $0.x < $1.x }), let mr = lips.max(by: { $0.x < $1.x }) else { return nil }
        return [eyes[0], eyes[1], nose, Point2(Double(ml.x), Double(ml.y)), Point2(Double(mr.x), Double(mr.y))]
    }

    private func iou(_ a: CGRect, _ b: CGRect) -> Double {
        let inter = a.intersection(b)
        guard !inter.isNull else { return 0 }
        let i = inter.width * inter.height
        return Double(i / (a.width * a.height + b.width * b.height - i))
    }

    // MARK: - 修复与回贴

    private func restoreFace(_ face: DetectedFace, in image: CIImage, strength: Double) throws -> CIImage {
        guard let t = SimilarityTransform.fit(from: face.points, to: FaceTemplate.pointsBottomLeft) else { return image }
        let forward = CGAffineTransform(a: t.a, b: t.b, c: -t.b, d: t.a, tx: t.tx, ty: t.ty)
        let inverse = forward.inverted()
        let square = CGRect(x: 0, y: 0, width: Self.size, height: Self.size)

        // 1. 对齐裁剪
        let aligned = image.clampedToExtent().transformed(by: forward).cropped(to: square)
        let input = try PixelBuffers.make(width: Self.size, height: Self.size)
        context.render(aligned, to: input, bounds: square, colorSpace: ImageFiles.sRGB)

        // 2. 推理
        let provider = try MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(pixelBuffer: input)])
        let out = try model.prediction(from: provider)
        guard let buffer = out.featureValue(for: "output")?.imageBufferValue else {
            throw EngineError.modelOutput("人脸修复模型")
        }
        var restored = CIImage(cvPixelBuffer: buffer)

        // 3. 颜色匹配：让修复后的脸与原来的平均颜色一致，避免"脸和脖子两个颜色"
        let center = CGRect(x: 160, y: 120, width: 192, height: 240)
        if let before = averageColor(aligned, in: center), let after = averageColor(restored, in: center) {
            func gain(_ a: Double, _ b: Double) -> CGFloat { CGFloat(min(max(a / max(b, 1e-3), 0.8), 1.25)) }
            let m = CIFilter.colorMatrix()
            m.inputImage = restored
            m.rVector = CIVector(x: gain(before.r, after.r), y: 0, z: 0, w: 0)
            m.gVector = CIVector(x: 0, y: gain(before.g, after.g), z: 0, w: 0)
            m.bVector = CIVector(x: 0, y: 0, z: gain(before.b, after.b), w: 0)
            restored = m.outputImage?.cropped(to: square) ?? restored
        }

        // 4. 柔和的圆形遮罩（中心白、边缘渐黑），强度决定最大不透明度
        let s = CGFloat(min(max(strength, 0), 1))
        let gradient = CIFilter.radialGradient()
        gradient.center = CGPoint(x: 256, y: 250)
        gradient.radius0 = 150
        gradient.radius1 = 240
        gradient.color0 = CIColor(red: s, green: s, blue: s)
        gradient.color1 = CIColor(red: 0, green: 0, blue: 0)
        guard let mask = gradient.outputImage?.cropped(to: square) else { return image }

        // 5. 逆变换回原图并混合
        let blend = CIFilter.blendWithMask()
        blend.inputImage = restored.transformed(by: inverse)
        blend.backgroundImage = image
        blend.maskImage = mask.transformed(by: inverse)
        return blend.outputImage?.cropped(to: image.extent) ?? image
    }

    private func averageColor(_ image: CIImage, in rect: CGRect) -> (r: Double, g: Double, b: Double)? {
        let filter = CIFilter.areaAverage()
        filter.inputImage = image
        filter.extent = rect
        guard let out = filter.outputImage else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        context.render(out, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: ImageFiles.sRGB)
        return (Double(px[0]), Double(px[1]), Double(px[2]))
    }
}
