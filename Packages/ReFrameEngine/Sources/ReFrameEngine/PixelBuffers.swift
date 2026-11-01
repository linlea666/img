import CoreImage
import CoreVideo
import Foundation
import ReFrameCore

/// CVPixelBuffer 与 RGBAImage 互转（Core ML 图像输入输出用 32BGRA）
enum PixelBuffers {
    enum BufferError: LocalizedError {
        case create
        var errorDescription: String? { "无法创建图像缓冲区" }
    }

    static func make(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                         attrs as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw BufferError.create }
        return buffer
    }

    /// RGBA → 新建的 BGRA 缓冲区
    static func make(from image: RGBAImage) throws -> CVPixelBuffer {
        let buffer = try make(width: image.width, height: image.height)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        image.pixels.withUnsafeBufferPointer { src in
            for y in 0..<image.height {
                let row = base + y * rowBytes
                var s = y * image.width * 4
                for x in 0..<image.width {
                    let d = x * 4
                    row[d] = src[s + 2]      // B
                    row[d + 1] = src[s + 1]  // G
                    row[d + 2] = src[s]      // R
                    row[d + 3] = 255
                    s += 4
                }
            }
        }
        return buffer
    }

    /// 任意格式的缓冲区 → RGBAImage（非 BGRA 时先用 Core Image 转换）
    static func rgba(from buffer: CVPixelBuffer, context: CIContext) throws -> RGBAImage {
        var source = buffer
        if CVPixelBufferGetPixelFormatType(buffer) != kCVPixelFormatType_32BGRA {
            let converted = try make(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
            context.render(CIImage(cvPixelBuffer: buffer), to: converted)
            source = converted
        }
        let w = CVPixelBufferGetWidth(source), h = CVPixelBufferGetHeight(source)
        CVPixelBufferLockBaseAddress(source, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(source)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(source)
        var pixels = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            let row = base + y * rowBytes
            var d = y * w * 4
            for x in 0..<w {
                let s = x * 4
                pixels[d] = row[s + 2]
                pixels[d + 1] = row[s + 1]
                pixels[d + 2] = row[s]
                d += 4
            }
        }
        return RGBAImage(width: w, height: h, pixels: pixels)
    }
}
