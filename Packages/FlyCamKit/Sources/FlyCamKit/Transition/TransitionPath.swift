// Virtual camera path between two real cameras (plan.md Phase 4).
// Tools/flycam_tools/transition.py implements the same algorithm; keep them in step
// (Tools/testdata/golden/*/transition.json checks that they agree).

import Foundation

/// Smootherstep easing 6u^5 - 15u^4 + 10u^3 on [0, 1]. Exact at 0 and 1.
public func smootherstep(_ u: Double) -> Double {
    let x = min(1, max(0, u))
    return x * x * x * (x * (x * 6 - 15) + 10)
}

public struct TransitionConfig: Equatable, Sendable, Codable {
    /// Duration T in seconds.
    public var duration: Double = 1.2
    /// Fraction of T used for each cross-fade between video and render.
    public var fadeFraction: Double = 0.15
    /// Minimum height of the virtual camera above the floor, metres.
    public var floorClearance: Double = 0.3
    /// Interest points further than this from either camera are rejected, metres.
    public var maxInterestDistance: Double = 20
    /// Optical axes closer than this angle (radians) count as parallel.
    public var parallelAngle: Double = 2 * Double.pi / 180
    /// Fallback depth along each optical axis when the axes give no usable interest point, metres.
    public var medianSceneDepth: Double = 3

    public init() {}

    public init(duration: Double = 1.2, fadeFraction: Double = 0.15, floorClearance: Double = 0.3,
                maxInterestDistance: Double = 20, parallelAngle: Double = 2 * Double.pi / 180,
                medianSceneDepth: Double = 3) {
        self.duration = duration
        self.fadeFraction = fadeFraction
        self.floorClearance = floorClearance
        self.maxInterestDistance = maxInterestDistance
        self.parallelAngle = parallelAngle
        self.medianSceneDepth = medianSceneDepth
    }
}

public enum InterestPointMethod: String, Sendable, Codable {
    /// Midpoint of the shortest segment between the two optical axes.
    case axesMidpoint = "axes_midpoint"
    /// Axes parallel, point behind a camera or too far away: midpoint of the two points
    /// at `medianSceneDepth` along each optical axis.
    case medianDepth = "median_depth"
}

/// Weights for the final mix. They sum to 1.
public struct BlendWeights: Equatable, Sendable {
    public var videoA: Double
    public var render: Double
    public var videoB: Double
}

public struct TransitionPath: Sendable {
    public let from: PinholeCamera
    public let to: PinholeCamera
    public let floorY: Double?
    public let config: TransitionConfig
    public let interestPoint: Vec3
    public let interestMethod: InterestPointMethod

    private let qA: Quat
    private let qB: Quat
    private let distA: Double
    private let distB: Double
    private let dirA: Vec3
    private let dirB: Vec3
    private let intrinsicsB: Intrinsics

    /// - Parameters:
    ///   - from: camera A (current program camera) at the start of the flight.
    ///   - to: camera B (preview camera). For a moving target, build a new path every frame
    ///     with B's latest pose and keep the same elapsed time (plan.md Phase 8).
    ///   - floorY: floor height from the scan, nil to disable the floor guard.
    public init(from a: PinholeCamera, to b: PinholeCamera, floorY: Double?, config: TransitionConfig = TransitionConfig()) {
        from = a
        to = b
        self.floorY = floorY
        self.config = config
        let (p, method) = Self.interestPoint(a: a, b: b, config: config)
        interestPoint = p
        interestMethod = method
        qA = Quat(a.c2w.rotation)
        qB = Quat(b.c2w.rotation)
        let rA = a.position - p
        let rB = b.position - p
        distA = rA.length
        distB = rB.length
        dirA = distA > 0 ? rA / distA : a.forward * -1
        dirB = distB > 0 ? rB / distB : b.forward * -1
        if b.intrinsics.width == a.intrinsics.width && b.intrinsics.height == a.intrinsics.height {
            intrinsicsB = b.intrinsics
        } else {
            intrinsicsB = b.intrinsics.scaled(toWidth: a.intrinsics.width, height: a.intrinsics.height)
        }
    }

