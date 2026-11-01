import CoreGraphics
import Foundation
import ImageIO
import ReFrameCore
import UniformTypeIdentifiers

/// 图片读写。原图只读打开；输出先写临时文件，成功后再移动到目标位置。
public enum ImageFiles {
    public enum IOError: LocalizedError {
        case cannotRead(String)
        case cannotWrite(String)

        public var errorDescription: String? {
            switch self {
            case .cannotRead(let name): return "无法读取图片「\(name)」"
            case .cannotWrite(let name): return "无法写入「\(name)」"
            }
        }
    }

    public static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    public static func loadCGImage(_ url: URL, maxPixelSize: Int? = nil) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw IOError.cannotRead(url.lastPathComponent)
        }
        if let maxPixelSize {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ]
            if let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) { return thumb }
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw IOError.cannotRead(url.lastPathComponent)
        }
        return image
    }

    /// 只读取尺寸（不解码像素）
    public static func pixelSize(of url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    public static func loadRGBA(_ url: URL) throws -> RGBAImage {
        try rgba(from: loadCGImage(url))
    }

    public static func rgba(from image: CGImage) -> RGBAImage {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: w * 4, space: sRGB,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var i = 3
        while i < pixels.count { pixels[i] = 255; i += 4 }
        return RGBAImage(width: w, height: h, pixels: pixels)
    }

    public static func cgImage(from image: RGBAImage) -> CGImage {
        let data = Data(image.pixels) as CFData
        let provider = CGDataProvider(data: data)!
        return CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: image.width * 4, space: sRGB,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }

    /// 写图片：先写到同目录的临时文件，再原子地移动/替换到目标位置
    public static func write(_ image: CGImage, to url: URL, format: RestoreSettings.OutputFormat,
                             quality: Double, replacing: Bool) throws {
        let type: UTType
        switch format {
        case .png: type = .png
        case .jpeg: type = .jpeg
        case .heic: type = .heic
        }
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, type.identifier as CFString, 1, nil) else {
            throw IOError.cannotWrite(url.lastPathComponent)
        }
        var props: [CFString: Any] = [:]
        if format != .png { props[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: tmp)
            throw IOError.cannotWrite(url.lastPathComponent)
        }
        do {
            if replacing, FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }
}
