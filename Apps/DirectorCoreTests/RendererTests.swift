import XCTest
import simd
import FlyCamKit
@testable import DirectorCore

/// Scope tests (a) and (b): Gaussians at known 3D points, rendered offscreen with MetalSplatter through a
/// projection matrix built from explicit fx, fy, cx, cy with an off-centre principal point.
final class RendererTests: XCTestCase {
    // 1280 x 720 with the principal point far from the image centre (639.5, 359.5).
    let intrinsics = Intrinsics(fx: 1100, fy: 1000, cx: 703.25, cy: 301.75, width: 1280, height: 720)

    var c2w: Mat4 {
        // Camera at (0.4, 1.3, 2.5), yawed 25 degrees left and pitched 8 degrees down.
        let yaw = Quat(axis: .unitY, angle: 25 * .pi / 180)
        let pitch = Quat(axis: .unitX, angle: -8 * .pi / 180)
        return Mat4(rotation: yaw.matrix * pitch.matrix, translation: Vec3(0.4, 1.3, 2.5))
    }

    /// Plan.md section 5 projection, written out independently of FlyCamKit:
    /// camera point = w2c * p; u = cx + fx * x / (-z); v = cy - fy * y / (-z); depth = -z.
    func planProjection(_ p: Vec3) -> (u: Double, v: Double, depth: Double) {
        let w2c = c2w.rigidInverse
        let q = w2c.transformPoint(p)
        let k = intrinsics
        return (k.cx + k.fx * q.x / -q.z, k.cy - k.fy * q.y / -q.z, -q.z)
    }

    /// World points spread over the image (including near the corners) at depths from 1.2 m to 9 m.
    func knownPoints() -> [Vec3] {
        let cam = PinholeCamera(intrinsics: intrinsics, c2w: c2w)
        var pts = [Vec3]()
        let us: [Double] = [90, 400, 703.25, 1000, 1190]
        let vs: [Double] = [70, 301.75, 520, 650]
        var n = 0
        for v in vs {
            for u in us {
                // Non-integer pixel targets so that rounding errors would show.
                let depth = 1.2 + Double(n % 7) * 1.3
                pts.append(cam.unproject(u: u + 0.37 * Double(n % 3), v: v - 0.29 * Double(n % 4), depth: depth))
                n += 1
            }
        }
        return pts
    }

    func makeScene(points: [Vec3]) async throws -> (SplatScene, [Gaussian]) {
        let ctx = try MetalContext.shared()
        // Constant pixel footprint (sigma about 4 px) independent of depth.
        let gaussians = points.enumerated().map { (i, p) -> Gaussian in
            let d = planProjection(p).depth
            return Gaussian(position: p.simdFloat, color: SIMD3(0.9, 0.3 + 0.05 * Float(i % 10), 0.2),
                            opacity: 0.99, radius: Float(d * 4 / 1050))
        }
        // Round trip through a PLY file so that MetalSplatter's PLY loading is part of the test.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("flycam-known-\(UUID().uuidString).ply")
        try GaussianPLY.write(gaussians, to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let scene = try await SplatScene.load(url: url, context: ctx)
        XCTAssertEqual(scene.splatCount, gaussians.count)
        return (scene, gaussians)
    }

    func testGaussiansRenderAtProjectedPositionWithin1px() async throws {
        let points = knownPoints()
        let (scene, _) = try await makeScene(points: points)
        let ctx = scene.context
        let targets = try SplatRenderTargets(context: ctx, width: intrinsics.width, height: intrinsics.height)
        try scene.renderSettled(camera: PinholeCamera(intrinsics: intrinsics, c2w: c2w), targets: targets)
        let color = try Readback.rgba16Float(targets.color, context: ctx)

        var worst = 0.0
        for p in points {
            let e = planProjection(p)
            // Alpha-weighted centroid in a window around the prediction. Pixel centres are integers.
            let r = 18
            var sw = 0.0, su = 0.0, sv = 0.0
            for y in max(0, Int(e.v) - r)...min(intrinsics.height - 1, Int(e.v) + r) {
                for x in max(0, Int(e.u) - r)...min(intrinsics.width - 1, Int(e.u) + r) {
                    let a = Double(color[x, y, 3])
                    sw += a
                    su += a * Double(x)
                    sv += a * Double(y)
                }
            }
            XCTAssertGreaterThan(sw, 5, "no splat near predicted pixel (\(e.u), \(e.v))")
            guard sw > 0 else { continue }
            let du = su / sw - e.u, dv = sv / sw - e.v
            let err = (du * du + dv * dv).squareRoot()
            worst = max(worst, err)
            XCTAssertLessThan(err, 1.0, "splat at (\(su / sw), \(sv / sw)), predicted (\(e.u), \(e.v)), depth \(e.depth)")
        }
        print("RendererTests: worst centroid error \(worst) px over \(points.count) Gaussians")

        // Also cross-check against FlyCamKit's projection used everywhere else.
        let cam = PinholeCamera(intrinsics: intrinsics, c2w: c2w)
        for p in points {
            let a = planProjection(p), b = cam.project(p)!
            XCTAssertEqual(a.u, b.u, accuracy: 1e-9)
            XCTAssertEqual(a.v, b.v, accuracy: 1e-9)
        }
    }

    func testDepthReadBackWithin2Percent() async throws {
        let points = knownPoints()
        let (scene, _) = try await makeScene(points: points)
        let ctx = scene.context
        let targets = try SplatRenderTargets(context: ctx, width: intrinsics.width, height: intrinsics.height)
        try scene.renderSettled(camera: PinholeCamera(intrinsics: intrinsics, c2w: c2w), targets: targets)
        let depth = try Readback.r32Float(targets.depth, context: ctx)

        var worst = 0.0
        for p in points {
            let e = planProjection(p)
            let x = Int(e.u.rounded()), y = Int(e.v.rounded())
            let z = Double(depth[x, y, 0])
            let rel = abs(z - e.depth) / e.depth
            worst = max(worst, rel)
            XCTAssertLessThan(rel, 0.02, "depth \(z) at (\(x), \(y)), true \(e.depth)")
        }
        print("RendererTests: worst relative depth error \(worst)")

        // Empty pixels read 0 (no content), as documented for the .f32 export.
        XCTAssertEqual(depth[2, 2, 0], 0)
    }

    func testEmptySceneRendersTransparent() async throws {
        let ctx = try MetalContext.shared()
        let scene = try await SplatScene(points: [], context: ctx)
        let targets = try SplatRenderTargets(context: ctx, width: 64, height: 32)
        try scene.renderSettled(camera: PinholeCamera(intrinsics: Intrinsics(fx: 50, fy: 50, cx: 31.5, cy: 15.5, width: 64, height: 32), c2w: .identity), targets: targets)
        let color = try Readback.rgba16Float(targets.color, context: ctx)
        XCTAssertEqual(color.data.max(), 0)
    }
}
