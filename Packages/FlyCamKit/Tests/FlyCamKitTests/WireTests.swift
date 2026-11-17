import XCTest
@testable import FlyCamKit

final class WireTests: XCTestCase {
    func sampleHeader(frame: UInt32 = 7, keyframe: Bool = true) -> MediaPacketHeader {
        let c2w = lookAt(eye: Vec3(1, 0.5, 2), target: Vec3(0, 0, -3)).columnMajor.map(Float.init)
        return MediaPacketHeader(cameraID: 3, frameIndex: frame, timestamp: 12345.678901234, c2w: c2w,
                                 fx: 1500.5, fy: 1499.25, cx: 961.25, cy: 538.75, width: 1920, height: 1080,
                                 keyframe: keyframe, tracking: .normal, hasParameterSets: keyframe, payloadLength: 0)
    }

    func testHeaderLayout() throws {
        let h = sampleHeader()
        let bytes = h.encode()
        XCTAssertEqual(bytes.count, 110)
        XCTAssertEqual(Array(bytes[0..<4]), Array("FCAM".utf8))
        var r = ByteReader(bytes, offset: 4)
        XCTAssertEqual(try r.readLE(UInt16.self), 1)               // version @4
        XCTAssertEqual(try r.readLE(UInt16.self), 3)               // camera id @6
        XCTAssertEqual(try r.readLE(UInt32.self), 7)               // frame index @8
        XCTAssertEqual(try r.readF64(), 12345.678901234)           // timestamp @12
        XCTAssertEqual(try r.readF32(), h.c2w[0])                  // c2w[0] @20
        r = ByteReader(bytes, offset: 20 + 12 * 4)
        XCTAssertEqual(try r.readF32(), h.c2w[12])                 // translation x (column 3) @68
        r = ByteReader(bytes, offset: 84)
        XCTAssertEqual(try r.readF32(), 1500.5)                    // fx @84
        r = ByteReader(bytes, offset: 100)
        XCTAssertEqual(try r.readLE(UInt16.self), 1920)            // width @100
        XCTAssertEqual(try r.readLE(UInt16.self), 1080)            // height @102
        XCTAssertEqual(try r.readLE(UInt16.self), 0b1101)          // flags @104: key, normal(2)<<1, param sets
        XCTAssertEqual(try r.readLE(UInt32.self), 0)               // payload length @106
    }

    func testPacketRoundTrip() throws {
        for tracking in TrackingState.allCases {
            var h = sampleHeader()
            h.tracking = tracking
            let p = MediaPacket(header: h, payload: [0, 0, 0, 2, 0x40, 0x01, 0, 0, 0, 1, 0x26])
            let d = try MediaPacket.decode(p.encode())
            XCTAssertEqual(d, p)
            XCTAssertEqual(d.header.payloadLength, 11)
            XCTAssertEqual(d.header.tracking, tracking)
        }
    }

    func testDecodeErrors() {
        var bytes = sampleHeader().encode()
        bytes[0] = 0x58
        XCTAssertThrowsError(try MediaPacketHeader.decode(bytes)) { XCTAssertEqual($0 as? WireError, .badMagic([0x58, 0x43, 0x41, 0x4D])) }
        bytes = sampleHeader().encode()
        bytes[4] = 2
        XCTAssertThrowsError(try MediaPacketHeader.decode(bytes)) { XCTAssertEqual($0 as? WireError, .unsupportedVersion(2)) }
        bytes = sampleHeader().encode()
        bytes[104] = 0b110 // tracking = 3
        XCTAssertThrowsError(try MediaPacketHeader.decode(bytes)) { XCTAssertEqual($0 as? WireError, .invalidTrackingState(3)) }
        XCTAssertThrowsError(try MediaPacketHeader.decode(Array(sampleHeader().encode().prefix(50))))
        // Reserved flag bits are ignored.
        bytes = sampleHeader().encode()
        bytes[105] = 0xF0
        XCTAssertEqual(try MediaPacketHeader.decode(bytes).keyframe, true)
    }

    func testStreamParserWithArbitraryChunks() throws {
        var rng = SeededRNG(seed: 9)
        var stream = Channel.media.preamble
        var expected = [MediaPacket]()
        for i in 0..<20 {
            let payload = (0..<Int(rng.uniform(1, 400))).map { _ in UInt8.random(in: 0...255, using: &rng) }
            let p = MediaPacket(header: sampleHeader(frame: UInt32(i), keyframe: i % 5 == 0), payload: payload)
            expected.append(p)
            stream += p.encode()
        }
        var pre = PreambleReader()
        var parser = MediaStreamParser()
        var got = [MediaPacket]()
        var pos = 0
        var channel: Channel?
        while pos < stream.count {
            let n = min(stream.count - pos, Int(rng.uniform(1, 300)))
            var chunk = Array(stream[pos..<(pos + n)])
            pos += n
            if channel == nil {
                guard let (c, rest) = try pre.feed(chunk) else { continue }
                channel = c
                chunk = rest
            }
            got += try parser.feed(chunk)
        }
        XCTAssertEqual(channel, .media)
        XCTAssertEqual(got, expected)
        XCTAssertEqual(parser.bufferedByteCount, 0)
    }

