import Foundation

/// 一次修复的全部参数。参与"配方"描述，参数变了，已修过的结果会被视为过期。
public struct RestoreSettings: Codable, Equatable, Sendable {
    public enum Scale: Int, Codable, CaseIterable, Sendable {
        case x4 = 4
        case x8 = 8

        public var title: String { self == .x4 ? "×4（240×135 → 960×540）" : "×8（240×135 → 1920×1080）" }
        public var suffix: String { "x\(rawValue)" }
    }

    public enum TimestampMode: String, Codable, CaseIterable, Sendable {
        /// 去除：用背景底图补全
        case remove
        /// 原样保留：修复时保护，最后把原水印放大贴回
        case keep
        /// 不处理：当作普通画面一起修
        case ignore

        public var title: String {
            switch self {
            case .remove: return "去除"
            case .keep: return "原样保留"
            case .ignore: return "不处理"
            }
        }
    }

    public enum OutputFormat: String, Codable, CaseIterable, Sendable {
        case png, jpeg, heic

        public var fileExtension: String {
            switch self {
            case .png: return "png"
            case .jpeg: return "jpg"
            case .heic: return "heic"
            }
        }

        public var title: String {
            switch self {
            case .png: return "PNG（无损，体积大）"
            case .jpeg: return "JPG"
            case .heic: return "HEIC（体积小）"
            }
        }

        /// 1080p 单张的大致体积（字节/像素），用于磁盘预估
        public var bytesPerPixel: Double {
            switch self {
            case .png: return 1.8
            case .jpeg: return 0.35
            case .heic: return 0.18
            }
        }
    }

    public enum ConflictPolicy: String, Codable, CaseIterable, Sendable {
        case skip, rename, overwrite

        public var title: String {
            switch self {
            case .skip: return "跳过已存在的（可断点续跑）"
            case .rename: return "自动改名"
            case .overwrite: return "覆盖旧的修复结果"
            }
        }
    }

    public enum ComputeUnits: String, Codable, CaseIterable, Sendable {
        case all, neuralEngine, gpu, cpu

        public var title: String {
            switch self {
            case .all: return "自动"
            case .neuralEngine: return "神经网络引擎"
            case .gpu: return "GPU"
            case .cpu: return "仅 CPU"
            }
        }
    }

    // 修复
    public var scale: Scale = .x8
    public var faceRestore: Bool = true
    /// 人脸修复强度 0...1（越低越保留原样，越高越清晰但越可能"不像"）
    public var faceStrength: Double = 0.7
    /// 白平衡（去色偏）强度 0...1
    public var whiteBalance: Double = 0.7
    public var autoLevels: Bool = true
    public var autoBrightness: Bool = true
    /// 最终锐化 0...1
    public var sharpen: Double = 0.3
    public var timestampMode: TimestampMode = .remove
    /// 画面方向（输出时转正）
    public var orientation: ImageOrientation = .identity

    // 输出
    public var format: OutputFormat = .png
    public var jpegQuality: Double = 0.92
    public var nameTemplate: String = "{name}_{scale}"
    public var conflictPolicy: ConflictPolicy = .skip

    // 运行
    public var computeUnits: ComputeUnits = .all

    public init() {}

    enum CodingKeys: String, CodingKey {
        case scale, faceRestore, faceStrength, whiteBalance, autoLevels, autoBrightness, sharpen, timestampMode
        case orientation, format, jpegQuality, nameTemplate, conflictPolicy, computeUnits
    }

    /// 逐项读取，缺少的字段用默认值（升级版本后旧的设置仍能读出来）
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RestoreSettings()
        scale = (try? c.decodeIfPresent(Scale.self, forKey: .scale)) ?? d.scale
        faceRestore = (try? c.decodeIfPresent(Bool.self, forKey: .faceRestore)) ?? d.faceRestore
        faceStrength = (try? c.decodeIfPresent(Double.self, forKey: .faceStrength)) ?? d.faceStrength
        whiteBalance = (try? c.decodeIfPresent(Double.self, forKey: .whiteBalance)) ?? d.whiteBalance
        autoLevels = (try? c.decodeIfPresent(Bool.self, forKey: .autoLevels)) ?? d.autoLevels
        autoBrightness = (try? c.decodeIfPresent(Bool.self, forKey: .autoBrightness)) ?? d.autoBrightness
        sharpen = (try? c.decodeIfPresent(Double.self, forKey: .sharpen)) ?? d.sharpen
        timestampMode = (try? c.decodeIfPresent(TimestampMode.self, forKey: .timestampMode)) ?? d.timestampMode
        orientation = (try? c.decodeIfPresent(ImageOrientation.self, forKey: .orientation)) ?? d.orientation
        format = (try? c.decodeIfPresent(OutputFormat.self, forKey: .format)) ?? d.format
        jpegQuality = (try? c.decodeIfPresent(Double.self, forKey: .jpegQuality)) ?? d.jpegQuality
        nameTemplate = (try? c.decodeIfPresent(String.self, forKey: .nameTemplate)) ?? d.nameTemplate
        conflictPolicy = (try? c.decodeIfPresent(ConflictPolicy.self, forKey: .conflictPolicy)) ?? d.conflictPolicy
        computeUnits = (try? c.decodeIfPresent(ComputeUnits.self, forKey: .computeUnits)) ?? d.computeUnits
    }

    /// 稳定的文字描述（只含影响画面的参数），写入任务清单便于复现
    public var recipeDescription: String {
        [
            "scale=\(scale.rawValue)",
            "face=\(faceRestore ? String(format: "%.2f", faceStrength) : "off")",
            String(format: "wb=%.2f", whiteBalance),
            "levels=\(autoLevels)",
            "brightness=\(autoBrightness)",
            String(format: "sharpen=%.2f", sharpen),
            "timestamp=\(timestampMode.rawValue)",
            "orientation=\(orientation.key)",
            "models=realesrgan-x4plus,gfpgan-1.4",
        ].joined(separator: "&")
    }
}
