// Preview/program workflow and the running transition (plan.md Phase 4).
// The path itself (interest point, orbit, slerp, log-focal, floor guard, easing, blend) is FlyCamKit's
// TransitionPath; this type decides when a flight runs and between which cameras.

import Foundation
import FlyCamKit

public struct ActiveTransition: Sendable, Equatable {
    public var from: UInt16
    public var to: UInt16
    /// Program time of the take.
    public var startTime: Double
    public var duration: Double
}

/// What the program shows at one instant.
public enum ProgramState: Equatable {
    /// Untouched live video of one camera (outside a transition).
    case video(UInt16)
    /// In flight. `elapsed` in [0, duration].
    case transition(ActiveTransition, elapsed: Double)
}

public final class TransitionController {
    public private(set) var program: UInt16
    public private(set) var preview: UInt16?
    public var config: TransitionConfig
    public private(set) var active: ActiveTransition?

    public init(program: UInt16, preview: UInt16? = nil, config: TransitionConfig = TransitionConfig()) {
        self.program = program
        self.preview = preview
        self.config = config
    }

    /// Operator selects the next camera. Ignored while a transition runs or for the program camera.
    public func selectPreview(_ id: UInt16) {
        guard active == nil, id != program else { return }
        preview = id
    }

    /// Operator triggers the take: the flight from program to preview starts at `time`.
    /// Returns false when there is no preview or a flight is already running.
    @discardableResult
    public func take(at time: Double) -> Bool {
        guard active == nil, let p = preview else { return false }
        active = ActiveTransition(from: program, to: p, startTime: time, duration: config.duration)
        return true
    }

    /// Program state at `time`. Finishes the transition once its duration has passed:
    /// B becomes program and A becomes preview (vision mixer convention).
    public func state(at time: Double) -> ProgramState {
        if let a = active {
            var elapsed = time - a.startTime
            // Snap timestamps within 1 us of the ends so rounding cannot turn the landing frame into a mix.
            if abs(elapsed) < 1e-6 { elapsed = 0 }
            if abs(elapsed - a.duration) < 1e-6 { elapsed = a.duration }
            if elapsed < 0 { return .video(a.from) }
            if elapsed < a.duration { return .transition(a, elapsed: elapsed) }
            program = a.to
            preview = a.from
            active = nil
            return .video(program)
        }
        return .video(program)
    }

    /// Path between the current poses of the two cameras. Rebuilt every frame from the latest poses, so a
    /// moving target needs no change here (plan.md Phase 8); for tripods it is the same path every frame.
    public func path(from a: PinholeCamera, to b: PinholeCamera, floorY: Double?) -> TransitionPath {
        TransitionPath(from: a, to: b, floorY: floorY, config: config)
    }
}

/// Per-frame record of a rendered program (written next to the MP4, same fields as Tools/prototype).
public struct ProgramFrameLog: Codable, Equatable, Sendable {
    public var frame: Int
    public var time: Double
    /// Elapsed / duration, nil outside the flight.
    public var u: Double?
    /// Eased progress, nil outside the flight.
    public var s: Double?
    public var videoA: Double
    public var render: Double
    public var videoB: Double
    public var programCamera: Int
    public var sourceA: Int?
    public var sourceB: Int?
    /// Virtual camera c2w (column-major), nil outside the flight.
    public var c2w: [Double]?
    public var fx: Double?
    public var fy: Double?
    public var cx: Double?
    public var cy: Double?
    public var interestPoint: [Double]?
    public var interestMethod: String?

    enum CodingKeys: String, CodingKey {
        case frame, time, u, s, videoA = "video_a", render, videoB = "video_b", programCamera = "program_camera"
        case sourceA = "source_frame_a", sourceB = "source_frame_b", c2w, fx, fy, cx, cy
        case interestPoint = "interest_point", interestMethod = "interest_method"
    }
}
