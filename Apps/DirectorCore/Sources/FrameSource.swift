// FrameSource (plan.md section 4): everything downstream of the sources only sees this protocol.
// Implementations: RecordedSource (session folders) and LiveSource (network).

import Foundation
import CoreVideo
import FlyCamKit

/// One video frame with everything needed to place it in the world frame.
public struct SourceFrame: @unchecked Sendable {
    public var cameraID: UInt16
    /// Frame index within the source (line of frames.jsonl, or frame_index of the media packet).
    public var index: Int
    /// Time on the source's timeline (`FrameSource.time(phoneTime:)`), seconds.
    public var time: Double
    /// Capture time on the phone clock, seconds.
    public var phoneTime: Double
    /// Pose and intrinsics used for rendering (a pose override replaces the per-frame pose).
    public var camera: PinholeCamera
    public var tracking: TrackingState
    /// 32BGRA, Metal compatible.
    public var pixelBuffer: CVPixelBuffer

    public init(cameraID: UInt16, index: Int, time: Double, phoneTime: Double, camera: PinholeCamera,
                tracking: TrackingState, pixelBuffer: CVPixelBuffer) {
        self.cameraID = cameraID
        self.index = index
        self.time = time
        self.phoneTime = phoneTime
        self.camera = camera
        self.tracking = tracking
        self.pixelBuffer = pixelBuffer
    }
}

public protocol FrameSource: AnyObject {
    var cameraID: UInt16 { get }
    var name: String { get }
    /// Frame size in pixels.
    var width: Int { get }
    var height: Int { get }
    var fps: Double { get }
    /// Floor height of the scan the source is registered to, when known.
    var floorY: Double? { get }
    /// Times of the frames currently available (nil while empty).
    var availableTimes: ClosedRange<Double>? { get }
    /// The frame whose time is nearest to `time` (ties: the earlier frame), nil if there is none.
    func frame(nearest time: Double) throws -> SourceFrame?
}

/// Index of the value in sorted `times` nearest to `t`. Ties go to the earlier one (docs/protocol.md 4).
func nearestIndex(_ times: [Double], _ t: Double) -> Int? {
    guard !times.isEmpty else { return nil }
    var lo = 0, hi = times.count
    while lo < hi {
        let mid = (lo + hi) / 2
        if times[mid] < t { lo = mid + 1 } else { hi = mid }
    }
    if lo == 0 { return 0 }
    if lo == times.count { return times.count - 1 }
    return (t - times[lo - 1]) <= (times[lo] - t) ? lo - 1 : lo
}
