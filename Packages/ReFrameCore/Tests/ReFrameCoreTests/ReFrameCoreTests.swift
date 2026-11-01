import XCTest
@testable import ReFrameCore

final class NaturalSortTests: XCTestCase {
    func testNumbersSortByValue() {
        let names = ["frame_10.jpg", "frame_2.jpg", "frame_1.jpg", "Frame_3.jpg"]
        let sorted = names.sorted(by: NaturalSort.isOrderedBefore)
        XCTAssertEqual(sorted, ["frame_1.jpg", "frame_2.jpg", "Frame_3.jpg", "frame_10.jpg"])
    }

    func testSupportedExtensions() {
        XCTAssertTrue(SupportedImage.isSupported(URL(fileURLWithPath: "/a/b.JPG")))
        XCTAssertFalse(SupportedImage.isSupported(URL(fileURLWithPath: "/a/b.mp4")))
    }
}

final class RGBAImageTests: XCTestCase {
    func testCropClampedPadsWithEdgePixels() {
        var img = RGBAImage(width: 2, height: 2)
        img.setPixel(1, 1, (200, 100, 50))
        let crop = img.cropClamped(PixelRect(x: 1, y: 1, width: 3, height: 2))
        XCTAssertEqual(crop.width, 3)
        XCTAssertEqual(crop.pixel(2, 1).r, 200)   // 超出部分复制边缘像素
    }

    func testPasteIgnoresOutOfBounds() {
        var dst = RGBAImage(width: 3, height: 3)
        let src = RGBAImage(width: 2, height: 2, fill: (9, 9, 9))
        dst.paste(src, atX: 2, y: 2)
        XCTAssertEqual(dst.pixel(2, 2).r, 9)
        XCTAssertEqual(dst.pixel(1, 1).r, 0)
    }
}

final class ColorCorrectionTests: XCTestCase {
    func testWhiteBalanceRemovesColorCast() {
        // 偏紫的灰墙
        let img = RGBAImage(width: 10, height: 10, fill: (150, 110, 150))
        let c = ColorCorrection.estimate(from: img, whiteBalance: 1, autoLevels: false, autoBrightness: false)
        var out = img
        c.apply(to: &out)
        let p = out.pixel(0, 0)
        XCTAssertLessThan(abs(Int(p.r) - Int(p.g)), 4)
        XCTAssertLessThan(abs(Int(p.b) - Int(p.g)), 4)
    }

    func testLevelsStretchLowContrast() {
        var img = RGBAImage(width: 20, height: 1)
        for x in 0..<20 { let v = UInt8(40 + x * 6); img.setPixel(x, 0, (v, v, v)) }   // 40...154，发灰
        let c = ColorCorrection.estimate(from: img, whiteBalance: 0, autoLevels: true, autoBrightness: false)
        var out = img
        c.apply(to: &out)
        XCTAssertLessThan(out.pixel(0, 0).r, 10)
        XCTAssertGreaterThan(out.pixel(19, 0).r, 200)
    }

    func testDarkImageGetsBrighter() {
        let img = RGBAImage(width: 8, height: 8, fill: (50, 50, 50))
        let c = ColorCorrection.estimate(from: img, whiteBalance: 0, autoLevels: false, autoBrightness: true)
        XCTAssertLessThan(c.gamma, 1)
        var out = img
        c.apply(to: &out)
        XCTAssertGreaterThan(out.pixel(0, 0).r, 50)
    }

    func testExcludedRegionIgnored() {
        var img = RGBAImage(width: 10, height: 10, fill: (100, 100, 100))
        for x in 0..<10 { img.setPixel(x, 9, (255, 230, 0)) }  // 黄色水印行
        let c = ColorCorrection.estimate(from: img, whiteBalance: 1, autoLevels: false, autoBrightness: false,
                                         excluding: PixelRect(x: 0, y: 9, width: 10, height: 1))
        XCTAssertEqual(c.gainB, 1, accuracy: 0.001)
    }
}

