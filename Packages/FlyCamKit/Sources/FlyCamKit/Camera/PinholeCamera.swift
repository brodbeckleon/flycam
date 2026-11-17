// Pinhole camera with ARKit conventions (plan.md section 5, docs/protocol.md 1.2-1.3).

import Foundation

/// Intrinsics in pixels for an image of `width x height` pixels.
/// Integer pixel coordinates are pixel centres; u to the right, v down.
public struct Intrinsics: Equatable, Sendable, Codable {
    public var fx: Double
    public var fy: Double
    public var cx: Double
    public var cy: Double
    public var width: Int
    public var height: Int

    public init(fx: Double, fy: Double, cx: Double, cy: Double, width: Int, height: Int) {
        self.fx = fx
        self.fy = fy
        self.cx = cx
        self.cy = cy
        self.width = width
        self.height = height
    }

    /// The same camera at a different image resolution (pixel-centre convention).
    public func scaled(toWidth w: Int, height h: Int) -> Intrinsics {
        let sx = Double(w) / Double(width)
        let sy = Double(h) / Double(height)
        return Intrinsics(fx: fx * sx, fy: fy * sy,
                          cx: (cx + 0.5) * sx - 0.5, cy: (cy + 0.5) * sy - 0.5,
                          width: w, height: h)
    }
}

/// A projected point: pixel coordinates and depth along the viewing axis (> 0 in front).
public struct PixelProjection: Equatable, Sendable {
    public var u: Double
    public var v: Double
    public var depth: Double

    public init(u: Double, v: Double, depth: Double) {
        self.u = u
        self.v = v
        self.depth = depth
    }
}

public struct PinholeCamera: Equatable, Sendable {
    public var intrinsics: Intrinsics
    /// Camera-to-world, ARKit convention (camera looks along -Z, +Y up).
    public var c2w: Mat4

    public init(intrinsics: Intrinsics, c2w: Mat4) {
        self.intrinsics = intrinsics
        self.c2w = c2w
    }

    public var position: Vec3 { c2w.translation }

    /// Unit viewing direction in world coordinates (-Z axis of the camera).
    public var forward: Vec3 { (-c2w.column(2).xyz).normalized }

    public var up: Vec3 { c2w.column(1).xyz.normalized }

    /// Camera-space point for pixel (u, v) at depth z > 0 along the viewing axis.
    public static func unprojectToCamera(u: Double, v: Double, depth z: Double, intrinsics k: Intrinsics) -> Vec3 {
        Vec3((u - k.cx) / k.fx * z, -(v - k.cy) / k.fy * z, -z)
    }

    /// Camera-space point to pixel. Returns nil for points not in front of the camera.
    public static func projectFromCamera(_ p: Vec3, intrinsics k: Intrinsics) -> PixelProjection? {
        let depth = -p.z
        guard depth > 0 else { return nil }
        return PixelProjection(u: k.cx + k.fx * p.x / depth, v: k.cy - k.fy * p.y / depth, depth: depth)
    }

    /// World point for pixel (u, v) at depth z > 0 (plan.md section 5, "Unprojection").
    public func unproject(u: Double, v: Double, depth z: Double) -> Vec3 {
        c2w.transformPoint(Self.unprojectToCamera(u: u, v: v, depth: z, intrinsics: intrinsics))
    }

    /// World point to pixel. Returns nil for points behind the camera.
    public func project(_ world: Vec3) -> PixelProjection? {
        Self.projectFromCamera(c2w.rigidInverse.transformPoint(world), intrinsics: intrinsics)
    }

    /// Unit ray direction in world coordinates through pixel (u, v).
    public func rayDirection(u: Double, v: Double) -> Vec3 {
        c2w.transformDirection(Self.unprojectToCamera(u: u, v: v, depth: 1, intrinsics: intrinsics)).normalized
    }

    /// World-to-camera (view) matrix.
    public var viewMatrix: Mat4 { c2w.rigidInverse }

    /// Metal projection matrix with an off-centre frustum built from fx, fy, cx, cy.
    /// Clip z in [0, 1] (0 at `near`). The viewport maps pixel (u, v) to window (u + 0.5, v + 0.5).
    public func projectionMatrix(near: Double, far: Double) -> Mat4 {
        Self.projectionMatrix(intrinsics: intrinsics, near: near, far: far)
    }

    public static func projectionMatrix(intrinsics k: Intrinsics, near: Double, far: Double) -> Mat4 {
        precondition(near > 0 && far > near, "need 0 < near < far")
        let w = Double(k.width), h = Double(k.height)
        return Mat4(rows: [
            [2 * k.fx / w, 0, 1 - (2 * k.cx + 1) / w, 0],
            [0, 2 * k.fy / h, (2 * k.cy + 1) / h - 1, 0],
            [0, 0, far / (near - far), near * far / (near - far)],
            [0, 0, -1, 0],
        ])
    }

    /// Maps a clip-space position to window coordinates (origin top-left, pixel centres at +0.5)
    /// and NDC depth, as the Metal rasteriser does with a full-image viewport.
    public static func clipToWindow(_ clip: Vec4, width: Int, height: Int) -> (x: Double, y: Double, z: Double) {
        let nx = clip.x / clip.w, ny = clip.y / clip.w, nz = clip.z / clip.w
        return ((nx + 1) / 2 * Double(width), (1 - ny) / 2 * Double(height), nz)
    }
}
