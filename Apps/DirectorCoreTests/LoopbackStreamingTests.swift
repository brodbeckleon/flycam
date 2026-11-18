import XCTest
import CoreMedia
import FlyCamKit
@testable import DirectorCore

/// Scope test (d): encode, packetise, send over localhost, decode. Uses the same phone-side client and encoder as
/// the CaptureApp (Apps/Shared/Streaming) and the Mac server (DirectorServer). No Bonjour (no local network prompt).
final class LoopbackStreamingTests: XCTestCase {
    final class Recorder: PhoneStreamClientDelegate, @unchecked Sendable {
        let lock = NSLock()
        var states: [PhoneStreamClient.State] = []
        var messages: [ControlMessage] = []
        func streamClient(_ client: PhoneStreamClient, didChange state: PhoneStreamClient.State) {
            lock.lock(); states.append(state); lock.unlock()
        }
        func streamClient(_ client: PhoneStreamClient, didReceive message: ControlMessage) {
            lock.lock(); messages.append(message); lock.unlock()
            client.sendAck(ref: message.type, ok: true)
        }
        var snapshot: ([PhoneStreamClient.State], [ControlMessage]) { lock.lock(); defer { lock.unlock() }; return (states, messages) }
    }

    func wait(_ timeout: Double, _ what: String, _ cond: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertTrue(cond(), "timed out waiting for \(what)")
    }

    /// Camera-like content: the synthetic room rendered from the splat, panning slowly (frame i), as BGRA.
    /// (A synthetic pattern with saturated 16 px red/blue checks measured 23.7 dB with no colour bias: 4:2:0 chroma
    /// subsampling, not representative of camera frames. See docs/track-m/status.md, item 6.)
    func roomFrames(_ n: Int, w: Int, h: Int) async throws -> [[UInt8]] {
        let ctx = try MetalContext.shared()
        let scene = try await SplatScene(points: [], context: ctx)
        _ = scene
        let fx = try await TestFixtures.shared.twoCameraFixture()
        let room = try await SplatScene.load(url: fx.splat, context: ctx)
        let comp = try Compositor(context: ctx)
        let targets = try SplatRenderTargets(context: ctx, width: w, height: h)
        let k = Intrinsics(fx: 520.25, fy: 519.75, cx: 322.4, cy: 176.8, width: w, height: h)
        var out = [[UInt8]]()
        for i in 0..<n {
            let c2w = Mat4.lookAt(eye: Vec3(-1.7 + 0.01 * Double(i), 0.1, 1.4), target: Vec3(0, -0.6, -1.6))
            try room.renderSettled(camera: PinholeCamera(intrinsics: k, c2w: c2w), targets: targets)
            let pb = try makeBGRAPixelBuffer(width: w, height: h)
            let tex = try ctx.texture(for: pb)
            let cb = ctx.queue.makeCommandBuffer()!
            comp.encodeMix(videoA: nil, render: targets, videoB: nil, weights: .renderOnly,
                           output: CVMetalTextureGetTexture(tex)!, commandBuffer: cb)
            try ctx.commitAndWait(cb)
            out.append(bgraBytes(of: pb))
        }
        return out
    }

    func testLoopbackDeliversEveryFrameWithIntactHeaderAndTimestamps() async throws {
        let content = try await roomFrames(90, w: 640, h: 360)
        try runLoopback(content: content)
    }