final class TimestampDetectorTests: XCTestCase {
    func testDetectsYellowTextAtBottom() {
        var frames: [RGBAImage] = []
        for f in 0..<10 {
            var img = RGBAImage(width: 60, height: 40, fill: (UInt8(60 + f * 5), 70, 80))
            // 底部一行"数字"：位置固定，部分像素每帧变化
            for x in 30..<55 where (x + f) % 3 != 0 {
                for y in 34..<38 { img.setPixel(x, y, (240, 220, 40)) }
            }
            frames.append(img)
        }
        let rect = TimestampDetector.detect(in: frames)
        XCTAssertNotNil(rect)
        XCTAssertLessThanOrEqual(rect!.x, 30)
        XCTAssertGreaterThanOrEqual(rect!.maxX, 55)
        XCTAssertGreaterThanOrEqual(rect!.y, 30)
    }

    func testNoTimestamp() {
        let frames = (0..<5).map { _ in RGBAImage(width: 30, height: 20, fill: (90, 90, 90)) }
        XCTAssertNil(TimestampDetector.detect(in: frames))
    }
}

final class BackgroundPlateTests: XCTestCase {
    func testMedianRemovesMovingObject() {
        var frames: [RGBAImage] = []
        for f in 0..<7 {
            var img = RGBAImage(width: 10, height: 4, fill: (100, 120, 140))
            img.setPixel(f, 1, (255, 0, 0))   // 走动的"人"
            frames.append(img)
        }
        let plate = BackgroundPlate.median(of: frames)!
        for x in 0..<10 { XCTAssertEqual(plate.pixel(x, 1).r, 100) }
    }

    func testInpaintFillsSmoothly() {
        var img = RGBAImage(width: 20, height: 10, fill: (100, 100, 100))
        for x in 5..<15 { for y in 3..<7 { img.setPixel(x, y, (255, 255, 0)) } }
        let out = BackgroundPlate.inpaint(img, rect: PixelRect(x: 5, y: 3, width: 10, height: 4))
        let p = out.pixel(10, 5)
        XCTAssertEqual(Int(p.r), 100, accuracy: 2)
        XCTAssertEqual(Int(p.b), 100, accuracy: 2)
    }
}

final class FaceAlignmentTests: XCTestCase {
    func testFitRecoversTransform() {
        let truth = SimilarityTransform(a: 1.5, b: 0.4, tx: 12, ty: -7)
        let src = [Point2(0, 0), Point2(10, 0), Point2(5, 8), Point2(1, 13), Point2(9, 13)]
        let dst = src.map(truth.apply)
        let fit = SimilarityTransform.fit(from: src, to: dst)!
        XCTAssertEqual(fit.a, truth.a, accuracy: 1e-9)
        XCTAssertEqual(fit.b, truth.b, accuracy: 1e-9)
        XCTAssertEqual(fit.tx, truth.tx, accuracy: 1e-9)
        XCTAssertEqual(fit.ty, truth.ty, accuracy: 1e-9)
    }

    func testInverse() {
        let t = SimilarityTransform(a: 0.8, b: -0.3, tx: 4, ty: 9)
        let p = Point2(13, -2)
        let back = t.inverse.apply(t.apply(p))
        XCTAssertEqual(back.x, p.x, accuracy: 1e-9)
        XCTAssertEqual(back.y, p.y, accuracy: 1e-9)
    }
}

final class OutputPlannerTests: XCTestCase {
    let out = URL(fileURLWithPath: "/tmp/out")

    func testNameTemplate() {
        var s = RestoreSettings()
        s.nameTemplate = "{name}_{scale}_{index}"
        let planner = OutputPlanner(outputDirectory: out, settings: s, sources: [])
        XCTAssertEqual(planner.intendedURL(for: URL(fileURLWithPath: "/src/a.jpg"), index: 0).lastPathComponent,
                       "a_x8_00001.png")
    }

    func testRefusesToOverwriteSource() {
        var s = RestoreSettings()
        s.nameTemplate = "{name}"
        s.format = .jpeg
        let src = URL(fileURLWithPath: "/tmp/out/a.jpg")
        let planner = OutputPlanner(outputDirectory: out, settings: s, sources: [src])
        XCTAssertThrowsError(try planner.decide(for: src, index: 0, fileExists: { _ in true }))
    }