    func testBadPreamble() {
        var pre = PreambleReader()
        XCTAssertThrowsError(try pre.feed(Array("HTTP".utf8)))
    }

    func testControlMessagesRoundTrip() throws {
        let messages: [ControlMessage] = [
            .hello(.init(deviceID: "A1B2", deviceModel: "iPhone15,2", osVersion: "18.1", videoFormat: .init(width: 1920, height: 1080, fps: 60))),
            .helloAck(.init(cameraID: 2)),
            .ping(.init(seq: 4, t1: 100.25)),
            .pong(.init(seq: 4, t1: 100.25, t2: 5000.5, t3: 5000.5001)),
            .status(.init(battery: 0.8, thermalState: "fair", tracking: .limited, fps: 59.9, recording: false)),
            .ack(.init(ref: "start_recording", ok: true)),
            .ack(.init(ref: "set_camera_settings", ok: false, message: "device busy")),
            .setCameraSettings(.init(lock: true, iso: 200, shutter: 1.0 / 120, wbTemperature: 5200, wbTint: -3)),
            .setCameraSettings(.init(lock: false)),
            .startRecording(.init(sessionName: "session_2026-11-17_A", clockOffset: -4321.5)),
            .stopRecording,
        ]
        var stream = Channel.control.preamble
        for m in messages { stream += try ControlProtocol.frame(m) }
        var pre = PreambleReader()
        let (ch, rest) = try XCTUnwrap(try pre.feed(stream))
        XCTAssertEqual(ch, .control)
        var parser = ControlStreamParser()
        // Feed one byte at a time to exercise partial frames.
        var got = [ControlMessage]()
        for b in rest { got += try parser.feed([b]) }
        XCTAssertEqual(got, messages)
    }

    func testControlJSONShape() throws {
        let body = try ControlProtocol.encodeJSON(.pong(.init(seq: 1, t1: 2, t2: 3, t3: 4)))
        let obj = try JSONSerialization.jsonObject(with: Data(body)) as! [String: Any]
        XCTAssertEqual(obj["type"] as? String, "pong")
        XCTAssertEqual(obj["t2"] as? Double, 3)
        let hello = try ControlProtocol.encodeJSON(.hello(.init(deviceID: "x", deviceModel: "m", osVersion: "o", videoFormat: .init(width: 1, height: 2, fps: 3))))
        let h = try JSONSerialization.jsonObject(with: Data(hello)) as! [String: Any]
        XCTAssertEqual(h["protocol_version"] as? Int, 1)
        XCTAssertEqual((h["video_format"] as? [String: Any])?["width"] as? Int, 1)
    }

    func testUnknownAndExtraKeysAreTolerated() throws {
        let m = try ControlProtocol.decodeJSON(Array(#"{"type":"future_thing","x":1}"#.utf8))
        XCTAssertEqual(m, .unknown(type: "future_thing"))
        let p = try ControlProtocol.decodeJSON(Array(#"{"type":"ping","seq":1,"t1":2.5,"extra":"ok"}"#.utf8))
        XCTAssertEqual(p, .ping(.init(seq: 1, t1: 2.5)))
        let s = try ControlProtocol.decodeJSON(Array(#"{"type":"set_camera_settings","lock":true,"iso":null}"#.utf8))
        XCTAssertEqual(s, .setCameraSettings(.init(lock: true)))
        XCTAssertThrowsError(try ControlProtocol.decodeJSON(Array("not json".utf8)))
    }

    func testControlFrameLimits() {
        var parser = ControlStreamParser()
        XCTAssertThrowsError(try parser.feed([0, 0, 0, 0]))
        var parser2 = ControlStreamParser()
        XCTAssertThrowsError(try parser2.feed([0, 0, 0x20, 0]))  // 2 MiB
    }

    func testHEVCPayload() throws {
        let vps: [UInt8] = [0x40, 0x01, 0x0c], sps: [UInt8] = [0x42, 0x01, 0x01], pps: [UInt8] = [0x44, 0x01], idr: [UInt8] = [0x26, 0x01, 0xaf, 0x00]
        let payload = HEVCPayload.join(nalUnits: [vps, sps, pps, idr])
        XCTAssertEqual(Array(payload.prefix(4)), [0, 0, 0, 3])
        XCTAssertEqual(try HEVCPayload.split(payload), [vps, sps, pps, idr])
        XCTAssertEqual([vps, sps, pps, idr].compactMap(HEVCPayload.nalType), [32, 33, 34, 19])
        XCTAssertTrue(HEVCPayload.startsWithParameterSets(payload))
        XCTAssertFalse(HEVCPayload.startsWithParameterSets(HEVCPayload.join(nalUnits: [idr])))
        XCTAssertThrowsError(try HEVCPayload.split([0, 0, 0, 9, 1]))
    }
}