    /// Blocking part of the loopback test (real-time pacing, waits).
    func runLoopback(content: [[UInt8]]) throws {
        var cfg = DirectorServer.Config()
        cfg.advertise = false
        cfg.loopbackOnly = true
        cfg.storeSeconds = 0.5
        let server = DirectorServer(config: cfg)
        let port = try server.start()
        defer { server.stop() }
        XCTAssertGreaterThan(port, 0)

        let lock = NSLock()
        var received: [(UInt16, LiveFrame, Double)] = []
        server.onFrame = { id, f, t in lock.lock(); received.append((id, f, t)); lock.unlock() }
        var logs: [String] = []
        server.onLog = { s in lock.lock(); logs.append(s); lock.unlock() }

        // The phone clock is the Mac clock minus 1234.5 s, so the true offset t_mac - t_phone is +1234.5 s.
        let trueOffset = 1234.5
        let phoneClock = { MonotonicClock.now() - trueOffset }
        let hello = ControlMessage.Hello(deviceID: "test-phone-1", deviceModel: "iPhone15,2", osVersion: "18.1",
                                         videoFormat: VideoFormat(width: 640, height: 360, fps: 60))
        let client = PhoneStreamClient(hello: hello, clock: phoneClock)
        let rec = Recorder()
        client.delegate = rec
        client.connect(host: "127.0.0.1", port: port)
        wait(5, "streaming state") { client.isStreaming }
        XCTAssertEqual(client.cameraID, 0)
        wait(3, "clock offset") { server.cameraInfo(0)?.offset != nil }

        let w = 640, h = 360, n = content.count
        let encoder = try HEVCEncoder(width: w, height: h, fps: 60, bitRate: 12_000_000, keyframeInterval: 0.5)
        client.onNeedKeyframe = { encoder.requestKeyframe() }
        let k = Intrinsics(fx: 520.25, fy: 519.75, cx: 322.4, cy: 176.8, width: w, height: h)
        var sent: [MediaPacketHeader] = []
        var sources: [[UInt8]] = []
        let start = MonotonicClock.now()
        for i in 0..<n {
            let pb = try makeBGRAPixelBuffer(width: w, height: h)
            fill(pb, bgra: content[i])
            FrameCode.stamp(i, into: pb)
            sources.append(bgraBytes(of: pb))
            let t = phoneClock()
            let au = try encoder.encodeSync(pb, pts: CMTime(seconds: t, preferredTimescale: 1_000_000))
            // A moving handheld pose and a tracking state that changes, so every header field varies.
            let c2w = Mat4(rotation: Quat(axis: .unitY, angle: Double(i) * 0.01).matrix, translation: Vec3(0.01 * Double(i), 1.2, -0.5))
            let header = MediaPacketHeader(cameraID: 99, frameIndex: UInt32(i), timestamp: t, c2w: c2w.columnMajor.map(Float.init),
                                           fx: Float(k.fx), fy: Float(k.fy), cx: Float(k.cx), cy: Float(k.cy),
                                           width: UInt16(w), height: UInt16(h), keyframe: au.keyframe,
                                           tracking: i % 17 == 5 ? .limited : .normal,
                                           hasParameterSets: au.hasParameterSets, payloadLength: 0)
            XCTAssertTrue(client.send(header: header, payload: au.payload), "frame \(i) not sent")
            var expected = MediaPacket(header: header, payload: au.payload).header
            expected.cameraID = 0
            sent.append(expected)
            // Real-time pacing at 60 fps.
            let next = start + Double(i + 1) / 60
            let now = MonotonicClock.now()
            if next > now { Thread.sleep(forTimeInterval: next - now) }
        }
        wait(10, "all frames") { lock.lock(); defer { lock.unlock() }; return received.count == n }

        lock.lock()
        let got = received
        let log = logs
        lock.unlock()
        XCTAssertEqual(got.count, n, "log: \(log)")
        XCTAssertTrue(sent[0].keyframe && sent[0].hasParameterSets, "first frame is a keyframe with VPS/SPS/PPS")
        XCTAssertGreaterThanOrEqual(sent.filter(\.keyframe).count, 3, "keyframe every 0.5 s")
        let offset = try XCTUnwrap(server.cameraInfo(0)?.offset)
        XCTAssertEqual(offset, trueOffset, accuracy: 0.002, "clock offset estimate")
        var worstPSNR = Double.infinity
        for (j, (id, f, macTime)) in got.enumerated() where j < sent.count {
            XCTAssertEqual(id, 0)
            // Header intact: every field equal to what was sent (timestamps bit-identical).
            XCTAssertEqual(f.header, sent[j], "header of frame \(j)")
            XCTAssertEqual(f.header.timestamp.bitPattern, sent[j].timestamp.bitPattern)
            XCTAssertEqual(Int(f.header.frameIndex), j, "frames in order")
            // Mac time = phone time + the offset estimate applied at arrival (exactly), and that estimate is within
            // 2 ms of the true offset. The estimate is refined by later pings, so it is compared per frame.
            XCTAssertEqual(macTime, f.header.timestamp + f.offsetApplied, accuracy: 1e-9)
            XCTAssertEqual(f.offsetApplied, trueOffset, accuracy: 0.002)
            XCTAssertEqual(macTime, f.header.timestamp + trueOffset, accuracy: 0.002)
            // The decoded picture is this frame.
            XCTAssertEqual(FrameCode.read(f.pixelBuffer), j, "decoded frame \(j)")
            worstPSNR = min(worstPSNR, psnr(bgraBytes(of: f.pixelBuffer), sources[j]))
            XCTAssertLessThan(f.receivedAt - macTime, 0.5, "latency")
        }
        XCTAssertGreaterThan(worstPSNR, 30, "decoded frames match the source frames")
        print("LoopbackStreamingTests: \(got.count)/\(n) frames, offset error \((offset - trueOffset) * 1000) ms, worst PSNR \(worstPSNR) dB, "
              + "mean latency \(got.map { $0.1.receivedAt - $0.2 }.reduce(0, +) / Double(got.count) * 1000) ms")
        XCTAssertEqual(client.droppedPackets, 0)

        // Frame store and LiveSource: last 0.5 s kept, nearest frame by Mac time.
        let live = LiveSource(server: server, cameraID: 0)
        let range = try XCTUnwrap(live.availableTimes)
        XCTAssertLessThanOrEqual(range.upperBound - range.lowerBound, 0.5 + 1e-9)
        let last = got.last!
        let lf = try XCTUnwrap(try live.frame(nearest: last.2))
        XCTAssertEqual(lf.index, n - 1)
        XCTAssertEqual(lf.camera.c2w, last.1.header.c2wMatrix)
        XCTAssertEqual(lf.camera.intrinsics, last.1.header.intrinsics)
        XCTAssertEqual(live.width, w)
        XCTAssertEqual(FrameCode.read(lf.pixelBuffer), n - 1)
        let prev = try XCTUnwrap(try live.frame(nearest: got[n - 3].2 + 0.001))
        XCTAssertEqual(prev.index, n - 3)

        // Control channel round trip: settings pushed, recording started with the offset, acks and status back.
        server.pushCameraSettings(.init(lock: true, iso: 200, shutter: 1.0 / 120, wbTemperature: 5000, wbTint: 0))
        server.startRecordingAll(sessionName: "R1")
        server.stopRecordingAll()
        client.sendStatus(.init(battery: 0.8, thermalState: "fair", tracking: .normal, fps: 59.9, recording: false))
        wait(3, "acks") { (server.cameraInfo(0)?.acks.count ?? 0) >= 3 && server.cameraInfo(0)?.lastStatus != nil }
        let msgs = rec.snapshot.1
        XCTAssertEqual(msgs.map(\.type), ["set_camera_settings", "start_recording", "stop_recording"])
        if case .startRecording(let s) = msgs[1] {
            XCTAssertEqual(s.sessionName, "R1_cam0")
            XCTAssertEqual(s.clockOffset, trueOffset, accuracy: 0.002)
        } else { XCTFail("start_recording missing") }
        XCTAssertEqual(server.cameraInfo(0)?.acks.map(\.ref), ["set_camera_settings", "start_recording", "stop_recording"])
        XCTAssertEqual(server.cameraInfo(0)?.lastStatus?.thermalState, "fair")
        XCTAssertGreaterThanOrEqual(client.pingsAnswered, 10)
        client.stop()
    }

