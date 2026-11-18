// Writer for 3D Gaussian splat PLY files in the layout of the reference 3DGS implementation
// (the format Brush and SuperSplat export and MetalSplatter reads). Used for generated fixtures.

import Foundation

public struct Gaussian: Sendable, Equatable {
    /// World position, metres.
    public var position: SIMD3<Float>
    /// sRGB colour in [0, 1].
    public var color: SIMD3<Float>
    /// Opacity in (0, 1).
    public var opacity: Float
    /// Standard deviations along the local axes, metres.
    public var scale: SIMD3<Float>
    /// Rotation quaternion (w, x, y, z).
    public var rotation: SIMD4<Float>

    public init(position: SIMD3<Float>, color: SIMD3<Float>, opacity: Float = 0.99,
                scale: SIMD3<Float>, rotation: SIMD4<Float> = SIMD4(1, 0, 0, 0)) {
        self.position = position
        self.color = color
        self.opacity = opacity
        self.scale = scale
        self.rotation = rotation
    }

    public init(position: SIMD3<Float>, color: SIMD3<Float>, opacity: Float = 0.99, radius: Float) {
        self.init(position: position, color: color, opacity: opacity, scale: SIMD3(repeating: radius))
    }
}

public enum GaussianPLY {
    static let shC0: Float = 0.28209479177387814

    public static func encode(_ gaussians: [Gaussian]) -> Data {
        let props = ["x", "y", "z", "nx", "ny", "nz", "f_dc_0", "f_dc_1", "f_dc_2", "opacity",
                     "scale_0", "scale_1", "scale_2", "rot_0", "rot_1", "rot_2", "rot_3"]
        var header = "ply\nformat binary_little_endian 1.0\nelement vertex \(gaussians.count)\n"
        for p in props { header += "property float \(p)\n" }
        header += "end_header\n"
        var d = Data(header.utf8)
        var values = [Float]()
        values.reserveCapacity(gaussians.count * props.count)
        for g in gaussians {
            let dc = (g.color - 0.5) / shC0
            let o = min(max(g.opacity, 1e-6), 1 - 1e-6)
            values += [g.position.x, g.position.y, g.position.z, 0, 0, 0, dc.x, dc.y, dc.z, log(o / (1 - o)),
                       log(g.scale.x), log(g.scale.y), log(g.scale.z),
                       g.rotation.x, g.rotation.y, g.rotation.z, g.rotation.w]
        }
        values.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
        return d
    }

    public static func write(_ gaussians: [Gaussian], to url: URL) throws {
        try encode(gaussians).write(to: url)
    }
}
