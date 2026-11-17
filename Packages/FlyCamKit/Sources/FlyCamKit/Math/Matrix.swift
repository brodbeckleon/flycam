// Column-major 3x3 and 4x4 matrices in Double precision.
// Storage and serialisation order match simd_float4x4: `columns.0` ... `columns.3`.

import Foundation

public struct Mat3: Equatable, Sendable {
    /// Columns c0, c1, c2.
    public var columns: (Vec3, Vec3, Vec3)

    public init(columns c0: Vec3, _ c1: Vec3, _ c2: Vec3) {
        columns = (c0, c1, c2)
    }

    /// Rows given as three row vectors.
    public init(rows r0: Vec3, _ r1: Vec3, _ r2: Vec3) {
        columns = (Vec3(r0.x, r1.x, r2.x), Vec3(r0.y, r1.y, r2.y), Vec3(r0.z, r1.z, r2.z))
    }

    public static let identity = Mat3(columns: .unitX, .unitY, .unitZ)

    public static func == (a: Mat3, b: Mat3) -> Bool {
        a.columns.0 == b.columns.0 && a.columns.1 == b.columns.1 && a.columns.2 == b.columns.2
    }

    public func column(_ c: Int) -> Vec3 {
        switch c {
        case 0: return columns.0
        case 1: return columns.1
        case 2: return columns.2
        default: preconditionFailure("Mat3 column out of range")
        }
    }

    /// Element at (row, column).
    public subscript(_ r: Int, _ c: Int) -> Double {
        let col = column(c)
        switch r {
        case 0: return col.x
        case 1: return col.y
        case 2: return col.z
        default: preconditionFailure("Mat3 row out of range")
        }
    }

    public var transpose: Mat3 {
        Mat3(rows: columns.0, columns.1, columns.2)
    }

    public var determinant: Double {
        columns.0.dot(columns.1.cross(columns.2))
    }

    public static func * (m: Mat3, v: Vec3) -> Vec3 {
        m.columns.0 * v.x + m.columns.1 * v.y + m.columns.2 * v.z
    }

    public static func * (a: Mat3, b: Mat3) -> Mat3 {
        Mat3(columns: a * b.columns.0, a * b.columns.1, a * b.columns.2)
    }
}

public struct Mat4: Equatable, Sendable {
    /// Columns c0 ... c3.
    public var columns: (Vec4, Vec4, Vec4, Vec4)

    public init(columns c0: Vec4, _ c1: Vec4, _ c2: Vec4, _ c3: Vec4) {
        columns = (c0, c1, c2, c3)
    }

    /// 16 values in column-major order (the serialisation order of `c2w`).
    public init(columnMajor v: [Double]) {
        precondition(v.count == 16, "Mat4 needs 16 values")
        columns = (
            Vec4(v[0], v[1], v[2], v[3]),
            Vec4(v[4], v[5], v[6], v[7]),
            Vec4(v[8], v[9], v[10], v[11]),
            Vec4(v[12], v[13], v[14], v[15])
        )
    }

    /// Four rows of four values (Nerfstudio `transform_matrix` order).
    public init(rows: [[Double]]) {
        precondition(rows.count == 4 && rows.allSatisfy { $0.count == 4 }, "Mat4 needs 4x4 rows")
        self.init(columnMajor: (0..<4).flatMap { c in (0..<4).map { r in rows[r][c] } })
    }

    /// Rigid transform from rotation and translation.
    public init(rotation r: Mat3, translation t: Vec3) {
        columns = (
            Vec4(r.columns.0, 0),
            Vec4(r.columns.1, 0),
            Vec4(r.columns.2, 0),
            Vec4(t, 1)
        )
    }

