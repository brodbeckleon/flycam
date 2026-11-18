import XCTest
import simd
import FlyCamKit
@testable import DirectorCore

/// Phone-side logic from Apps/Shared/Capture (compiled into CaptureApp and DirectorCore).
final class CaptureLogicTests: XCTestCase {
    func testARConversions() {
        // simd is column-major: columns[3] is the translation.
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(1, 2, 3, 1)
        m.columns.0 = SIMD4(0, 1, 0, 0)
        m.columns.1 = SIMD4(-1, 0, 0, 0)
        let c2w = ARConvert.c2w(m)
        XCTAssertEqual(c2w.translation, Vec3(1, 2, 3))
        XCTAssertEqual(c2w[1, 0], 1)
        XCTAssertEqual(c2w[0, 1], -1)
        XCTAssertEqual(c2w.columnMajor.count, 16)
        // ARKit intrinsics: [[fx 0 0] [0 fy 0] [cx cy 1]] (columns).
        let k = simd_float3x3(SIMD3(1500, 0, 0), SIMD3(0, 1501, 0), SIMD3(960.5, 540.25, 1))
        XCTAssertEqual(ARConvert.intrinsics(k, width: 1920, height: 1080),
                       Intrinsics(fx: 1500, fy: 1501, cx: 960.5, cy: 540.25, width: 1920, height: 1080))
    }

    func testScanKeyframeSelection() {
        var sel = ScanKeyframeSelector()
        func pose(x: Double, yawDeg: Double) -> Mat4 {
            Mat4(rotation: Quat(axis: .unitY, angle: yawDeg * .pi / 180).matrix, translation: Vec3(x, 0, 0))
        }
        XCTAssertTrue(sel.shouldSave(time: 0, c2w: pose(x: 0, yawDeg: 0), tracking: .normal), "first frame")
        XCTAssertFalse(sel.shouldSave(time: 0.1, c2w: pose(x: 0.05, yawDeg: 0), tracking: .normal), "5 cm")
        XCTAssertTrue(sel.shouldSave(time: 0.2, c2w: pose(x: 0.101, yawDeg: 0), tracking: .normal), "10.1 cm")
        XCTAssertFalse(sel.shouldSave(time: 0.5, c2w: pose(x: 0.101, yawDeg: 7), tracking: .normal), "7 degrees")
        XCTAssertTrue(sel.shouldSave(time: 1.0, c2w: pose(x: 0.101, yawDeg: 8.5), tracking: .normal), "8.5 degrees")
        // Fast rotation: 10 degrees in 0.1 s = 100 deg/s, skipped even though far enough.
        XCTAssertFalse(sel.shouldSave(time: 1.1, c2w: pose(x: 0.101, yawDeg: 18.5), tracking: .normal))
        // Slow again: saved.
        XCTAssertTrue(sel.shouldSave(time: 2.1, c2w: pose(x: 0.101, yawDeg: 19), tracking: .normal))
        XCTAssertFalse(sel.shouldSave(time: 3.0, c2w: pose(x: 1, yawDeg: 19), tracking: .limited), "limited tracking")
        XCTAssertEqual(sel.savedCount, 4)
    }

    func testFloorEstimation() {
        let planes = [PlaneObservation(y: 0.7, area: 1.2, isFloor: false),       // table
                      PlaneObservation(y: -1.31, area: 4.0, isFloor: true),
                      PlaneObservation(y: -1.29, area: 9.0, isFloor: true),
                      PlaneObservation(y: -1.0, area: 20, isFloor: false)]        // e.g. a bed, not floor
        XCTAssertEqual(FloorEstimator.floorY(planes: planes), -1.29)
        // Without classification: largest plane well below the cameras.
        let unclassified = [PlaneObservation(y: 0.7, area: 30, isFloor: false), PlaneObservation(y: -1.3, area: 6, isFloor: false)]
        XCTAssertEqual(FloorEstimator.floorY(planes: unclassified, lowestCameraY: -0.1), -1.3)
        XCTAssertNil(FloorEstimator.floorY(planes: []))
    }

    func testPointsPLYRoundTripAndFormat() throws {
        let pts = (0..<100).map { i in ColoredPoint(position: SIMD3(Float(i) * 0.1, -1.3, Float(-i) * 0.05),
                                                    color: SIMD3(UInt8(i), UInt8(255 - i), 7)) }
        let data = PointCloudPLY.encode(pts)
        let header = String(decoding: data.prefix(200), as: UTF8.self)
        XCTAssertTrue(header.hasPrefix("ply\nformat binary_little_endian 1.0\nelement vertex 100\nproperty float x\n"))
        XCTAssertTrue(header.contains("property uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n"))
        XCTAssertEqual(try PointCloudPLY.decode(data), pts)
    }