    public static func interestPoint(a: PinholeCamera, b: PinholeCamera, config: TransitionConfig) -> (Vec3, InterestPointMethod) {
        let pA = a.position, dA = a.forward
        let pB = b.position, dB = b.forward
        let fallback = ((pA + dA * config.medianSceneDepth) + (pB + dB * config.medianSceneDepth)) * 0.5
        let sinAngle = dA.cross(dB).length
        if sinAngle < sin(config.parallelAngle) {
            return (fallback, .medianDepth)
        }
        let w0 = pA - pB
        let bb = dA.dot(dB)
        let d = dA.dot(w0)
        let e = dB.dot(w0)
        let denom = 1 - bb * bb
        let t = (bb * e - d) / denom
        let u = (e - bb * d) / denom
        if !(t > 0 && u > 0) {
            return (fallback, .medianDepth)
        }
        let p = ((pA + dA * t) + (pB + dB * u)) * 0.5
        if p.distance(to: pA) > config.maxInterestDistance || p.distance(to: pB) > config.maxInterestDistance {
            return (fallback, .medianDepth)
        }
        return (p, .axesMidpoint)
    }

    /// Eased progress s for elapsed time t in seconds.
    public func progress(atTime t: Double) -> Double {
        smootherstep(t / config.duration)
    }

    /// Virtual camera for eased progress s in [0, 1]. Exactly A at s = 0 and exactly B at s = 1.
    public func camera(atProgress sIn: Double) -> PinholeCamera {
        let s = min(1, max(0, sIn))
        if s == 0 { return from }
        if s == 1 { return PinholeCamera(intrinsics: intrinsicsB, c2w: to.c2w) }

        // Position: orbit around the interest point.
        let dist = (1 - s) * distA + s * distB
        let dir = slerpDirection(dirA, dirB, s)
        var pos = interestPoint + dir * dist

        // Floor guard. The lower bound never exceeds the straight-line height between the
        // two cameras, so the endpoints stay exact even for phones mounted below the clearance.
        if let floorY {
            let minY = min(floorY + config.floorClearance, (1 - s) * from.position.y + s * to.position.y)
            pos.y = max(pos.y, minY)
        }

        let q = Quat.slerp(qA, qB, s)

        let kA = from.intrinsics, kB = intrinsicsB
        let k = Intrinsics(
            fx: exp((1 - s) * log(kA.fx) + s * log(kB.fx)),
            fy: exp((1 - s) * log(kA.fy) + s * log(kB.fy)),
            cx: (1 - s) * kA.cx + s * kB.cx,
            cy: (1 - s) * kA.cy + s * kB.cy,
            width: kA.width, height: kA.height)

        return PinholeCamera(intrinsics: k, c2w: Mat4(rotation: q.matrix, translation: pos))
    }

    public func camera(atTime t: Double) -> PinholeCamera {
        camera(atProgress: progress(atTime: t))
    }

    /// Video/render mix for elapsed time t (linear fades over `fadeFraction * duration`).
    public func blendWeights(atTime t: Double) -> BlendWeights {
        Self.blendWeights(timeFraction: t / config.duration, fadeFraction: config.fadeFraction)
    }

    public static func blendWeights(timeFraction uIn: Double, fadeFraction f: Double) -> BlendWeights {
        let u = min(1, max(0, uIn))
        // Written as 1 - distance/f so that the weights are exactly 1 at u = 0 and u = 1.
        let a = max(0, 1 - u / f)
        let b = max(0, 1 - (1 - u) / f)
        return BlendWeights(videoA: a, render: 1 - a - b, videoB: b)
    }

    /// Weights of the people reconstructed from A and from B (plan.md Phases 6 and 7).
    public static func peopleWeights(progress s: Double) -> (a: Double, b: Double) {
        let c = min(1, max(0, s))
        return (1 - c, c)
    }
}
