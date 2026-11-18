// Conversions between FlyCamKit (Double, Foundation only) and simd (Float) for Metal.

import simd
import FlyCamKit

extension Mat4 {
    /// Column-major, like FlyCamKit and simd.
    public var simdFloat: simd_float4x4 {
        let v = columnMajor.map(Float.init)
        return simd_float4x4(columns: (SIMD4(v[0], v[1], v[2], v[3]), SIMD4(v[4], v[5], v[6], v[7]),
                                       SIMD4(v[8], v[9], v[10], v[11]), SIMD4(v[12], v[13], v[14], v[15])))
    }

    public init(_ m: simd_float4x4) {
        var v = [Double]()
        for c in 0..<4 { for r in 0..<4 { v.append(Double(m[c][r])) } }
        self.init(columnMajor: v)
    }
}

extension Vec3 {
    public var simdFloat: SIMD3<Float> { SIMD3(Float(x), Float(y), Float(z)) }
    public init(_ v: SIMD3<Float>) { self.init(Double(v.x), Double(v.y), Double(v.z)) }
}

/// Near and far planes used for every splat render. Depth readback is metric, so these only
/// bound what is drawn.
public struct DepthRange: Equatable, Sendable {
    public var near: Double
    public var far: Double
    public init(near: Double = 0.05, far: Double = 100) {
        self.near = near
        self.far = far
    }
}
