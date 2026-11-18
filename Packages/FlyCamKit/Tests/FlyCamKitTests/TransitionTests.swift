import XCTest
@testable import FlyCamKit

final class TransitionTests: XCTestCase {
    let k = Intrinsics(fx: 1500, fy: 1500, cx: 960, cy: 540, width: 1920, height: 1080)
    let subject = Vec3(0, 0, -4)

    func makeCams(_ kB: Intrinsics? = nil) -> (PinholeCamera, PinholeCamera) {
        let a = PinholeCamera(intrinsics: k, c2w: lookAt(eye: Vec3(-2, 0.2, 0), target: subject))
        let b = PinholeCamera(intrinsics: kB ?? k, c2w: lookAt(eye: Vec3(2.5, -0.1, -1), target: subject))
        return (a, b)
    }

    func testSmootherstep() {
        XCTAssertEqual(smootherstep(0), 0)
        XCTAssertEqual(smootherstep(1), 1)
        XCTAssertEqual(smootherstep(0.5), 0.5, accuracy: 1e-15)
        XCTAssertEqual(smootherstep(-1), 0)
        XCTAssertEqual(smootherstep(2), 1)
        // Zero first derivative at both ends.
        let h = 1e-6
        XCTAssertLessThan(smootherstep(h) / h, 1e-9)
        XCTAssertLessThan((1 - smootherstep(1 - h)) / h, 1e-9)
    }

    /// plan.md Phase 4: at s = 0 and s = 1 the virtual camera equals the real camera exactly.
    func testEndpointsAreExact() {
        let (a, b) = makeCams()
        let path = TransitionPath(from: a, to: b, floorY: -1.3)
        XCTAssertEqual(path.camera(atProgress: 0), a)
        XCTAssertEqual(path.camera(atProgress: 1), b)
        XCTAssertEqual(path.camera(atTime: 0), a)
        XCTAssertEqual(path.camera(atTime: path.config.duration), b)
        XCTAssertEqual(path.camera(atTime: 99), b)
    }

    func testInterestPointOfCrossingAxes() {
        let (a, b) = makeCams()
        let (p, method) = TransitionPath.interestPoint(a: a, b: b, config: TransitionConfig())
        XCTAssertEqual(method, .axesMidpoint)
        // Both cameras look exactly at the subject, so the axes intersect there.
        XCTAssertVecEqual(p, subject, accuracy: 1e-9)
    }

    func testInterestPointOfSkewAxes() {
        // Axis A along -Z through (0, 0, 0); axis B along +X through (-5, 1, -3). Closest points
        // (0, 0, -3) and (0, 1, -3) -> midpoint (0, 0.5, -3).
        let a = PinholeCamera(intrinsics: k, c2w: .identity)
        let b = PinholeCamera(intrinsics: k, c2w: lookAt(eye: Vec3(-5, 1, -3), target: Vec3(0, 1, -3)))
        let (p, method) = TransitionPath.interestPoint(a: a, b: b, config: TransitionConfig())
        XCTAssertEqual(method, .axesMidpoint)
        XCTAssertVecEqual(p, Vec3(0, 0.5, -3), accuracy: 1e-12)
    }

    func testInterestPointFallbacks() {
        let cfg = TransitionConfig(medianSceneDepth: 2)
        // Parallel axes.
        let a = PinholeCamera(intrinsics: k, c2w: .identity)
        let b = PinholeCamera(intrinsics: k, c2w: Mat4(rotation: .identity, translation: Vec3(1, 0, 0)))
        var r = TransitionPath.interestPoint(a: a, b: b, config: cfg)
        XCTAssertEqual(r.1, .medianDepth)
        XCTAssertVecEqual(r.0, Vec3(0.5, 0, -2), accuracy: 1e-12)

        // Axes cross behind camera B (B looks away from the crossing).
        let b2 = PinholeCamera(intrinsics: k, c2w: lookAt(eye: Vec3(2, 0, -3), target: Vec3(4, 0, -3)))
        r = TransitionPath.interestPoint(a: a, b: b2, config: cfg)
        XCTAssertEqual(r.1, .medianDepth)

        // Axes cross further than 20 m away (nearly parallel but above the parallel threshold).
        let b3 = PinholeCamera(intrinsics: k, c2w: lookAt(eye: Vec3(1, 0, 0), target: Vec3(0, 0, -40)))
        r = TransitionPath.interestPoint(a: a, b: b3, config: cfg)
        XCTAssertEqual(r.1, .medianDepth)
    }

    func testOrbitKeepsDistanceProfile() {
        let (a, b) = makeCams()
        let path = TransitionPath(from: a, to: b, floorY: nil)
        let dA = a.position.distance(to: path.interestPoint)
        let dB = b.position.distance(to: path.interestPoint)
        for i in 1..<20 {
            let s = Double(i) / 20
            let c = path.camera(atProgress: s)
            XCTAssertEqual(c.position.distance(to: path.interestPoint), (1 - s) * dA + s * dB, accuracy: 1e-9)
            XCTAssertLessThan(c.c2w.rigidityError, 1e-12)
        }
        // The arc does not pass through the subject: mid-flight distance stays well away from P.
        XCTAssertGreaterThan(path.camera(atProgress: 0.5).position.distance(to: subject), 0.9 * min(dA, dB))
    }

