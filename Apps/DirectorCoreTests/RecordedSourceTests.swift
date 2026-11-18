import XCTest
import FlyCamKit
@testable import DirectorCore

final class RecordedSourceTests: XCTestCase {
    func testReadsSessionAndServesFramesByTimestamp() async throws {
        let fx = try await TestFixtures.shared.twoCameraFixture()
        let src = try await RecordedSource(folder: fx.sessionA)
        XCTAssertEqual(src.frameCount, 60)
        XCTAssertEqual(src.timeBase, .macClock)
        XCTAssertEqual(src.cameraID, 0)
        XCTAssertEqual(src.width, 640)
        XCTAssertEqual(src.height, 360)
        XCTAssertEqual(src.floorY!, -1.3, accuracy: 1e-6)
        // Mac clock: phone time + clock offset.
        XCTAssertEqual(src.times[0], 5000, accuracy: 1e-9)
        XCTAssertEqual(src.times[59], 5000 + 59.0 / 30, accuracy: 1e-9)

        // Forward, with jitter around each frame time (nearest wins).
        for i in 0..<60 {
            let jitter = (i % 3 == 0 ? -0.4 : 0.4) / 30.0
            let f = try XCTUnwrap(try src.frame(nearest: src.times[i] + jitter))
            XCTAssertEqual(f.index, i)
            XCTAssertEqual(FrameCode.read(f.pixelBuffer), i, "decoded video frame is frame \(i)")
            XCTAssertEqual(f.time, src.times[i])
            XCTAssertEqual(f.phoneTime, src.records[i].t)
            XCTAssertEqual(CVPixelBufferGetPixelFormatType(f.pixelBuffer), kCVPixelFormatType_32BGRA)
        }
        // Backwards and random access (seeks).
        for i in [45, 3, 59, 0, 31, 30, 12] {
            let f = try XCTUnwrap(try src.frame(nearest: src.times[i]))
            XCTAssertEqual(f.index, i)
            XCTAssertEqual(FrameCode.read(f.pixelBuffer), i)
        }
        // Outside the recording: clamped to the first / last frame.
        XCTAssertEqual(try src.frame(nearest: 0)?.index, 0)
        XCTAssertEqual(try src.frame(nearest: 1e9)?.index, 59)
        // Tie between two frames goes to the earlier one (exactly representable times).
        XCTAssertEqual(nearestIndex([0, 0.5, 1.0, 1.5], 0.75), 1)
        XCTAssertEqual(nearestIndex([0, 0.5, 1.0, 1.5], 0.76), 2)
        XCTAssertEqual(nearestIndex([], 1), nil)

        // Pose and intrinsics come from frames.jsonl.
        let f7 = try src.frame(at: 7)
        XCTAssertEqual(f7.camera, src.records[7].camera)
    }

    func testTwoSessionsShareTheMacClock() async throws {
        let fx = try await TestFixtures.shared.twoCameraFixture()
        let a = try await RecordedSource(folder: fx.sessionA)
        let b = try await RecordedSource(folder: fx.sessionB)
        XCTAssertEqual(b.cameraID, 1)
        // Different phone clocks, same Mac clock (B started 4 ms after A).
        XCTAssertNotEqual(a.records[0].t, b.records[0].t)
        XCTAssertEqual(b.times[0] - a.times[0], 0.004, accuracy: 1e-9)
        let fb = try XCTUnwrap(try b.frame(nearest: a.times[20]))
        XCTAssertEqual(fb.index, 20)
    }

    func testOtherTimeBasesAndPoseOverride() async throws {
        let fx = try await TestFixtures.shared.twoCameraFixture()
        // Copy session A and add a pose override.
        let dir = fx.dir.appendingPathComponent("override_copy")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.copyItem(at: fx.sessionA, to: dir)
        let overridePose = Mat4.lookAt(eye: Vec3(0.1, 0.2, 0.3), target: Vec3(0, 0, -5))
        let json = """
        {"format_version": 1, "c2w": \(overridePose.columnMajor), "source": "refine_pose", "frame_index": 3}
        """
        try json.write(to: dir.appendingPathComponent("pose_override.json"), atomically: true, encoding: .utf8)

        let s = try await RecordedSource(folder: dir, timeBase: .sessionStart)
        XCTAssertEqual(s.times[0], 0)
        XCTAssertEqual(s.times[30], 1.0, accuracy: 1e-9)
        XCTAssertEqual(try s.frame(at: 5).camera.c2w, overridePose)
        XCTAssertEqual(try s.frame(at: 5).camera.intrinsics, s.records[5].intrinsics)

        let noOverride = try await RecordedSource(folder: dir, timeBase: .phoneClock, usePoseOverride: false)
        XCTAssertEqual(noOverride.times[0], 1200, accuracy: 1e-9)
        XCTAssertEqual(try noOverride.frame(at: 5).camera.c2w, noOverride.records[5].c2wMatrix)
    }

    func testRejectsFrameCountMismatch() async throws {
        let fx = try await TestFixtures.shared.twoCameraFixture()
        let dir = fx.dir.appendingPathComponent("mismatch_copy")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.copyItem(at: fx.sessionA, to: dir)
        var frames = try SessionIO.readFrames(dir)
        let last = frames.last!
        frames.append(FrameRecord(i: last.i + 1, t: last.t + 1.0 / 30, c2w: last.c2wMatrix, intrinsics: last.intrinsics, tracking: .normal))
        try SessionIO.encodeFrames(frames).write(to: dir.appendingPathComponent("frames.jsonl"))
        do {
            _ = try await RecordedSource(folder: dir)
            XCTFail("expected a frame count mismatch")
        } catch let e as RecordedSourceError {
            guard case .frameCountMismatch(video: 60, lines: 61) = e else { return XCTFail("\(e)") }
        }
    }
}
