// Unit quaternion (Hamilton convention, x y z = vector part, w = scalar part).
// Tools/flycam_tools/geometry.py implements the same formulas; keep them in step.

import Foundation

public struct Quat: Equatable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public var z: Double
    public var w: Double

    public init(x: Double, y: Double, z: Double, w: Double) {
        self.x = x
        self.y = y
        self.z = z
        self.w = w
    }

    public static let identity = Quat(x: 0, y: 0, z: 0, w: 1)

    /// Rotation by `angle` radians about the unit vector `axis`.
    public init(axis: Vec3, angle: Double) {
        let a = axis.normalized
        let s = sin(angle / 2)
        self.init(x: a.x * s, y: a.y * s, z: a.z * s, w: cos(angle / 2))
    }

    /// From a rotation matrix (Shepperd's method). The result has w >= 0.
    public init(_ m: Mat3) {
        let trace = m[0, 0] + m[1, 1] + m[2, 2]
        var q: Quat
        if trace > 0 {
            let s = (trace + 1).squareRoot() * 2
            q = Quat(x: (m[2, 1] - m[1, 2]) / s, y: (m[0, 2] - m[2, 0]) / s, z: (m[1, 0] - m[0, 1]) / s, w: s / 4)
        } else if m[0, 0] > m[1, 1] && m[0, 0] > m[2, 2] {
            let s = (1 + m[0, 0] - m[1, 1] - m[2, 2]).squareRoot() * 2
            q = Quat(x: s / 4, y: (m[0, 1] + m[1, 0]) / s, z: (m[0, 2] + m[2, 0]) / s, w: (m[2, 1] - m[1, 2]) / s)
        } else if m[1, 1] > m[2, 2] {
            let s = (1 + m[1, 1] - m[0, 0] - m[2, 2]).squareRoot() * 2
            q = Quat(x: (m[0, 1] + m[1, 0]) / s, y: s / 4, z: (m[1, 2] + m[2, 1]) / s, w: (m[0, 2] - m[2, 0]) / s)
        } else {
            let s = (1 + m[2, 2] - m[0, 0] - m[1, 1]).squareRoot() * 2
            q = Quat(x: (m[0, 2] + m[2, 0]) / s, y: (m[1, 2] + m[2, 1]) / s, z: s / 4, w: (m[1, 0] - m[0, 1]) / s)
        }
        q = q.normalized
        if q.w < 0 { q = q.negated }
        self = q
    }

    public var negated: Quat { Quat(x: -x, y: -y, z: -z, w: -w) }

    public func dot(_ b: Quat) -> Double { x * b.x + y * b.y + z * b.z + w * b.w }

    public var length: Double { dot(self).squareRoot() }

    public var normalized: Quat {
        let l = length
        precondition(l > 0, "cannot normalise a zero quaternion")
        return Quat(x: x / l, y: y / l, z: z / l, w: w / l)
    }

    public var matrix: Mat3 {
        let xx = x * x, yy = y * y, zz = z * z
        let xy = x * y, xz = x * z, yz = y * z
        let wx = w * x, wy = w * y, wz = w * z
        return Mat3(rows:
            Vec3(1 - 2 * (yy + zz), 2 * (xy - wz), 2 * (xz + wy)),
            Vec3(2 * (xy + wz), 1 - 2 * (xx + zz), 2 * (yz - wx)),
            Vec3(2 * (xz - wy), 2 * (yz + wx), 1 - 2 * (xx + yy))
        )
    }

    /// Angle in radians of the rotation from `self` to `b` (0 ... pi).
    public func angle(to b: Quat) -> Double {
        let d = min(1, abs(dot(b)))
        return 2 * acos(d)
    }

    /// Spherical linear interpolation along the shorter arc. slerp(a, b, 0) == a, slerp(a, b, 1) == ±b.
    public static func slerp(_ a: Quat, _ b: Quat, _ t: Double) -> Quat {
        if t == 0 { return a }
        var b = b
        var d = a.dot(b)
        if d < 0 {
            b = b.negated
            d = -d
        }
        if t == 1 { return b }
        if d > 0.9995 {
            // Nearly identical: normalised lerp is accurate and avoids division by sin ~ 0.
            let q = Quat(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t,
                         z: a.z + (b.z - a.z) * t, w: a.w + (b.w - a.w) * t)
            return q.normalized
        }
        let theta = acos(d)
        let s = sin(theta)
        let wa = sin((1 - t) * theta) / s
        let wb = sin(t * theta) / s
        return Quat(x: a.x * wa + b.x * wb, y: a.y * wa + b.y * wb,
                    z: a.z * wa + b.z * wb, w: a.w * wa + b.w * wb)
    }
}

/// Spherical interpolation between two unit vectors. Endpoints are returned exactly.
/// For antiparallel inputs the rotation axis is `fallbackAxis` (projected to be perpendicular).
public func slerpDirection(_ a: Vec3, _ b: Vec3, _ t: Double, fallbackAxis: Vec3 = .unitY) -> Vec3 {
    if t == 0 { return a }
    if t == 1 { return b }
    let d = max(-1, min(1, a.dot(b)))
    let theta = acos(d)
    if theta < 1e-9 {
        return Vec3.lerp(a, b, t).normalized
    }
    if Double.pi - theta < 1e-6 {
        // Antiparallel: rotate a about an axis perpendicular to a.
        var axis = fallbackAxis - a * fallbackAxis.dot(a)
        if axis.length < 1e-9 {
            axis = Vec3.unitX - a * a.x
        }
        let q = Quat(axis: axis.normalized, angle: theta * t)
        return q.matrix * a
    }
    let s = sin(theta)
    return a * (sin((1 - t) * theta) / s) + b * (sin(t * theta) / s)
}
