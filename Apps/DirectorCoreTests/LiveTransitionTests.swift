import XCTest
import CoreMedia
import FlyCamKit
@testable import DirectorCore

/// The Phase 4 fly-through on live sources (plan.md Phase 5 "the Phase 4 fly-through works live"): two phone clients
/// stream over localhost, the program flies between the two LiveSources.
final class LiveTransitionTests: XCTestCase {
    func render(_ scene: SplatScene, _ cam: PinholeCamera) throws -> [UInt8] {
        let ctx = scene.context
        let targets = try SplatRenderTargets(context: ctx, width: cam.intrinsics.width, height: cam.intrinsics.height)
        try scene.renderSettled(camera: cam, targets: targets)
        let comp = try Compositor(context: ctx)
        comp.background = SIMD4(0.05, 0.05, 0.06, 1)
        let pb = try makeBGRAPixelBuffer(width: cam.intrinsics.width, height: cam.intrinsics.height)
        let tex = try ctx.texture(for: pb)
        let cb = ctx.queue.makeCommandBuffer()!
        comp.encodeMix(videoA: nil, render: targets, videoB: nil, weights: .renderOnly, output: CVMetalTextureGetTexture(tex)!, commandBuffer: cb)
        try ctx.commitAndWait(cb)
        return bgraBytes(of: pb)
    }

    func testFlyThroughBetweenTwoLiveSources() async throws {
        let fx = try await TestFixtures.shared.twoCameraFixture()
        let ctx = try MetalContext.shared()
        let scene = try await SplatScene.load(url: fx.splat, context: ctx)
        let (camA, camB) = SyntheticRoom.tripodCameras()
        let imgA = try render(scene, camA), imgB = try render(scene, camB)
        try runLive(scene: scene, cams: [camA, camB], images: [imgA, imgB])
    }

