// Offline take from session A to session B, written to an MP4 without a window
// (`director-cli render-transition`). Timeline: `pre` seconds of A, the flight (duration T), `post` seconds of B.

import Foundation
import AVFoundation
import CoreVideo
import FlyCamKit

public struct OfflineTransitionOptions: Sendable {
    /// Seconds of program video before the take.
    public var pre: Double = 0.5
    /// Seconds of program video after landing.
    public var post: Double = 0.5
    /// Output frame rate; nil = session A's frame rate.
    public var fps: Double?
    public var config = TransitionConfig()
    /// Start of the output on the common timeline, nil = the first time both sessions have frames.
    public var startTime: Double?
    public var bitRate: Int?
    /// Encoder quality in [0, 1] (used when bitRate is nil). The offline output is a master, so maximum quality.
    public var quality: Double = 1.0
    public var codec: AVVideoCodecType = .hevc

    public init() {}
}

public struct OfflineTransitionResult: Sendable {
    public var output: URL
    public var log: [ProgramFrameLog]
    public var takeFrame: Int
    public var landingFrame: Int
    public var timeBase: RecordedSource.TimeBase
}

public enum OfflineTransition {
    /// Renders the take and writes `out` (MP4) and `out` + ".json" (per-frame log).
    public static func render(sessionA: URL, sessionB: URL, splat: URL, out: URL,
                              options: OfflineTransitionOptions = OfflineTransitionOptions(),
                              context: MetalContext? = nil,
                              progress: ((Int, Int) -> Void)? = nil) async throws -> OfflineTransitionResult {
        let ctx = try context ?? MetalContext.shared()
        // Common timeline: the Mac clock if both sessions were recorded with a clock offset, otherwise
        // seconds since each session's first frame.
        let probeA = try SessionIO.readMeta(sessionA), probeB = try SessionIO.readMeta(sessionB)
        let tb: RecordedSource.TimeBase = (probeA.clockOffset != nil && probeB.clockOffset != nil) ? .macClock : .sessionStart
        let a = try await RecordedSource(folder: sessionA, cameraID: 0, timeBase: tb)
        let b = try await RecordedSource(folder: sessionB, cameraID: 1, timeBase: tb)
        guard let ra = a.availableTimes, let rb = b.availableTimes else {
            throw RenderError.renderSkipped("empty session")
        }
        let scene = try await SplatScene.load(url: splat, context: ctx)
        let fps = options.fps ?? a.fps
        let t0 = options.startTime ?? max(ra.lowerBound, rb.lowerBound)
        let T = options.config.duration
        let takeFrame = Int((options.pre * fps).rounded())
        let flightFrames = Int((T * fps).rounded())
        let landingFrame = takeFrame + flightFrames
        let total = landingFrame + Int((options.post * fps).rounded()) + 1
        let takeTime = t0 + Double(takeFrame) / fps
        let end = t0 + Double(total - 1) / fps
        if end > min(ra.upperBound, rb.upperBound) + 0.5 / fps {
            FileHandle.standardError.write("warning: output runs past the end of a session; the last frame is held\n".data(using: .utf8)!)
        }

        let width = a.width, height = a.height
        let program = try ProgramRenderer(context: ctx, scene: scene, width: width, height: height,
                                          settled: true, floorY: a.floorY ?? b.floorY)
        program.compositor.background = SIMD4(0.05, 0.05, 0.06, 1)
        let controller = TransitionController(program: 0, preview: 1, config: options.config)
        let writer = try SessionVideoWriter(url: out, width: width, height: height, fps: fps,
                                            bitRate: options.bitRate, quality: options.bitRate == nil ? options.quality : nil,
                                            fileType: .mp4, codec: options.codec)
        let sources: [UInt16: FrameSource] = [0: a, 1: b]
        var logs = [ProgramFrameLog]()
        for k in 0..<total {
            let t = t0 + Double(k) / fps
            if k == takeFrame { controller.take(at: takeTime) }
            // The landing frame is exactly at elapsed = T (snapped by the controller).
            let state = controller.state(at: k == landingFrame ? takeTime + T : t)
            let pb = try makeBGRAPixelBuffer(width: width, height: height)
            let tex = try ctx.texture(for: pb)
            var log = try program.render(state: state, time: t, sources: sources, controller: controller,
                                         output: CVMetalTextureGetTexture(tex)!, frameNumber: k)
            if k >= landingFrame {
                // After the take the program shows video B (the log's "video_b" weight).
                log.videoA = 0
                log.videoB = 1
                if k == landingFrame {
                    // Landing frame: flight finished, recorded as u = s = 1.
                    log.u = 1
                    log.s = 1
                }
            }
            logs.append(log)
            try writer.append(pb, time: Double(k) / fps)
            progress?(k + 1, total)
        }
        try await writer.finish()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(logs).write(to: URL(fileURLWithPath: out.path + ".json"))
        return OfflineTransitionResult(output: out, log: logs, takeFrame: takeFrame, landingFrame: landingFrame, timeBase: tb)
    }
}
