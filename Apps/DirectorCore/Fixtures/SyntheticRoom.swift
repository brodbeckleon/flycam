// Generated test scene: a room made of flat Gaussians (floor checkerboard, three striped walls, two boxes).
// No downloaded assets anywhere in the tests; everything is built from this.

import Foundation
import simd
import CoreVideo
import FlyCamKit

public struct SyntheticRoom: Sendable {
    /// Floor height in the world frame (ARKit-like: the origin is where the scan started, about 1.3 m above the floor).
    public var floorY: Float = -1.3
    public var halfWidth: Float = 3
    public var depth: Float = 6
    public var height: Float = 2.8
    /// Gaussian spacing on the surfaces, metres.
    public var spacing: Float = 0.04

    public init() {}

    public init(spacing: Float) {
        self.spacing = spacing
    }

    public func gaussians() -> [Gaussian] {
        var g = [Gaussian]()
        let s = spacing
        let r = s * 0.65
        let thin = s * 0.08
        // Room spans x in [-halfWidth, halfWidth], z in [-depth + 2, 2], y in [floorY, floorY + height].
        let z0: Float = 2 - depth, z1: Float = 2
        let y0 = floorY, y1 = floorY + height

        func steps(_ a: Float, _ b: Float) -> [Float] {
            let n = Int(((b - a) / s).rounded(.down))
            return (0...n).map { a + Float($0) * s }
        }

        // Floor: 0.5 m checkerboard.
        for x in steps(-halfWidth, halfWidth) {
            for z in steps(z0, z1) {
                let c = (Int(floor(x / 0.5)) + Int(floor(z / 0.5))) & 1 == 0
                let col: SIMD3<Float> = c ? SIMD3(0.85, 0.82, 0.75) : SIMD3(0.25, 0.3, 0.4)
                g.append(Gaussian(position: SIMD3(x, y0, z), color: col, scale: SIMD3(r, thin, r)))
            }
        }
        // Back wall (z = z0): horizontal colour gradient with vertical stripes.
        for x in steps(-halfWidth, halfWidth) {
            for y in steps(y0, y1) {
                let u = (x + halfWidth) / (2 * halfWidth)
                let stripe: Float = Int(floor(x / 0.3)) & 1 == 0 ? 1 : 0.7
                let col = SIMD3<Float>(0.9 * u + 0.1, 0.5 * stripe, 0.9 * (1 - u) + 0.1) * stripe
                g.append(Gaussian(position: SIMD3(x, y, z0), color: col, scale: SIMD3(r, r, thin)))
            }
        }
        // Side walls (x = -halfWidth, +halfWidth): horizontal bands.
        for (wx, base) in [(-halfWidth, SIMD3<Float>(0.3, 0.7, 0.35)), (halfWidth, SIMD3<Float>(0.75, 0.6, 0.2))] {
            for z in steps(z0, z1) {
                for y in steps(y0, y1) {
                    let band: Float = Int(floor((y - y0) / 0.25)) & 1 == 0 ? 1 : 0.6
                    let tick: Float = Int(floor(z / 1.0)) & 1 == 0 ? 1 : 0.85
                    g.append(Gaussian(position: SIMD3(wx, y, z), color: base * band * tick, scale: SIMD3(thin, r, r)))
                }
            }
        }
        // Two boxes standing on the floor.
        for (centre, size, col) in [(SIMD3<Float>(-0.6, 0, -1.2), SIMD3<Float>(0.6, 0.9, 0.6), SIMD3<Float>(0.8, 0.15, 0.15)),
                                    (SIMD3<Float>(0.9, 0, -2.2), SIMD3<Float>(0.5, 1.4, 0.5), SIMD3<Float>(0.15, 0.6, 0.85))] {
            let lo = SIMD3(centre.x - size.x / 2, y0, centre.z - size.z / 2)
            let hi = SIMD3(centre.x + size.x / 2, y0 + size.y, centre.z + size.z / 2)
            for a in steps(lo.x, hi.x) {
                for b in steps(lo.y, hi.y) {
                    let shade: Float = Int(floor(b / 0.2)) & 1 == 0 ? 1 : 0.75
                    g.append(Gaussian(position: SIMD3(a, b, hi.z), color: col * shade, scale: SIMD3(r, r, thin)))
                    g.append(Gaussian(position: SIMD3(a, b, lo.z), color: col * shade * 0.8, scale: SIMD3(r, r, thin)))
                }
            }
            for c in steps(lo.z, hi.z) {
                for b in steps(lo.y, hi.y) {
                    let shade: Float = Int(floor(b / 0.2)) & 1 == 0 ? 0.9 : 0.65
                    g.append(Gaussian(position: SIMD3(lo.x, b, c), color: col * shade, scale: SIMD3(thin, r, r)))
                    g.append(Gaussian(position: SIMD3(hi.x, b, c), color: col * shade, scale: SIMD3(thin, r, r)))
                }
            }
            for a in steps(lo.x, hi.x) {
                for c in steps(lo.z, hi.z) {
                    g.append(Gaussian(position: SIMD3(a, hi.y, c), color: col * 1.1, scale: SIMD3(r, thin, r)))
                }
            }
        }
        return g
    }

    /// Two tripod cameras looking into the room from different sides, 640 x 360 with off-centre principal points.
    public static func tripodCameras() -> (PinholeCamera, PinholeCamera) {
        let kA = Intrinsics(fx: 520, fy: 520, cx: 322.4, cy: 176.8, width: 640, height: 360)
        let kB = Intrinsics(fx: 470, fy: 470, cx: 317.1, cy: 183.3, width: 640, height: 360)
        let target = Vec3(0, -0.6, -1.6)
        let a = PinholeCamera(intrinsics: kA, c2w: Mat4.lookAt(eye: Vec3(-1.7, 0.1, 1.4), target: target))
        let b = PinholeCamera(intrinsics: kB, c2w: Mat4.lookAt(eye: Vec3(1.9, -0.1, 0.9), target: target))
        return (a, b)
    }
}

/// Writes a frame index as 16 black/white squares into the top-left corner of a BGRA image, so that a decoded
/// frame can be identified after lossy compression.
public enum FrameCode {
    public static let bits = 16
    public static let cell = 10
    public static let origin = (x: 6, y: 6)

    public static func stamp(_ index: Int, into pb: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let stride = CVPixelBufferGetBytesPerRow(pb)
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        for b in 0..<bits {
            let v: UInt8 = (index >> b) & 1 == 1 ? 255 : 0
            for y in 0..<cell {
                for x in 0..<cell {
                    let p = base + (origin.y + y) * stride + (origin.x + b * cell + x) * 4
                    p[0] = v; p[1] = v; p[2] = v; p[3] = 255
                }
            }
        }
    }

    public static func read(_ pb: CVPixelBuffer) -> Int {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let stride = CVPixelBufferGetBytesPerRow(pb)
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        var v = 0
        for b in 0..<bits {
            let p = base + (origin.y + cell / 2) * stride + (origin.x + b * cell + cell / 2) * 4
            let lum = (Int(p[0]) + Int(p[1]) + Int(p[2])) / 3
            if lum > 128 { v |= 1 << b }
        }
        return v
    }
}