    func testRotationAndIntrinsicsInterpolation() {
        let kB = Intrinsics(fx: 3000, fy: 3000, cx: 980, cy: 520, width: 1920, height: 1080)
        let (a, b) = makeCams(kB)
        let path = TransitionPath(from: a, to: b, floorY: nil)
        let mid = path.camera(atProgress: 0.5)
        // Focal length in log space: geometric mean at s = 0.5.
        XCTAssertEqual(mid.intrinsics.fx, (1500.0 * 3000.0).squareRoot(), accuracy: 1e-9)
        XCTAssertEqual(mid.intrinsics.cx, 970, accuracy: 1e-12)
        XCTAssertEqual(mid.intrinsics.cy, 530, accuracy: 1e-12)
        let qA = Quat(a.c2w.rotation), qB = Quat(b.c2w.rotation), qM = Quat(mid.c2w.rotation)
        XCTAssertEqual(qA.angle(to: qM), qM.angle(to: qB), accuracy: 1e-9)
        XCTAssertEqual(qA.angle(to: qM) * 2, qA.angle(to: qB), accuracy: 1e-9)
    }

    func testDifferentResolutionTargetIsScaled() {
        let kB = Intrinsics(fx: 750, fy: 750, cx: 479.5, cy: 269.5, width: 960, height: 540)
        let (a, b) = makeCams(kB)
        let path = TransitionPath(from: a, to: b, floorY: nil)
        let end = path.camera(atProgress: 1)
        XCTAssertEqual(end.intrinsics.width, 1920)
        XCTAssertEqual(end.intrinsics.fx, 1500, accuracy: 1e-12)
        XCTAssertEqual(end.c2w, b.c2w)
    }

    func testPathIsContinuous() {
        let (a, b) = makeCams()
        let path = TransitionPath(from: a, to: b, floorY: -1.3)
        let n = 600
        var prev = path.camera(atTime: 0)
        var maxStep = 0.0, maxAngle = 0.0
        for i in 1...n {
            let c = path.camera(atTime: path.config.duration * Double(i) / Double(n))
            maxStep = max(maxStep, c.position.distance(to: prev.position))
            maxAngle = max(maxAngle, Quat(c.c2w.rotation).angle(to: Quat(prev.c2w.rotation)))
            prev = c
        }
        // Path length is a few metres; at 600 steps no step may be more than a few centimetres.
        XCTAssertLessThan(maxStep, 0.03)
        XCTAssertLessThan(maxAngle, 0.01)
    }

    func testFloorGuard() {
        // Two cameras 0.4 m above the floor look up at a point 0.9 m above them. The orbit around
        // that point sags in the middle (to about 0.08 m above the floor) and must be held at floorY + 0.3.
        let floorY = -1.0
        let target = Vec3(0, 0.3, -3)
        let a = PinholeCamera(intrinsics: k, c2w: lookAt(eye: Vec3(-3, -0.6, -3), target: target))
        let b = PinholeCamera(intrinsics: k, c2w: lookAt(eye: Vec3(0, -0.6, 0), target: target))
        let path = TransitionPath(from: a, to: b, floorY: floorY)
        let unguarded = TransitionPath(from: a, to: b, floorY: nil)
        var dipped = false
        for i in 1..<100 {
            let s = Double(i) / 100
            let y = path.camera(atProgress: s).position.y
            XCTAssertGreaterThanOrEqual(y, floorY + 0.3 - 1e-12)
            if unguarded.camera(atProgress: s).position.y < floorY + 0.3 { dipped = true }
        }
        XCTAssertTrue(dipped, "test geometry must make the unguarded path dip below the clearance")
    }

    func testFloorGuardKeepsLowEndpointsExact() {
        // Phone mounted 0.1 m above the floor: the guard must not lift the endpoint.
        let floorY = -1.0
        let a = PinholeCamera(intrinsics: k, c2w: lookAt(eye: Vec3(-2, -0.9, 0), target: subject))
        let b = PinholeCamera(intrinsics: k, c2w: lookAt(eye: Vec3(2, 0, 0), target: subject))
        let path = TransitionPath(from: a, to: b, floorY: floorY)
        let near0 = path.camera(atProgress: 1e-6)
        XCTAssertLessThan(near0.position.distance(to: a.position), 1e-4)
    }

    func testBlendWeights() {
        let f = 0.15
        func w(_ u: Double) -> BlendWeights { TransitionPath.blendWeights(timeFraction: u, fadeFraction: f) }
        XCTAssertEqual(w(0), BlendWeights(videoA: 1, render: 0, videoB: 0))
        XCTAssertEqual(w(1), BlendWeights(videoA: 0, render: 0, videoB: 1))
        XCTAssertEqual(w(0.5), BlendWeights(videoA: 0, render: 1, videoB: 0))
        XCTAssertEqual(w(0.075).videoA, 0.5, accuracy: 1e-12)
        XCTAssertEqual(w(0.925).videoB, 0.5, accuracy: 1e-12)
        XCTAssertEqual(w(f).videoA, 0, accuracy: 1e-12)
        for i in 0...100 {
            let b = w(Double(i) / 100)
            XCTAssertEqual(b.videoA + b.render + b.videoB, 1, accuracy: 1e-12)
            XCTAssertGreaterThanOrEqual(min(b.videoA, b.render, b.videoB), -1e-12)
        }
        let p = TransitionPath.peopleWeights(progress: 0.3)
        XCTAssertEqual(p.a, 0.7, accuracy: 1e-12)
        XCTAssertEqual(p.b, 0.3, accuracy: 1e-12)
    }
}
