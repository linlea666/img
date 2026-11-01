import Foundation

/// 决定每张图的输出路径，并保证绝不会写到原图上。
public struct OutputPlanner: Sendable {
    public enum Decision: Equatable, Sendable {
        /// 写到这个路径（`replacing` 为 true 表示覆盖输出目录里的旧结果）
        case write(URL, replacing: Bool)
        /// 已存在，按策略跳过
        case skip(URL)
    }

    public enum PlanError: LocalizedError, Equatable {
        case wouldOverwriteSource(String)
        case emptyName

        public var errorDescription: String? {
            switch self {
            case .wouldOverwriteSource(let name): return "输出文件会覆盖原图「\(name)」，已拒绝。请换一个输出目录或命名规则。"
            case .emptyName: return "命名规则生成了空文件名。"
            }
        }
    }

    public let outputDirectory: URL
    public let settings: RestoreSettings
    /// 所有原图的标准化路径，用于防止覆盖
    private let sourcePaths: Set<String>

    public init(outputDirectory: URL, settings: RestoreSettings, sources: [URL]) {
        self.outputDirectory = outputDirectory
        self.settings = settings
        self.sourcePaths = Set(sources.map { Self.normalized($0) })
    }

    static func normalized(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
    }

    /// 按模板生成文件名（不含扩展名）。支持 {name} {index} {scale}
    public func baseName(for source: URL, index: Int) -> String {
        let name = source.deletingPathExtension().lastPathComponent
        var result = settings.nameTemplate
            .replacingOccurrences(of: "{name}", with: name)
            .replacingOccurrences(of: "{scale}", with: settings.scale.suffix)
            .replacingOccurrences(of: "{index}", with: String(format: "%05d", index + 1))
        result = result.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// 期望的输出路径（不考虑冲突）
    public func intendedURL(for source: URL, index: Int) -> URL {
        outputDirectory.appendingPathComponent(baseName(for: source, index: index))
            .appendingPathExtension(settings.format.fileExtension)
    }

    public func decide(for source: URL, index: Int,
                       fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) throws -> Decision {
        guard !baseName(for: source, index: index).isEmpty else { throw PlanError.emptyName }
        let url = intendedURL(for: source, index: index)
        guard !sourcePaths.contains(Self.normalized(url)) else {
            throw PlanError.wouldOverwriteSource(source.lastPathComponent)
        }
        guard fileExists(url) else { return .write(url, replacing: false) }
        switch settings.conflictPolicy {
        case .skip:
            return .skip(url)
        case .overwrite:
            return .write(url, replacing: true)
        case .rename:
            let base = url.deletingPathExtension().lastPathComponent
            var n = 2
            while true {
                let candidate = outputDirectory.appendingPathComponent("\(base) (\(n))")
                    .appendingPathExtension(settings.format.fileExtension)
                if !fileExists(candidate) && !sourcePaths.contains(Self.normalized(candidate)) {
                    return .write(candidate, replacing: false)
                }
                n += 1
            }
        }
    }

    /// 预估输出总大小（字节）
    public static func estimatedBytes(count: Int, inputWidth: Int, inputHeight: Int, settings: RestoreSettings) -> Int64 {
        let s = Double(settings.scale.rawValue)
        let pixels = Double(inputWidth) * s * Double(inputHeight) * s
        return Int64(Double(count) * pixels * settings.format.bytesPerPixel)
    }
}
