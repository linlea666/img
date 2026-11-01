import Foundation

/// 自然排序：frame_2 排在 frame_10 前面（按数字大小而不是逐字符比较）。
public enum NaturalSort {
    public static func isOrderedBefore(_ a: String, _ b: String) -> Bool {
        let result = a.compare(b, options: [.numeric, .caseInsensitive, .widthInsensitive])
        if result == .orderedSame { return a < b }
        return result == .orderedAscending
    }

    public static func sorted(_ urls: [URL]) -> [URL] {
        urls.sorted { isOrderedBefore($0.lastPathComponent, $1.lastPathComponent) }
    }
}

/// 支持导入的图片扩展名
public enum SupportedImage {
    public static let extensions: Set<String> = ["jpg", "jpeg", "png", "bmp", "webp", "tif", "tiff", "heic", "heif"]

    public static func isSupported(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }
}