    public static let identity = Mat4(columnMajor: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])

    public static func == (a: Mat4, b: Mat4) -> Bool {
        a.columnMajor == b.columnMajor
    }

    public func column(_ c: Int) -> Vec4 {
        switch c {
        case 0: return columns.0
        case 1: return columns.1
        case 2: return columns.2
        case 3: return columns.3
        default: preconditionFailure("Mat4 column out of range")
        }
    }

    /// Element at (row, column).
    public subscript(_ r: Int, _ c: Int) -> Double {
        column(c)[r]
    }

    public var columnMajor: [Double] {
        columns.0.array + columns.1.array + columns.2.array + columns.3.array
    }

    public var rows: [[Double]] {
        (0..<4).map { r in (0..<4).map { c in self[r, c] } }
    }

    public var transpose: Mat4 {
        Mat4(columnMajor: rows.flatMap { $0 })
    }

    public var rotation: Mat3 {
        Mat3(columns: columns.0.xyz, columns.1.xyz, columns.2.xyz)
    }

    public var translation: Vec3 { columns.3.xyz }

    public static func * (m: Mat4, v: Vec4) -> Vec4 {
        m.columns.0 * v.x + m.columns.1 * v.y + m.columns.2 * v.z + m.columns.3 * v.w
    }

    public static func * (a: Mat4, b: Mat4) -> Mat4 {
        Mat4(columns: a * b.columns.0, a * b.columns.1, a * b.columns.2, a * b.columns.3)
    }

    /// Transform a point (w = 1).
    public func transformPoint(_ p: Vec3) -> Vec3 {
        (self * Vec4(p, 1)).xyz
    }

    /// Transform a direction (w = 0).
    public func transformDirection(_ d: Vec3) -> Vec3 {
        (self * Vec4(d, 0)).xyz
    }

    /// Inverse of a rigid transform (rotation + translation). Exact for rigid inputs.
    public var rigidInverse: Mat4 {
        let rt = rotation.transpose
        return Mat4(rotation: rt, translation: -(rt * translation))
    }

    /// General inverse by cofactor expansion. Returns nil for singular matrices.
    public var inverse: Mat4? {
        let m = columnMajor
        var inv = [Double](repeating: 0, count: 16)
        inv[0] = m[5] * m[10] * m[15] - m[5] * m[11] * m[14] - m[9] * m[6] * m[15] + m[9] * m[7] * m[14] + m[13] * m[6] * m[11] - m[13] * m[7] * m[10]
        inv[4] = -m[4] * m[10] * m[15] + m[4] * m[11] * m[14] + m[8] * m[6] * m[15] - m[8] * m[7] * m[14] - m[12] * m[6] * m[11] + m[12] * m[7] * m[10]
        inv[8] = m[4] * m[9] * m[15] - m[4] * m[11] * m[13] - m[8] * m[5] * m[15] + m[8] * m[7] * m[13] + m[12] * m[5] * m[11] - m[12] * m[7] * m[9]
        inv[12] = -m[4] * m[9] * m[14] + m[4] * m[10] * m[13] + m[8] * m[5] * m[14] - m[8] * m[6] * m[13] - m[12] * m[5] * m[10] + m[12] * m[6] * m[9]
        inv[1] = -m[1] * m[10] * m[15] + m[1] * m[11] * m[14] + m[9] * m[2] * m[15] - m[9] * m[3] * m[14] - m[13] * m[2] * m[11] + m[13] * m[3] * m[10]
        inv[5] = m[0] * m[10] * m[15] - m[0] * m[11] * m[14] - m[8] * m[2] * m[15] + m[8] * m[3] * m[14] + m[12] * m[2] * m[11] - m[12] * m[3] * m[10]
        inv[9] = -m[0] * m[9] * m[15] + m[0] * m[11] * m[13] + m[8] * m[1] * m[15] - m[8] * m[3] * m[13] - m[12] * m[1] * m[11] + m[12] * m[3] * m[9]
        inv[13] = m[0] * m[9] * m[14] - m[0] * m[10] * m[13] - m[8] * m[1] * m[14] + m[8] * m[2] * m[13] + m[12] * m[1] * m[10] - m[12] * m[2] * m[9]
        inv[2] = m[1] * m[6] * m[15] - m[1] * m[7] * m[14] - m[5] * m[2] * m[15] + m[5] * m[3] * m[14] + m[13] * m[2] * m[7] - m[13] * m[3] * m[6]
        inv[6] = -m[0] * m[6] * m[15] + m[0] * m[7] * m[14] + m[4] * m[2] * m[15] - m[4] * m[3] * m[14] - m[12] * m[2] * m[7] + m[12] * m[3] * m[6]
        inv[10] = m[0] * m[5] * m[15] - m[0] * m[7] * m[13] - m[4] * m[1] * m[15] + m[4] * m[3] * m[13] + m[12] * m[1] * m[7] - m[12] * m[3] * m[5]
        inv[14] = -m[0] * m[5] * m[14] + m[0] * m[6] * m[13] + m[4] * m[1] * m[14] - m[4] * m[2] * m[13] - m[12] * m[1] * m[6] + m[12] * m[2] * m[5]
        inv[3] = -m[1] * m[6] * m[11] + m[1] * m[7] * m[10] + m[5] * m[2] * m[11] - m[5] * m[3] * m[10] - m[9] * m[2] * m[7] + m[9] * m[3] * m[6]
        inv[7] = m[0] * m[6] * m[11] - m[0] * m[7] * m[10] - m[4] * m[2] * m[11] + m[4] * m[3] * m[10] + m[8] * m[2] * m[7] - m[8] * m[3] * m[6]
        inv[11] = -m[0] * m[5] * m[11] + m[0] * m[7] * m[9] + m[4] * m[1] * m[11] - m[4] * m[3] * m[9] - m[8] * m[1] * m[7] + m[8] * m[3] * m[5]
        inv[15] = m[0] * m[5] * m[10] - m[0] * m[6] * m[9] - m[4] * m[1] * m[10] + m[4] * m[2] * m[9] + m[8] * m[1] * m[6] - m[8] * m[2] * m[5]
        let det = m[0] * inv[0] + m[1] * inv[4] + m[2] * inv[8] + m[3] * inv[12]
        if det == 0 || !det.isFinite { return nil }
        return Mat4(columnMajor: inv.map { $0 / det })
    }

    /// Largest deviation of a rigid transform from orthonormality / a proper last row.
    /// 0 for an exact rigid transform. Used by validators.
    public var rigidityError: Double {
        let r = rotation
        let rtr = r.transpose * r
        var err = 0.0
        for i in 0..<3 {
            for j in 0..<3 {
                err = max(err, abs(rtr[i, j] - (i == j ? 1 : 0)))
            }
        }
        err = max(err, abs(r.determinant - 1))
        err = max(err, abs(self[3, 0]), abs(self[3, 1]), abs(self[3, 2]), abs(self[3, 3] - 1))
        return err
    }
}
