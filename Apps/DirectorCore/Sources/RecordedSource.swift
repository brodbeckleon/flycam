// RecordedSource: a session folder (docs/protocol.md 2) served through FrameSource.

import Foundation
import CoreVideo
import FlyCamKit

public enum RecordedSourceError: Error, CustomStringConvertible {
    case invalidSession(URL, [String])
    case frameCountMismatch(video: Int, lines: Int)
    case noVideo(URL)

    public var description: String {
        switch self {
        case .invalidSession(let u, let p): return "invalid session \(u.lastPathComponent): \(p.prefix(5).joined(separator: "; "))"
        case .frameCountMismatch(let v, let l): return "video has \(v) frames, frames.jsonl has \(l) lines"
        case .noVideo(let u): return "no video.mov in \(u.path)"
        }
    }
}

public final class RecordedSource: FrameSource {
    public enum TimeBase: Equatable, Sendable {
        /// `t + meta.clock_offset`: the Mac clock of the recording (sessions recorded together share it).
        case macClock
        /// Phone clock as recorded.
        case phoneClock
        /// Seconds since the first frame.
        case sessionStart
    }

    public let folder: URL
    public let cameraID: UInt16
    public let meta: SessionMeta
    public let records: [FrameRecord]
    public let poseOverride: PoseOverride?
    public let timeBase: TimeBase
    public let video: VideoFileReader
    /// Frame times on `timeBase`, one per frame.
    public let times: [Double]

    public var name: String { folder.lastPathComponent }
    public var width: Int { records.first?.w ?? video.width }
    public var height: Int { records.first?.h ?? video.height }
    public var fps: Double { meta.videoFormat.fps }
    public var floorY: Double? { meta.floorY }
    public var frameCount: Int { records.count }
    public var availableTimes: ClosedRange<Double>? {
        guard let a = times.first, let b = times.last else { return nil }
        return a...b
    }

    /// - Parameters:
    ///   - timeBase: default `.macClock` when meta.json has a clock offset, else `.sessionStart`.
    ///   - usePoseOverride: use pose_override.json (fixed phones, plan Phase 3) when present.
    public init(folder: URL, cameraID: UInt16? = nil, timeBase: TimeBase? = nil, usePoseOverride: Bool = true) async throws {
        self.folder = folder
        meta = try SessionIO.readMeta(folder)
        let recs = try SessionIO.readFrames(folder)
        let validation = SessionValidation.validate(recs)
        guard validation.isValid else { throw RecordedSourceError.invalidSession(folder, validation.problems) }
        records = recs
        poseOverride = usePoseOverride ? try SessionIO.readPoseOverride(folder) : nil
        self.cameraID = cameraID ?? UInt16(clamping: meta.cameraID ?? 0)
        let tb = timeBase ?? (meta.clockOffset != nil ? .macClock : .sessionStart)
        if tb == .macClock && meta.clockOffset == nil {
            throw RecordedSourceError.invalidSession(folder, ["time base macClock needs clock_offset in meta.json"])
        }
        self.timeBase = tb
        let videoURL = folder.appendingPathComponent("video.mov")
        guard FileManager.default.fileExists(atPath: videoURL.path) else { throw RecordedSourceError.noVideo(folder) }
        video = try await VideoFileReader(url: videoURL)
        guard video.frameCount == recs.count else {
            throw RecordedSourceError.frameCountMismatch(video: video.frameCount, lines: recs.count)
        }
        let t0 = recs.first?.t ?? 0
        let off = meta.clockOffset ?? 0
        times = recs.map { r in
            switch tb {
            case .macClock: return r.t + off
            case .phoneClock: return r.t
            case .sessionStart: return r.t - t0
            }
        }
    }

    /// Time of a phone timestamp on this source's timeline.
    public func time(phoneTime t: Double) -> Double {
        switch timeBase {
        case .macClock: return t + (meta.clockOffset ?? 0)
        case .phoneClock: return t
        case .sessionStart: return t - (records.first?.t ?? 0)
        }
    }

    /// Camera used for frame `i`: per-frame intrinsics, pose from pose_override.json when present.
    public func camera(at i: Int) -> PinholeCamera {
        let r = records[i]
        if let o = poseOverride, o.c2w.count == 16 {
            return PinholeCamera(intrinsics: r.intrinsics, c2w: Mat4(columnMajor: o.c2w))
        }
        return r.camera
    }

    public func frame(at i: Int) throws -> SourceFrame {
        let r = records[i]
        return SourceFrame(cameraID: cameraID, index: i, time: times[i], phoneTime: r.t, camera: camera(at: i),
                           tracking: r.tracking, pixelBuffer: try video.frame(at: i))
    }

    public func frame(nearest time: Double) throws -> SourceFrame? {
        guard let i = nearestIndex(times, time) else { return nil }
        return try frame(at: i)
    }
}
