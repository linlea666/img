import Foundation

/// 批处理清单：写在输出目录里，记录用什么参数修了哪些图，便于复现和排查。
public struct BatchManifest: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public enum Status: String, Codable, Sendable { case done, skipped, failed }
        public var source: String
        public var output: String?
        public var status: Status
        public var seconds: Double?
        public var error: String?

        public init(source: String, output: String?, status: Status, seconds: Double? = nil, error: String? = nil) {
            self.source = source
            self.output = output
            self.status = status
            self.seconds = seconds
            self.error = error
        }
    }

    public var app: String = "ReFrame"
    public var version: Int = 1
    public var startedAt: Date
    public var finishedAt: Date?
    public var recipe: String
    public var settings: RestoreSettings
    public var timestampRegion: PixelRect?
    public var colorCorrection: ColorCorrection?
    public var entries: [Entry] = []

    public init(startedAt: Date, settings: RestoreSettings, timestampRegion: PixelRect?, colorCorrection: ColorCorrection?) {
        self.startedAt = startedAt
        self.recipe = settings.recipeDescription
        self.settings = settings
        self.timestampRegion = timestampRegion
        self.colorCorrection = colorCorrection
    }

    public static let fileName = "reframe-manifest.json"

    public func write(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        try data.write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
    }
}