    func testCameraIDsAreStablePerDeviceAndMediaBeforeHelloIsRejected() throws {
        var cfg = DirectorServer.Config()
        cfg.advertise = false
        cfg.loopbackOnly = true
        let server = DirectorServer(config: cfg)
        let port = try server.start()
        defer { server.stop() }
        func hello(_ id: String) -> ControlMessage.Hello {
            .init(deviceID: id, deviceModel: "iPhone", osVersion: "18", videoFormat: VideoFormat(width: 64, height: 64, fps: 30))
        }
        let a = PhoneStreamClient(hello: hello("A"))
        a.connect(host: "127.0.0.1", port: port)
        wait(5, "A streaming") { a.isStreaming }
        let b = PhoneStreamClient(hello: hello("B"))
        b.connect(host: "127.0.0.1", port: port)
        wait(5, "B streaming") { b.isStreaming }
        XCTAssertEqual(a.cameraID, 0)
        XCTAssertEqual(b.cameraID, 1)
        a.stop()
        wait(3, "A disconnected") { server.cameraInfo(0)?.connected == false }
        let a2 = PhoneStreamClient(hello: hello("A"))
        a2.connect(host: "127.0.0.1", port: port)
        wait(5, "A again") { a2.isStreaming }
        XCTAssertEqual(a2.cameraID, 0, "same device gets the same camera id")

        // A raw media connection for an unknown camera is closed by the server; the server keeps running.
        let lock = NSLock()
        var logs: [String] = []
        server.onLog = { s in lock.lock(); logs.append(s); lock.unlock() }
        let raw = NWConnectionProbe(port: port)
        let header = MediaPacketHeader(cameraID: 77, frameIndex: 0, timestamp: 1, c2w: Mat4.identity.columnMajor.map(Float.init),
                                       fx: 1, fy: 1, cx: 0, cy: 0, width: 64, height: 64, keyframe: true, tracking: .normal,
                                       hasParameterSets: false, payloadLength: 0)
        raw.send(Channel.media.preamble + MediaPacket(header: header, payload: [0, 0, 0, 1, 2]).encode())
        wait(3, "rejection logged") { lock.lock(); defer { lock.unlock() }; return logs.contains { $0.contains("unknown camera 77") } }
        raw.close()
        // Bad preamble is rejected too.
        let bad = NWConnectionProbe(port: port)
        bad.send(Array("HTTP".utf8))
        wait(3, "bad preamble logged") { lock.lock(); defer { lock.unlock() }; return logs.contains { $0.contains("rejected connection") } }
        bad.close()
        XCTAssertTrue(b.isStreaming)
        a2.stop()
        b.stop()
    }
}

import Network

/// Minimal raw TCP client for protocol-violation tests.
final class NWConnectionProbe {
    let c: NWConnection
    init(port: UInt16) {
        c = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        c.start(queue: DispatchQueue(label: "probe"))
    }
    func send(_ bytes: [UInt8]) { c.send(content: Data(bytes), completion: .contentProcessed { _ in }) }
    func close() { c.cancel() }
}
