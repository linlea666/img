import AVFoundation
import XCTest
import ReFrameCore
@testable import ReFrameEngine

final class ReFrameEngineTests: XCTestCase {
    /// 模拟样张：240×135、偏紫的墙、一个"人"、右下角黄色时间水印
    func makeFrame(_ i: Int) -> RGBAImage {
        var img = RGBAImage(width: 240, height: 135, fill: (150, 120, 150))
        for y in 20..<110 { for x in (40 + i * 3)..<(70 + i * 3) { img.setPixel(x, y, (90, 60, 110)) } }
        for x in 100..<180 where (x + i) % 4 != 0 { for y in 124..<131 { img.setPixel(x, y, (245, 225, 40)) } }
        return img
    }

    func writeFrames(_ n: Int) throws -> [URL] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reframe-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try (0..<n).map { i in
            let url = dir.appendingPathComponent(String(format: "frame_%03d.png", i))
            try ImageFiles.write(ImageFiles.cgImage(from: makeFrame(i)), to: url, format: .png, quality: 1, replacing: false)
            return url
        }
    }

    func testTileOrigins() {
        XCTAssertEqual(SuperResolver.tileOrigins(size: 240, tile: 256, overlap: 12), [0])
        XCTAssertEqual(SuperResolver.tileOrigins(size: 500, tile: 256, overlap: 12), [0, 232, 244])
    }

    func testImageRoundTrip() throws {
        let frame = makeFrame(0)
        let back = ImageFiles.rgba(from: ImageFiles.cgImage(from: frame))
        XCTAssertEqual(back.pixel(10, 10).r, frame.pixel(10, 10).r)
        XCTAssertEqual(back.pixel(150, 127).b, frame.pixel(150, 127).b)
    }

    func testContextDetectsTimestampAndPlate() async throws {
        let urls = try writeFrames(9)
        let engine = RestorationEngine(modelsDirectory: nil)
        let ctx = try await engine.buildContext(urls: urls, settings: RestoreSettings())
        XCTAssertNotNil(ctx?.timestampRect)
        XCTAssertNotNil(ctx?.plate)
        // 底图里水印已被补全成墙面颜色
        let p = ctx!.plate!.pixel(140, 127)
        XCTAssertLessThan(abs(Int(p.r) - 150), 12)
        XCTAssertLessThan(abs(Int(p.b) - 150), 12)
    }

    /// 没有模型时退化为 Lanczos，流程仍然完整
    func testFallbackPipelineProduces1080p() async throws {
        let urls = try writeFrames(5)
        let engine = RestorationEngine(modelsDirectory: nil)
        var settings = RestoreSettings()
        settings.faceRestore = false
        let ctx = try await engine.buildContext(urls: urls, settings: settings)
        let result = try await engine.restore(url: urls[0], settings: settings, context: ctx)
        XCTAssertEqual(result.image.width, 1920)
        XCTAssertEqual(result.image.height, 1080)
        XCTAssertFalse(result.usedSuperResolutionModel)
    }

    /// CI 里设置 REFRAME_MODELS_DIR 后，用真实 Core ML 模型跑完整流程
    func testModelPipeline() async throws {
        guard let dir = ProcessInfo.processInfo.environment["REFRAME_MODELS_DIR"] else {
            throw XCTSkip("未设置 REFRAME_MODELS_DIR")
        }
        let urls = try writeFrames(5)
        let engine = RestorationEngine(modelsDirectory: URL(fileURLWithPath: dir))
        let status = await engine.modelStatus()
        XCTAssertTrue(status.superResolution, "缺少超分模型")
        XCTAssertTrue(status.face, "缺少人脸模型")
        var settings = RestoreSettings()
        settings.computeUnits = .cpu   // CI 虚拟机没有神经网络引擎
        let ctx = try await engine.buildContext(urls: urls, settings: settings)
        let start = Date()
        let result = try await engine.restore(url: urls[2], settings: settings, context: ctx)
        print("单帧耗时（CI CPU）：\(Date().timeIntervalSince(start)) 秒")
        XCTAssertTrue(result.usedSuperResolutionModel)
        XCTAssertEqual(result.image.width, 1920)
        XCTAssertEqual(result.image.height, 1080)
        // 模型输出不应是全黑/全白
        let small = ImageFiles.rgba(from: result.image)
        XCTAssertGreaterThan(small.meanLuma, 20)
        XCTAssertLessThan(small.meanLuma, 240)
    }

    func testVideoExport() async throws {
        let urls = try writeFrames(6)
        let out = urls[0].deletingLastPathComponent().appendingPathComponent("out.mp4")
        let order = PlaybackSequencer.exportOrder(count: urls.count, mode: .pingPong, repeats: 1).map { urls[$0] }
        try await VideoExporter.export(.init(frames: order, fps: 10, codec: .h264, quality: .medium, outputURL: out),
                                       progress: { _ in })
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        let asset = AVURLAsset(url: out)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, Double(order.count) / 10, accuracy: 0.15)
    }
}