    func testSessionNamingAndFormatChoice() {
        let d = Date(timeIntervalSince1970: 1_795_000_000)
        XCTAssertEqual(SessionNaming.folderName(date: d, device: "iPhone15,2"), "session_20261118-110640_iPhone15-2")
        let formats = [VideoFormatCandidate(width: 1920, height: 1440, fps: 60), VideoFormatCandidate(width: 1920, height: 1080, fps: 30),
                       VideoFormatCandidate(width: 1920, height: 1080, fps: 60), VideoFormatCandidate(width: 3840, height: 2160, fps: 30),
                       VideoFormatCandidate(width: 1280, height: 720, fps: 60)]
        XCTAssertEqual(VideoFormatChooser.choose(formats), 2)
        XCTAssertEqual(VideoFormatChooser.choose([VideoFormatCandidate(width: 1920, height: 1440, fps: 60),
                                                  VideoFormatCandidate(width: 3840, height: 2160, fps: 30)]), 1)
    }

    func testRecorderClipSessionOpensAsRecordedSource() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("flycam-rec-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        let rec = try SessionRecorder(parent: parent, kind: .clip, deviceModel: "iPhone15,2", osVersion: "18.1",
                                      videoFormat: VideoFormat(width: 320, height: 180, fps: 60), cameraID: 3, clockOffset: 10)
        rec.cameraSettings = CameraSettings(locked: true, iso: 200, shutter: 1 / 120, wbTemperature: 4800, wbTint: 2)
        rec.floorY = -1.25
        let k = Intrinsics(fx: 250, fy: 250, cx: 160.3, cy: 89.7, width: 320, height: 180)
        for i in 0..<30 {
            let pb = try makeBGRAPixelBuffer(width: 320, height: 180)
            fill(pb, bgra: [UInt8](repeating: UInt8(40 + i * 5), count: 320 * 180 * 4))
            FrameCode.stamp(i, into: pb)
            // ARFrame-like timestamps with jitter around 60 fps.
            let t = 500 + Double(i) / 60 + (i % 2 == 0 ? 0.0004 : -0.0003)
            try rec.appendVideoFrame(pb, time: t, c2w: Mat4.lookAt(eye: Vec3(Double(i) * 0.01, 0, 0), target: Vec3(0, 0, -3)),
                                     intrinsics: k, tracking: i < 3 ? .limited : .normal, iso: 200, shutter: 1 / 120)
        }
        let folder = try rec.finish()
        let src = try await RecordedSource(folder: folder)
        XCTAssertEqual(src.frameCount, 30)
        XCTAssertEqual(src.cameraID, 3)
        XCTAssertEqual(src.meta.kind, .clip)
        XCTAssertEqual(src.meta.cameraSettings.iso, 200)
        XCTAssertEqual(src.floorY, -1.25)
        XCTAssertEqual(src.records[0].tracking, .limited)
        for i in [0, 7, 29] {
            let f = try src.frame(at: i)
            XCTAssertEqual(FrameCode.read(f.pixelBuffer), i)
            XCTAssertEqual(f.camera.intrinsics, k)
        }
    }

    func testRecorderScanSession() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("flycam-scan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        let rec = try SessionRecorder(parent: parent, kind: .scan, deviceModel: "iPhone15,2", osVersion: "18.1",
                                      videoFormat: VideoFormat(width: 320, height: 180, fps: 60))
        let k = Intrinsics(fx: 250, fy: 250, cx: 160, cy: 90, width: 320, height: 180)
        for i in 0..<4 {
            let pb = try makeBGRAPixelBuffer(width: 320, height: 180)
            fill(pb, bgra: [UInt8](repeating: 128, count: 320 * 180 * 4))
            try rec.appendStill(pb, time: Double(i), c2w: .identity, intrinsics: k, tracking: .normal)
        }
        rec.floorY = -1.3
        let folder = try rec.finish(worldMap: Data([1, 2, 3]), points: [ColoredPoint(position: SIMD3(0, -1.3, -2), color: SIMD3(1, 2, 3))])
        let fm = FileManager.default
        for f in ["meta.json", "frames.jsonl", "worldmap.bin", "points.ply", "images/00000.jpg", "images/00003.jpg"] {
            XCTAssertTrue(fm.fileExists(atPath: folder.appendingPathComponent(f).path), f)
        }
        XCTAssertFalse(fm.fileExists(atPath: folder.appendingPathComponent("video.mov").path))
        let meta = try SessionIO.readMeta(folder)
        XCTAssertEqual(meta.kind, .scan)
        XCTAssertEqual(meta.floorY, -1.3)
        XCTAssertTrue(folder.lastPathComponent.hasSuffix("_scan"))
        XCTAssertEqual(try SessionIO.readFrames(folder).count, 4)
        XCTAssertEqual(try PointCloudPLY.decode(Data(contentsOf: folder.appendingPathComponent("points.ply"))).count, 1)
    }
}
