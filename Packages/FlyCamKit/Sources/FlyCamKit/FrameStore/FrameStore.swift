// Per-camera ring buffers keyed by Mac time, with nearest-frame pairing (plan.md Phase 5,
// docs/protocol.md section 4). Not thread-safe: own it from one actor or queue.

import Foundation

public struct StoredFrame<Payload: Sendable>: Sendable {
    /// Capture time converted to the Mac clock.
    public var macTime: Double
    public var frameIndex: UInt32
    public var payload: Payload
}

/// Ring buffer for one camera. Frames are kept sorted by `macTime`.
public struct FrameRing<Payload: Sendable>: Sendable {
    public let capacitySeconds: Double
    public private(set) var frames: [StoredFrame<Payload>] = []

    public init(capacitySeconds: Double = 0.5) {
        precondition(capacitySeconds > 0, "capacity must be positive")
        self.capacitySeconds = capacitySeconds
    }

    public var newestTime: Double? { frames.last?.macTime }
    public var oldestTime: Double? { frames.first?.macTime }
    public var count: Int { frames.count }

    public mutating func insert(_ f: StoredFrame<Payload>) {
        // Usually appended at the end; out-of-order frames are inserted in place.
        var i = frames.count
        while i > 0 && frames[i - 1].macTime > f.macTime { i -= 1 }
        frames.insert(f, at: i)
        if let newest = newestTime {
            let cutoff = newest - capacitySeconds
            let drop = frames.prefix { $0.macTime < cutoff }.count
            if drop > 0 { frames.removeFirst(drop) }
        }
    }

    /// The frame nearest to `t`. Ties go to the earlier frame.
    public func nearest(to t: Double) -> StoredFrame<Payload>? {
        guard !frames.isEmpty else { return nil }
        // Binary search for the first frame with macTime >= t.
        var lo = 0, hi = frames.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if frames[mid].macTime < t { lo = mid + 1 } else { hi = mid }
        }
        if lo == 0 { return frames[0] }
        if lo == frames.count { return frames[frames.count - 1] }
        let before = frames[lo - 1], after = frames[lo]
        return (t - before.macTime) <= (after.macTime - t) ? before : after
    }
}

public struct PairedFrames<Payload: Sendable>: Sendable {
    public var renderTime: Double
    /// Camera id to the selected frame.
    public var frames: [UInt16: StoredFrame<Payload>]

    /// max(t_mac) - min(t_mac) over the selected frames; 0 for fewer than two cameras.
    public var residual: Double {
        let ts = frames.values.map(\.macTime)
        guard let lo = ts.min(), let hi = ts.max() else { return 0 }
        return hi - lo
    }

    /// Selected frame time minus render time, per camera.
    public func offsets() -> [UInt16: Double] {
        frames.mapValues { $0.macTime - renderTime }
    }
}

public struct FrameStore<Payload: Sendable>: Sendable {
    public let capacitySeconds: Double
    public var playoutDelay: Double
    public private(set) var rings: [UInt16: FrameRing<Payload>] = [:]

    public init(capacitySeconds: Double = 0.5, playoutDelay: Double = 0.150) {
        self.capacitySeconds = capacitySeconds
        self.playoutDelay = playoutDelay
    }

    public var cameraIDs: [UInt16] { rings.keys.sorted() }

    public mutating func insert(camera: UInt16, macTime: Double, frameIndex: UInt32, payload: Payload) {
        rings[camera, default: FrameRing(capacitySeconds: capacitySeconds)]
            .insert(StoredFrame(macTime: macTime, frameIndex: frameIndex, payload: payload))
    }

    public func renderTime(now: Double) -> Double { now - playoutDelay }

    /// Nearest frame of every camera (or of `cameras`) to `renderTime`.
    public func pair(at renderTime: Double, cameras: [UInt16]? = nil) -> PairedFrames<Payload> {
        var out = [UInt16: StoredFrame<Payload>]()
        for id in cameras ?? cameraIDs {
            if let f = rings[id]?.nearest(to: renderTime) { out[id] = f }
        }
        return PairedFrames(renderTime: renderTime, frames: out)
    }
}