    func runLive(scene: SplatScene, cams: [PinholeCamera], images: [[UInt8]]) throws {
        var cfg = DirectorServer.Config()
        cfg.advertise = false
        cfg.loopbackOnly = true
        let server = DirectorServer(config: cfg)
        let port = try server.start()
        defer { server.stop() }
        let lock = NSLock()
        var count = [UInt16: Int]()
        server.onFrame = { id, _, _ in lock.lock(); count[id, default: 0] += 1; lock.unlock() }

        let offsets = [250.0, -77.25]
        var clients = [PhoneStreamClient]()
        for p in 0..<2 {
            let c = PhoneStreamClient(hello: .init(deviceID: "live-\(p)", deviceModel: "iPhone", osVersion: "18",
                                                   videoFormat: VideoFormat(width: 640, height: 360, fps: 30)),
                                      clock: { MonotonicClock.now() - offsets[p] })
            c.connect(host: "127.0.0.1", port: port)
            clients.append(c)
        }
        let deadline = Date().addingTimeInterval(5)
        while !(clients.allSatisfy(\.isStreaming) && server.cameraInfo(0)?.offset != nil && server.cameraInfo(1)?.offset != nil)
                && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertTrue(clients.allSatisfy(\.isStreaming))

        // 12 frames per phone at 30 fps, interleaved, fixed tripod poses.
        let encoders = try (0..<2).map { _ in try HEVCEncoder(width: 640, height: 360, fps: 30) }
        let start = MonotonicClock.now()
        for i in 0..<12 {
            for p in 0..<2 {
                let id = clients[p].cameraID!
                let pb = try makeBGRAPixelBuffer(width: 640, height: 360)
                fill(pb, bgra: images[Int(id)])
                let t = clients[p].clock()
                let au = try encoders[p].encodeSync(pb, pts: CMTime(seconds: t, preferredTimescale: 1_000_000))
                let k = cams[Int(id)].intrinsics
                let h = MediaPacketHeader(cameraID: 0, frameIndex: UInt32(i), timestamp: t, c2w: cams[Int(id)].c2w.columnMajor.map(Float.init),
                                          fx: Float(k.fx), fy: Float(k.fy), cx: Float(k.cx), cy: Float(k.cy), width: 640, height: 360,
                                          keyframe: au.keyframe, tracking: .normal, hasParameterSets: au.hasParameterSets, payloadLength: 0)
                XCTAssertTrue(clients[p].send(header: h, payload: au.payload))
            }
            let next = start + Double(i + 1) / 30
            let now = MonotonicClock.now()
            if next > now { Thread.sleep(forTimeInterval: next - now) }
        }
        let d2 = Date().addingTimeInterval(5)
        while (lock.withLock { (count[0] ?? 0) < 12 || (count[1] ?? 0) < 12 }) && Date() < d2 { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertEqual(lock.withLock { count }, [0: 12, 1: 12])

        // Pairing residual between the two phones stays below one frame interval (frames sent together).
        let newest = server.withStore { s in s.cameraIDs.compactMap { s.rings[$0]?.newestTime }.min()! }
        let pair = server.withStore { $0.pair(at: newest) }
        XCTAssertEqual(pair.frames.count, 2)
        XCTAssertLessThan(pair.residual, 1.0 / 30)

        // Fly from live camera 0 to live camera 1 at the newest common time.
        let a = LiveSource(server: server, cameraID: 0, floorY: -1.3), b = LiveSource(server: server, cameraID: 1, floorY: -1.3)
        let sources: [UInt16: FrameSource] = [0: a, 1: b]
        let program = try ProgramRenderer(context: scene.context, scene: scene, width: 640, height: 360, settled: true, floorY: -1.3)
        program.compositor.background = SIMD4(0.05, 0.05, 0.06, 1)
        let controller = TransitionController(program: 0, preview: 1)
        XCTAssertTrue(controller.take(at: 100))
        func frame(elapsed: Double) throws -> ([UInt8], ProgramFrameLog) {
            let pb = try makeBGRAPixelBuffer(width: 640, height: 360)
            let tex = try scene.context.texture(for: pb)
            let state = controller.state(at: 100 + elapsed)
            let log = try program.render(state: state, time: newest, sources: sources, controller: controller,
                                         output: CVMetalTextureGetTexture(tex)!)
            return (bgraBytes(of: pb), log)
        }
        let liveA = bgraBytes(of: try a.frame(nearest: newest)!.pixelBuffer)
        let liveB = bgraBytes(of: try b.frame(nearest: newest)!.pixelBuffer)
        let (start0, log0) = try frame(elapsed: 0)
        XCTAssertEqual(log0.s, 0)
        XCTAssertGreaterThan(psnr(start0, liveA), 45, "take frame = live video A")
        let (mid, logMid) = try frame(elapsed: 0.6)
        XCTAssertEqual(logMid.render, 1)
        let virtual = PinholeCamera(intrinsics: Intrinsics(fx: logMid.fx!, fy: logMid.fy!, cx: logMid.cx!, cy: logMid.cy!, width: 640, height: 360),
                                    c2w: Mat4(columnMajor: logMid.c2w!))
        let reference = try render(scene, virtual)
        XCTAssertGreaterThan(psnr(mid, reference), 30, "mid-flight shows the splat from the virtual camera")
        XCTAssertLessThan(psnr(mid, liveA), psnr(mid, reference) - 3)
        let (end, _) = try frame(elapsed: 1.2)
        XCTAssertEqual(controller.program, 1)
        XCTAssertGreaterThan(psnr(end, liveB), 45, "landing frame = live video B")
        print("LiveTransitionTests: take vs live A \(psnr(start0, liveA)) dB, mid vs render \(psnr(mid, reference)) dB, "
              + "landing vs live B \(psnr(end, liveB)) dB, pairing residual \(pair.residual * 1000) ms")
        clients.forEach { $0.stop() }
    }
}
