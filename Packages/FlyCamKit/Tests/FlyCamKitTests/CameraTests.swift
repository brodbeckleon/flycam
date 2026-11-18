import XCTest
@testable import FlyCamKit

final class CameraTests: XCTestCase {
    /// plan.md section 5: project(unproject(u, v, z)) == (u, v).
    func testProjectUnprojectRoundTrip() {
        var rng = SeededRNG(seed: 3)
        for _ in 0..<20 {
            let c2w = Mat4(rotation: randomRotation(&rng), translation: Vec3(rng.uniform(-3, 3), rng.uniform(-2, 2), rng.uniform(-3, 3)))
            let cam = PinholeCamera(intrinsics: hd, c2w: c2w)
            for _ in 0..<50 {
                let u = rng.uniform(-0.5, 1919.5), v = rng.uniform(-0.5, 1079.5), z = rng.uniform(0.1, 30)
                let p = cam.unproject(u: u, v: v, depth: z)
                let q = cam.project(p)!
                XCTAssertEqual(q.u, u, accuracy: 1e-9)
                XCTAssertEqual(q.v, v, accuracy: 1e-9)
                XCTAssertEqual(q.depth, z, accuracy: 1e-9)
            }
        }
    }

    func testAxisConventions() {
        // Identity pose: camera at the origin looking along -Z, +Y up.
        let cam = PinholeCamera(intrinsics: hd, c2w: .identity)
        XCTAssertEqual(cam.forward, Vec3(0, 0, -1))
        // Principal point at depth 2 is on the -Z axis.
        XCTAssertVecEqual(cam.unproject(u: hd.cx, v: hd.cy, depth: 2), Vec3(0, 0, -2), accuracy: 1e-12)
        // A point above the axis has smaller v (v grows downwards), a point to the right larger u.
        let up = cam.project(Vec3(0, 0.1, -2))!
        XCTAssertLessThan(up.v, hd.cy)
        let right = cam.project(Vec3(0.1, 0, -2))!
        XCTAssertGreaterThan(right.u, hd.cx)
        XCTAssertNil(cam.project(Vec3(0, 0, 1)), "points behind the camera do not project")
    }

    func testProjectionMatrixMatchesProject() {
        var rng = SeededRNG(seed: 4)
        let near = 0.05, far = 50.0
        for _ in 0..<10 {
            let c2w = Mat4(rotation: randomRotation(&rng), translation: Vec3(rng.uniform(-3, 3), rng.uniform(-2, 2), rng.uniform(-3, 3)))
            let cam = PinholeCamera(intrinsics: hd, c2w: c2w)
            let vp = cam.projectionMatrix(near: near, far: far) * cam.viewMatrix
            for _ in 0..<50 {
                let u = rng.uniform(0, 1919), v = rng.uniform(0, 1079), z = rng.uniform(near, far)
                let p = cam.unproject(u: u, v: v, depth: z)
                let clip = vp * Vec4(p, 1)
                let win = PinholeCamera.clipToWindow(clip, width: hd.width, height: hd.height)
                XCTAssertEqual(win.x, u + 0.5, accuracy: 1e-7)
                XCTAssertEqual(win.y, v + 0.5, accuracy: 1e-7)
                // Metal depth: 0 at near, 1 at far, monotonic.
                let expected = far / (near - far) * (-z) + near * far / (near - far)
                XCTAssertEqual(win.z, expected / z, accuracy: 1e-9)
            }
        }
        let cam = PinholeCamera(intrinsics: hd, c2w: .identity)
        let proj = cam.projectionMatrix(near: near, far: far)
        let zNear = PinholeCamera.clipToWindow(proj * Vec4(0, 0, -near, 1), width: hd.width, height: hd.height).z
        let zFar = PinholeCamera.clipToWindow(proj * Vec4(0, 0, -far, 1), width: hd.width, height: hd.height).z
        XCTAssertEqual(zNear, 0, accuracy: 1e-12)
        XCTAssertEqual(zFar, 1, accuracy: 1e-12)
    }

    func testPrincipalPointOffsetIsKept() {
        // A symmetric FOV matrix would put the principal point at the image centre; ours keeps cx, cy.
        let k = Intrinsics(fx: 1000, fy: 1000, cx: 900, cy: 500, width: 1920, height: 1080)
        let cam = PinholeCamera(intrinsics: k, c2w: .identity)
        let clip = cam.projectionMatrix(near: 0.1, far: 10) * Vec4(0, 0, -1, 1)
        let win = PinholeCamera.clipToWindow(clip, width: 1920, height: 1080)
        XCTAssertEqual(win.x, 900.5, accuracy: 1e-9)
        XCTAssertEqual(win.y, 500.5, accuracy: 1e-9)
    }

    func testScaledIntrinsics() {
        let k = hd.scaled(toWidth: 960, height: 540)
        XCTAssertEqual(k.fx, hd.fx / 2, accuracy: 1e-12)
        // The image edge u = -0.5 stays the image edge.
        XCTAssertEqual((k.cx + 0.5) * 2, hd.cx + 0.5, accuracy: 1e-12)
        // The same 3D point lands on corresponding pixels.
        let p = Vec3(0.3, -0.2, -2)
        let a = PinholeCamera.projectFromCamera(p, intrinsics: hd)!
        let b = PinholeCamera.projectFromCamera(p, intrinsics: k)!
        XCTAssertEqual((b.u + 0.5) * 2, a.u + 0.5, accuracy: 1e-9)
        XCTAssertEqual((b.v + 0.5) * 2, a.v + 0.5, accuracy: 1e-9)
    }

    func testRayDirection() {
        let c2w = lookAt(eye: Vec3(1, 1, 1), target: Vec3(0, 0, -3))
        let cam = PinholeCamera(intrinsics: hd, c2w: c2w)
        let d = cam.rayDirection(u: 100, v: 900)
        let p = cam.unproject(u: 100, v: 900, depth: 4)
        XCTAssertVecEqual(d, (p - cam.position).normalized, accuracy: 1e-12)
        XCTAssertVecEqual(cam.forward, (Vec3(0, 0, -3) - Vec3(1, 1, 1)).normalized, accuracy: 1e-12)
    }
}
