import CoreImage
import CoreML
import Foundation
import ReFrameCore

/// Real-ESRGAN ×4 超分（Core ML）。模型输入固定 256×144，大图自动分块、带重叠拼接。
final class SuperResolver {
    static let modelName = "RealESRGANx4"
    static let tileWidth = 256
    static let tileHeight = 144
    static let factor = 4
    static let overlap = 12

    private let model: MLModel
    private let context: CIContext

    init(modelURL: URL, computeUnits: MLComputeUnits, context: CIContext) throws {
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        model = try MLModel(contentsOf: modelURL, configuration: config)
        self.context = context
    }

    /// 分块起点：相邻块重叠 2×overlap，最后一块贴齐末端
    static func tileOrigins(size: Int, tile: Int, overlap: Int) -> [Int] {
        guard size > tile else { return [0] }
        var origins: [Int] = []
        var x = 0
        while x + tile < size {
            origins.append(x)
            x += tile - 2 * overlap
        }
        origins.append(size - tile)
        return origins
    }

    func upscale(_ image: RGBAImage) throws -> RGBAImage {
        let f = Self.factor
        var output = RGBAImage(width: image.width * f, height: image.height * f)
        let xs = Self.tileOrigins(size: image.width, tile: Self.tileWidth, overlap: Self.overlap)
        let ys = Self.tileOrigins(size: image.height, tile: Self.tileHeight, overlap: Self.overlap)
        for (yi, ty) in ys.enumerated() {
            for (xi, tx) in xs.enumerated() {
                try autoreleasepool {
                    let tile = image.cropClamped(PixelRect(x: tx, y: ty, width: Self.tileWidth, height: Self.tileHeight))
                    let result = try predict(tile)
                    // 有效区域：去掉与相邻块重叠的一半，图像边缘不去
                    let x0 = xi == 0 ? 0 : tx + Self.overlap
                    let x1 = xi == xs.count - 1 ? image.width : tx + Self.tileWidth - Self.overlap
                    let y0 = yi == 0 ? 0 : ty + Self.overlap
                    let y1 = yi == ys.count - 1 ? image.height : ty + Self.tileHeight - Self.overlap
                    guard x1 > x0, y1 > y0 else { return }
                    let region = PixelRect(x: (x0 - tx) * f, y: (y0 - ty) * f, width: (x1 - x0) * f, height: (y1 - y0) * f)
                    output.paste(result, from: region, atX: x0 * f, y: y0 * f)
                }
            }
        }
        return output
    }

    private func predict(_ tile: RGBAImage) throws -> RGBAImage {
        let input = try PixelBuffers.make(from: tile)
        let provider = try MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(pixelBuffer: input)])
        let out = try model.prediction(from: provider)
        guard let buffer = out.featureValue(for: "output")?.imageBufferValue else {
            throw EngineError.modelOutput("超分模型")
        }
        return try PixelBuffers.rgba(from: buffer, context: context)
    }
}

public enum EngineError: LocalizedError {
    case modelOutput(String)
    case noContext

    public var errorDescription: String? {
        switch self {
        case .modelOutput(let name): return "\(name)没有返回图像"
        case .noContext: return "缺少批处理上下文"
        }
    }
}
