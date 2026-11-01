import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ReFrameCore

/// 把图片序列导出为视频（HEVC / H.264）。先写临时文件，成功后再移动到目标位置。
public enum VideoExporter {
    public enum Codec: String, CaseIterable, Sendable {
        case hevc, h264

        public var title: String { self == .hevc ? "HEVC（体积小，Mac/iPhone 通用）" : "H.264（兼容性最好）" }
    }

    public enum Quality: String, CaseIterable, Sendable {
        case high, medium, small

        public var title: String {
            switch self {
            case .high: return "高"
            case .medium: return "中"
            case .small: return "小文件"
            }
        }

        /// 1080p 下的平均码率
        func bitrate(codec: Codec, pixels: Int) -> Int {
            let base: Double
            switch self {
            case .high: base = codec == .hevc ? 14_000_000 : 20_000_000
            case .medium: base = codec == .hevc ? 7_000_000 : 10_000_000
            case .small: base = codec == .hevc ? 3_000_000 : 4_500_000
            }
            return Int(base * Double(pixels) / (1920.0 * 1080.0))
        }
    }

    public struct Options: Sendable {
        public var frames: [URL]
        public var fps: Int
        public var codec: Codec
        public var quality: Quality
        public var outputURL: URL
        /// 播放原图时与预览一致地转正
        public var orientation: ImageOrientation

        public init(frames: [URL], fps: Int, codec: Codec, quality: Quality, outputURL: URL,
                    orientation: ImageOrientation = .identity) {
            self.frames = frames
            self.fps = fps
            self.codec = codec
            self.quality = quality
            self.outputURL = outputURL
            self.orientation = orientation
        }
    }

    public enum ExportError: LocalizedError {
        case noFrames
        case writer(String)

        public var errorDescription: String? {
            switch self {
            case .noFrames: return "没有可导出的图片"
            case .writer(let s): return "写入视频失败：\(s)"
            }
        }
    }

    public static func export(_ options: Options, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let first = options.frames.first else { throw ExportError.noFrames }
        let firstImage = try ImageFiles.apply(options.orientation, to: ImageFiles.loadCGImage(first))
        // 编码器要求偶数尺寸
        let width = firstImage.width / 2 * 2, height = firstImage.height / 2 * 2

        let dir = options.outputURL.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(UUID().uuidString).\(options.outputURL.pathExtension)")
        let fileType: AVFileType = options.outputURL.pathExtension.lowercased() == "mov" ? .mov : .mp4
        let writer = try AVAssetWriter(outputURL: tmp, fileType: fileType)

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: options.quality.bitrate(codec: options.codec, pixels: width * height),
            AVVideoExpectedSourceFrameRateKey: options.fps,
            AVVideoMaxKeyFrameIntervalKey: max(1, options.fps * 2),
        ]
        if options.codec == .h264 {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }
        let settings: [String: Any] = [
            AVVideoCodecKey: options.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { throw ExportError.writer("不支持的编码设置") }
        writer.add(input)
        guard writer.startWriting() else { throw ExportError.writer(writer.error?.localizedDescription ?? "无法开始") }
        writer.startSession(atSourceTime: .zero)

        do {
            var cache: (URL, CGImage)? = (first, firstImage)
            for (i, url) in options.frames.enumerated() {
                try Task.checkCancellation()
                while !input.isReadyForMoreMediaData {
                    try Task.checkCancellation()
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
                let image: CGImage
                if let c = cache, c.0 == url { image = c.1 } else {
                    image = try ImageFiles.apply(options.orientation, to: ImageFiles.loadCGImage(url))
                    cache = (url, image)
                }
                guard let pool = adaptor.pixelBufferPool else { throw ExportError.writer("缓冲池不可用") }
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                guard let pb = buffer else { throw ExportError.writer("无法创建帧") }
                draw(image, into: pb, width: width, height: height)
                let time = CMTime(value: CMTimeValue(i), timescale: CMTimeScale(options.fps))
                guard adaptor.append(pb, withPresentationTime: time) else {
                    throw ExportError.writer(writer.error?.localizedDescription ?? "写入第 \(i + 1) 帧失败")
                }
                progress(Double(i + 1) / Double(options.frames.count))
            }
            input.markAsFinished()
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                writer.finishWriting { c.resume() }
            }
            guard writer.status == .completed else {
                throw ExportError.writer(writer.error?.localizedDescription ?? "未完成")
            }
            if FileManager.default.fileExists(atPath: options.outputURL.path) {
                _ = try FileManager.default.replaceItemAt(options.outputURL, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: options.outputURL)
            }
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    /// 等比缩放居中绘制，黑边填充
    private static func draw(_ image: CGImage, into buffer: CVPixelBuffer, width: Int, height: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                  space: ImageFiles.sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let s = min(Double(width) / Double(image.width), Double(height) / Double(image.height))
        let w = Double(image.width) * s, h = Double(image.height) * s
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: (Double(width) - w) / 2, y: (Double(height) - h) / 2, width: w, height: h))
    }
}
