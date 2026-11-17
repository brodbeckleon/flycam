import XCTest
@testable import FlyCamKit

final class SessionTests: XCTestCase {
    func sampleMeta() -> SessionMeta {
        SessionMeta(kind: .clip, deviceModel: "iPhone15,2", osVersion: "18.1", cameraID: 1,
                    videoFormat: VideoFormat(width: 1920, height: 1080, fps: 60),
                    cameraSettings: CameraSettings(locked: true, iso: 100, shutter: 1.0 / 120, wbTemperature: 5000, wbTint: 0),
                    floorY: -1.32, clockOffset: 1234.5678, created: "2026-11-17T19:00:00Z")
    }

    func sampleFrames(_ n: Int = 5) -> [FrameRecord] {
        (0..<n).map { i in
            FrameRecord(i: i, t: 100 + Double(i) / 60,
                        c2w: lookAt(eye: Vec3(Double(i) * 0.1, 0, 0), target: Vec3(0, 0, -4)),
                        intrinsics: hd, tracking: i == 0 ? .limited : .normal,
                        iso: i % 2 == 0 ? 100 : nil, shutter: 1.0 / 120)
        }
    }

    func testWriteReadRoundTrip() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try SessionIO.write(meta: sampleMeta(), frames: sampleFrames(), to: dir)
        XCTAssertEqual(try SessionIO.readMeta(dir), sampleMeta())
        XCTAssertEqual(try SessionIO.readFrames(dir), sampleFrames())
        // One line per frame, newline terminated.
        let text = try String(contentsOf: dir.appendingPathComponent("frames.jsonl"), encoding: .utf8)
        XCTAssertEqual(text.split(separator: "\n").count, 5)
        XCTAssertTrue(text.hasSuffix("\n"))
    }

    func testFramesWriterAppends() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("frames.jsonl")
        let w = try FramesWriter(url: url)
        for f in sampleFrames(3) { try w.append(f) }
        try w.close()
        XCTAssertEqual(w.count, 3)
        XCTAssertEqual(try SessionIO.decodeFrames(Data(contentsOf: url)), sampleFrames(3))
    }

    func testDecodeToleratesUnknownKeysAndMissingOptionals() throws {
        let c2w = Mat4.identity.columnMajor.map { String($0) }.joined(separator: ",")
        let line = #"{"i":0,"t":1.5,"c2w":[\#(c2w)],"fx":1,"fy":1,"cx":0,"cy":0,"w":2,"h":2,"tracking":"notAvailable","future":true}"#
        let frames = try SessionIO.decodeFrames(Data((line + "\n\n").utf8))
        XCTAssertEqual(frames.count, 1)
        XCTAssertNil(frames[0].iso)
        XCTAssertEqual(frames[0].tracking, .notAvailable)
        XCTAssertThrowsError(try SessionIO.decodeFrames(Data(#"{"i":0}"#.utf8)))
        let bad = #"{"i":0,"t":1.5,"c2w":[1,2],"fx":1,"fy":1,"cx":0,"cy":0,"w":2,"h":2,"tracking":"normal"}"#
        XCTAssertThrowsError(try SessionIO.decodeFrames(Data(bad.utf8))) { XCTAssertEqual($0 as? SessionError, .invalidMatrix(1)) }
    }

    func testMetaWritesExplicitNulls() throws {
        var m = sampleMeta()
        m.floorY = nil
        m.clockOffset = nil
        m.cameraID = nil
        let obj = try JSONSerialization.jsonObject(with: SessionIO.encodeMeta(m)) as! [String: Any]
        XCTAssertTrue(obj["floor_y"] is NSNull)
        XCTAssertTrue(obj["clock_offset"] is NSNull)
        XCTAssertEqual(try SessionIO.decodeMeta(SessionIO.encodeMeta(m)), m)
    }

    func testValidation() {
        XCTAssertTrue(SessionValidation.validate(sampleFrames()).isValid)
        var f = sampleFrames()
        f[2].t = f[1].t
        f[3].i = 7
        f[4].c2w[0] = 2
        let v = SessionValidation.validate(f)
        XCTAssertEqual(v.problems.count, 3)
    }

    func testRecordToPacketHeader() throws {
        let r = sampleFrames()[1]
        let h = r.packetHeader(cameraID: 4, keyframe: false, hasParameterSets: false)
        let d = try MediaPacketHeader.decode(h.encode())
        XCTAssertEqual(d.frameIndex, 1)
        XCTAssertEqual(d.timestamp, r.t)
        XCTAssertMatEqual(d.c2wMatrix, r.c2wMatrix, accuracy: 1e-6)
        XCTAssertEqual(d.intrinsics.fx, r.fx, accuracy: 1e-3)
    }

    func testPoseOverride() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(try SessionIO.readPoseOverride(dir))
        let json = #"{"format_version":1,"c2w":[1,0,0,0,0,1,0,0,0,0,1,0,0.5,0,0,1],"source":"refine_pose","inliers":40}"#
        try Data(json.utf8).write(to: dir.appendingPathComponent("pose_override.json"))
        let p = try XCTUnwrap(try SessionIO.readPoseOverride(dir))
        XCTAssertEqual(Mat4(columnMajor: p.c2w).translation, Vec3(0.5, 0, 0))
        XCTAssertEqual(p.inliers, 40)
    }
}
