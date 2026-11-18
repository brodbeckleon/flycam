import XCTest
import FlyCamKit
@testable import DirectorCore

final class TransitionTests: XCTestCase {
    /// Scope test (c): in a rendered transition the first and last frames match the source video frames with
    /// PSNR above 35 dB, and the middle frame shows the splat (not empty).
    func testRenderedTransitionEndpointsMatchVideoAndMiddleShowsSplat() async throws {
        let fx = try await TestFixtures.shared.twoCameraFixture()
        let out = fx.dir.appendingPathComponent("transition_test.mp4")
        let result = try await OfflineTransition.render(sessionA: fx.sessionA, sessionB: fx.sessionB, splat: fx.splat, out: out)
        // 0.5 s + 1.2 s + 0.5 s at 30 fps.
        XCTAssertEqual(result.log.count, 67)
        XCTAssertEqual(result.takeFrame, 15)
        XCTAssertEqual(result.landingFrame, 51)
        XCTAssertEqual(result.timeBase, .macClock)

        // Weights: video A before and at the take, video B at and after landing, render only in the middle.
        for l in result.log[0...15] { XCTAssertEqual(l.videoA, 1); XCTAssertEqual(l.render, 0) }
        for l in result.log[51...] { XCTAssertEqual(l.videoB, 1); XCTAssertEqual(l.render, 0); XCTAssertEqual(l.programCamera, 1) }
        XCTAssertTrue(result.log.contains { $0.render == 1 })
        // The virtual camera at the take is exactly camera A (s = 0).
        let (camA, _) = SyntheticRoom.tripodCameras()
        XCTAssertEqual(result.log[15].s, 0)
        XCTAssertEqual(result.log[15].c2w, camA.c2w.columnMajor)

        let report = try await TransitionVerification.verify(sessionA: fx.sessionA, sessionB: fx.sessionB, splat: fx.splat, video: out)
        print("TransitionTests:\n\(report.summary)")
        XCTAssertEqual(report.firstVsA.outputFrame, 0)
        XCTAssertEqual(report.lastVsB.outputFrame, 66)
        XCTAssertGreaterThan(report.firstVsA.psnr, 35)
        XCTAssertGreaterThan(report.lastVsB.psnr, 35)
        XCTAssertGreaterThan(report.takeVsA.psnr, 35)
        XCTAssertGreaterThan(report.landingVsB.psnr, 35)
        XCTAssertEqual(report.middleS, 0.5, accuracy: 0.05)
        XCTAssertGreaterThan(report.middleCoverage, 0.5, "middle frame is empty")
        XCTAssertGreaterThan(report.middleVsSplatRender, 30)
        XCTAssertEqual(report.failures(), [])
    }

    func testControllerPreviewTakeAndLanding() {
        let c = TransitionController(program: 0)
        XCTAssertFalse(c.take(at: 0), "no preview selected")
        c.selectPreview(0)
        XCTAssertNil(c.preview, "program cannot be preview")
        c.selectPreview(2)
        XCTAssertTrue(c.take(at: 10))
        XCTAssertFalse(c.take(at: 10.1), "already in flight")
        c.selectPreview(3)
        XCTAssertEqual(c.preview, 2, "preview locked during the flight")
        XCTAssertEqual(c.state(at: 9.9), .video(0))
        guard case .transition(let a, let e) = c.state(at: 10.6) else { return XCTFail() }
        XCTAssertEqual(a.from, 0)
        XCTAssertEqual(a.to, 2)
        XCTAssertEqual(e, 0.6, accuracy: 1e-12)
        // Landing within 1 us of T snaps to the end.
        XCTAssertEqual(c.state(at: 10 + 1.2 - 5e-7), .video(2))
        XCTAssertEqual(c.program, 2)
        XCTAssertEqual(c.preview, 0)
        XCTAssertNil(c.active)
    }

    func testPathEndpointsAreTheRealCameras() {
        let (a, b) = SyntheticRoom.tripodCameras()
        let c = TransitionController(program: 0, preview: 1)
        let p = c.path(from: a, to: b, floorY: -1.3)
        XCTAssertEqual(p.camera(atProgress: 0), a)
        XCTAssertEqual(p.camera(atProgress: 1).c2w, b.c2w)
        XCTAssertEqual(p.camera(atProgress: 1).intrinsics, b.intrinsics)
        // Mid-flight the camera stays above the floor guard.
        for i in 1..<20 {
            XCTAssertGreaterThanOrEqual(p.camera(atProgress: Double(i) / 20).position.y, -1.3 + 0.3 - 1e-9)
        }
    }
}
