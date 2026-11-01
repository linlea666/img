import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreML
import Foundation
import ReFrameCore

/// 整批共用的信息：时间水印位置、背景底图、统一的色彩校正参数。
/// 整批只算一次，所有帧用同一组参数，播放时不会忽明忽暗。
public struct BatchContext: Sendable {
    public var width: Int
    public var height: Int
    public var frameCount: Int
    public var timestampRect: PixelRect?
    /// 背景底图（已补全水印区域）
    public var plate: RGBAImage?
    public var correction: ColorCorrection

    public init(width: Int, height: Int, frameCount: Int, timestampRect: PixelRect?, plate: RGBAImage?,
                correction: ColorCorrection) {
        self.width = width
        self.height = height
        self.frameCount = frameCount
        self.timestampRect = timestampRect
        self.plate = plate
        self.correction = correction
    }
}

/// 单帧处理结果
public struct RestoreResult: @unchecked Sendable {
    public var image: CGImage
    public var facesRestored: Int
    public var usedSuperResolutionModel: Bool
}

/// 修复引擎。模型按需加载并常驻（FP16 下两个模型合计约 200MB，8GB 内存可承受）。
public actor RestorationEngine {
    public struct ModelStatus: Sendable, Equatable {
        public var superResolution: Bool
        public var face: Bool
    }

    private let modelsDirectory: URL?
    private let ciContext: CIContext
    private var superResolver: SuperResolver?
    private var faceRestorer: FaceRestorer?
    private var loadedUnits: RestoreSettings.ComputeUnits?

    public init(modelsDirectory: URL?) {
        self.modelsDirectory = modelsDirectory
        self.ciContext = CIContext(options: [
            .workingColorSpace: ImageFiles.sRGB,
            .outputColorSpace: ImageFiles.sRGB,
            .cacheIntermediates: false,
        ])
    }

    private func modelURL(_ name: String) -> URL? {
        guard let dir = modelsDirectory else { return nil }
        let url = dir.appendingPathComponent("\(name).mlmodelc")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func modelStatus() -> ModelStatus {
        ModelStatus(superResolution: modelURL(SuperResolver.modelName) != nil,
                    face: modelURL(FaceRestorer.modelName) != nil)
    }

    private static func mlUnits(_ units: RestoreSettings.ComputeUnits) -> MLComputeUnits {
        switch units {
        case .all: return .all
        case .neuralEngine: return .cpuAndNeuralEngine
        case .gpu: return .cpuAndGPU
        case .cpu: return .cpuOnly
        }
    }

    private func ensureModels(_ settings: RestoreSettings) throws {
        if loadedUnits != settings.computeUnits {
            superResolver = nil
            faceRestorer = nil
            loadedUnits = settings.computeUnits
        }
        let units = Self.mlUnits(settings.computeUnits)
        if superResolver == nil, let url = modelURL(SuperResolver.modelName) {
            superResolver = try SuperResolver(modelURL: url, computeUnits: units, context: ciContext)
        }
        if settings.faceRestore, faceRestorer == nil, let url = modelURL(FaceRestorer.modelName) {
            faceRestorer = try FaceRestorer(modelURL: url, computeUnits: units, context: ciContext)
        }
    }

    /// 释放模型（内存紧张时调用）
    public func unloadModels() {
        superResolver = nil
        faceRestorer = nil
        loadedUnits = nil
    }

    // MARK: - 批处理上下文

    public func buildContext(urls: [URL], settings: RestoreSettings) throws -> BatchContext? {
        guard let first = urls.first, let size = ImageFiles.pixelSize(of: first) else { return nil }
        // 均匀抽样（底图最多 160 张，水印检测用其中 60 张）
        let sameSize = urls.filter { url in
            guard let s = ImageFiles.pixelSize(of: url) else { return false }
            return s.width == size.width && s.height == size.height
        }
        let maxFrames = 160
        let sample: [URL]
        if sameSize.count > maxFrames {
            let step = Double(sameSize.count) / Double(maxFrames)
            sample = (0..<maxFrames).map { sameSize[Int(Double($0) * step)] }
        } else {
            sample = sameSize
        }
        var frames: [RGBAImage] = []
        frames.reserveCapacity(sample.count)
        for url in sample {
            try autoreleasepool {
                frames.append(try ImageFiles.loadRGBA(url))
            }
        }
        guard !frames.isEmpty else { return nil }

        var rect: PixelRect?
        if settings.timestampMode != .ignore {
            let step = max(1, frames.count / 60)
            rect = TimestampDetector.detect(in: stride(from: 0, to: frames.count, by: step).map { frames[$0] })
        }
        var plate = BackgroundPlate.median(of: frames, maxFrames: maxFrames)
        if let r = rect, let p = plate {
            plate = BackgroundPlate.inpaint(p, rect: r)
        }
        let correction = ColorCorrection.estimate(from: plate ?? frames[0], whiteBalance: settings.whiteBalance,
                                                  autoLevels: settings.autoLevels,
                                                  autoBrightness: settings.autoBrightness, excluding: rect)
        return BatchContext(width: size.width, height: size.height, frameCount: sameSize.count,
                            timestampRect: rect, plate: plate, correction: correction)
    }

    // MARK: - 单帧修复

    public func restore(url: URL, settings: RestoreSettings, context: BatchContext?) throws -> RestoreResult {
        try ensureModels(settings)
        let frame = try ImageFiles.loadRGBA(url)
        return try restore(frame: frame, settings: settings, context: context)
    }

    public func restore(frame: RGBAImage, settings: RestoreSettings, context: BatchContext?) throws -> RestoreResult {
        try ensureModels(settings)
        var working = frame
        let matchesContext = context.map { $0.width == frame.width && $0.height == frame.height } ?? false

        // 1. 时间水印：用底图把水印区域盖掉，模型永远看不到数字
        var keptPatch: RGBAImage?
        if matchesContext, let ctx = context, let rect = ctx.timestampRect, settings.timestampMode != .ignore,
           let plate = ctx.plate {
            if settings.timestampMode == .keep { keptPatch = frame.cropClamped(rect) }
            working.replace(rect, from: plate)
        }

        // 2. 色彩校正（整批统一参数；单张没有上下文时现场估计）
        let correction = matchesContext ? context!.correction
            : ColorCorrection.estimate(from: frame, whiteBalance: settings.whiteBalance, autoLevels: settings.autoLevels,
                                       autoBrightness: settings.autoBrightness)
        correction.apply(to: &working)

        // 3. 超分 ×4（模型缺失时退化为 Lanczos）
        var image: CIImage
        var srCG: CGImage
        let usedModel: Bool
        if let sr = superResolver {
            let up = try sr.upscale(working)
            srCG = ImageFiles.cgImage(from: up)
            image = CIImage(cgImage: srCG)
            usedModel = true
        } else {
            image = lanczos(CIImage(cgImage: ImageFiles.cgImage(from: working)), scale: 4)
            srCG = try render(image)
            image = CIImage(cgImage: srCG)
            usedModel = false
        }

        // 4. 人脸修复
        var faces = 0
        if settings.faceRestore, let restorer = faceRestorer {
            let (restored, n) = try restorer.restore(image, cgImage: srCG, strength: settings.faceStrength)
            image = restored
            faces = n
        }

        // 5. ×2 到最终尺寸 + 锐化
        if settings.scale == .x8 {
            image = lanczos(image, scale: 2)
        }
        if settings.sharpen > 0 {
            let extent = image.extent
            let f = CIFilter.unsharpMask()
            f.inputImage = image.clampedToExtent()
            f.radius = settings.scale == .x8 ? 2.5 : 1.5
            f.intensity = Float(settings.sharpen * 0.8)
            image = f.outputImage?.cropped(to: extent) ?? image
        }
        var output = try render(image)
        let unrotatedWidth = output.width, unrotatedHeight = output.height

        // 6. 画面方向：AI 按原方向处理，最后转正
        output = ImageFiles.apply(settings.orientation, to: output)

        // 7. 原样保留水印：画面转正后，把正着的原始水印放大贴回原来的角上
        //   （摄像头倒装时画面是倒的，但时间文字是后叠加的、本来就是正的，不能跟着一起转）
        if let patch = keptPatch, let rect = context?.timestampRect {
            let target = rect.scaled(by: settings.scale.rawValue)
                .reanchored(inWidth: unrotatedWidth, height: unrotatedHeight, toWidth: output.width, height: output.height)
            output = paste(patch, at: target, onto: output)
        }
        return RestoreResult(image: output, facesRestored: faces, usedSuperResolutionModel: usedModel)
    }

    // MARK: - 工具

    private func lanczos(_ image: CIImage, scale: CGFloat) -> CIImage {
        let extent = image.extent
        let f = CIFilter.lanczosScaleTransform()
        f.inputImage = image.clampedToExtent()
        f.scale = Float(scale)
        f.aspectRatio = 1
        let target = CGRect(x: extent.minX * scale, y: extent.minY * scale,
                            width: (extent.width * scale).rounded(), height: (extent.height * scale).rounded())
        return (f.outputImage ?? image).cropped(to: target)
    }

    private func render(_ image: CIImage) throws -> CGImage {
        let rect = CGRect(x: 0, y: 0, width: image.extent.width.rounded(), height: image.extent.height.rounded())
        guard let cg = ciContext.createCGImage(image, from: rect, format: .RGBA8, colorSpace: ImageFiles.sRGB) else {
            throw EngineError.modelOutput("渲染")
        }
        return cg
    }

    private func paste(_ patch: RGBAImage, at rect: PixelRect, onto image: CGImage) -> CGImage {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: ImageFiles.sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            return image
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        let target = CGRect(x: rect.x, y: h - rect.maxY, width: rect.width, height: rect.height)
        ctx.draw(ImageFiles.cgImage(from: patch), in: target)
        return ctx.makeImage() ?? image
    }
}