    func testConflictPolicies() throws {
        var s = RestoreSettings()
        let src = URL(fileURLWithPath: "/src/a.jpg")
        s.conflictPolicy = .skip
        var planner = OutputPlanner(outputDirectory: out, settings: s, sources: [src])
        XCTAssertEqual(try planner.decide(for: src, index: 0, fileExists: { _ in true }),
                       .skip(out.appendingPathComponent("a_x8.png")))
        s.conflictPolicy = .rename
        planner = OutputPlanner(outputDirectory: out, settings: s, sources: [src])
        let existing: Set<String> = ["a_x8.png", "a_x8 (2).png"]
        let decision = try planner.decide(for: src, index: 0, fileExists: { existing.contains($0.lastPathComponent) })
        XCTAssertEqual(decision, .write(out.appendingPathComponent("a_x8 (3).png"), replacing: false))
    }
}

final class PlaybackSequencerTests: XCTestCase {
    func testLoop() {
        var s = PlaybackSequencer(count: 3, mode: .loop)
        var seen: [Int] = []
        for _ in 0..<5 { s.advance(); seen.append(s.index) }
        XCTAssertEqual(seen, [1, 2, 0, 1, 2])
    }

    func testPingPong() {
        var s = PlaybackSequencer(count: 3, mode: .pingPong)
        var seen: [Int] = []
        for _ in 0..<6 { s.advance(); seen.append(s.index) }
        XCTAssertEqual(seen, [1, 2, 1, 0, 1, 2])
    }

    func testOnceStops() {
        var s = PlaybackSequencer(count: 2, mode: .once)
        XCTAssertTrue(s.advance())
        XCTAssertFalse(s.advance())
        XCTAssertEqual(s.index, 1)
    }

    func testExportOrder() {
        XCTAssertEqual(PlaybackSequencer.exportOrder(count: 4, mode: .pingPong, repeats: 1), [0, 1, 2, 3, 2, 1])
        XCTAssertEqual(PlaybackSequencer.exportOrder(count: 2, mode: .loop, repeats: 2), [0, 1, 0, 1])
        XCTAssertEqual(PlaybackSequencer.exportOrder(count: 3, mode: .once, repeats: 5), [0, 1, 2])
    }
}

final class OrientationTests: XCTestCase {
    func testOutputSize() {
        let a = ImageOrientation(rotation: .upsideDown).outputSize(width: 1920, height: 1080)
        XCTAssertEqual(a.width, 1920)
        XCTAssertEqual(a.height, 1080)
        let b = ImageOrientation(rotation: .clockwise90).outputSize(width: 1920, height: 1080)
        XCTAssertEqual(b.width, 1080)
        XCTAssertEqual(b.height, 1920)
    }

    func testTimestampStaysAtBottomRight() {
        // 1920×1080 右下角的水印，转 180° 后仍应放在右下角
        let r = PixelRect(x: 800, y: 990, width: 700, height: 60)
        let same = r.reanchored(inWidth: 1920, height: 1080, toWidth: 1920, height: 1080)
        XCTAssertEqual(same, r)
        // 转 90° 变竖屏：保持到右边、下边的距离
        let portrait = r.reanchored(inWidth: 1920, height: 1080, toWidth: 1080, height: 1920)
        XCTAssertEqual(portrait.maxX, 1080 - (1920 - r.maxX))
        XCTAssertEqual(portrait.maxY, 1920 - (1080 - r.maxY))
    }

    func testOldSettingsStillDecode() throws {
        // 旧版本保存的设置里没有 orientation 字段
        let old = #"{"scale":4,"faceStrength":0.5}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(RestoreSettings.self, from: old)
        XCTAssertEqual(s.scale, .x4)
        XCTAssertEqual(s.faceStrength, 0.5)
        XCTAssertEqual(s.orientation, .identity)
        XCTAssertEqual(s.format, .png)
    }

    func testSettingsRoundTrip() throws {
        var s = RestoreSettings()
        s.orientation = ImageOrientation(rotation: .upsideDown, flipHorizontal: true)
        let back = try JSONDecoder().decode(RestoreSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
        XCTAssertTrue(s.recipeDescription.contains("orientation=r180f"))
    }
}
