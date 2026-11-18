// Checks a rendered take against its inputs (scope test (c), also `director-cli verify-transition`):
// first/last frames vs. the source videos, and that the middle of the flight shows the splat.

import Foundation
import CoreVideo
import FlyCamKit

public struct TransitionReport: Codable, Sendable {
    public struct FrameCheck: Codable, Sendable {
        public var outputFrame: Int
        public var sourceFrame: Int
        public var psnr: Double
    }
    public var firstVsA: FrameCheck
    public var takeVsA: FrameCheck
    public var landingVsB: FrameCheck
    public var lastVsB: FrameCheck
    public var middleFrame: Int
    public var middleS: Double
    /// Fraction of pixels of the middle frame that differ from the empty background by more than 8 LSB.
    public var middleCoverage: Double
    /// Middle frame vs. a direct splat render from the logged virtual camera.
    public var middleVsSplatRender: Double
    /// Middle frame vs. the video frames (should be clearly lower than vs. the render).
    public var middleVsVideoA: Double
    public var middleVsVideoB: Double

    public var summary: String {
        func f(_ v: Double) -> String { v.isInfinite ? "inf" : String(format: "%.2f", v) }
        return """
        first frame \(firstVsA.outputFrame) vs A frame \(firstVsA.sourceFrame): \(f(firstVsA.psnr)) dB
        take frame \(takeVsA.outputFrame) vs A frame \(takeVsA.sourceFrame): \(f(takeVsA.psnr)) dB
        landing frame \(landingVsB.outputFrame) vs B frame \(landingVsB.sourceFrame): \(f(landingVsB.psnr)) dB
        last frame \(lastVsB.outputFrame) vs B frame \(lastVsB.sourceFrame): \(f(lastVsB.psnr)) dB
        middle frame \(middleFrame) (s = \(String(format: "%.3f", middleS))): coverage \(String(format: "%.3f", middleCoverage)), \
        vs splat render \(f(middleVsSplatRender)) dB, vs video A \(f(middleVsVideoA)) dB, vs video B \(f(middleVsVideoB)) dB
        """
    }

    /// The acceptance thresholds of scope test (c).
    public func failures(minPSNR: Double = 35) -> [String] {
        var out = [String]()
        for (name, c) in [("first", firstVsA), ("take", takeVsA), ("landing", landingVsB), ("last", lastVsB)] where !(c.psnr > minPSNR) {
            out.append("\(name) frame PSNR \(c.psnr) dB <= \(minPSNR) dB")
        }
        if !(middleCoverage > 0.5) { out.append("middle frame coverage \(middleCoverage) <= 0.5 (looks empty)") }
        if !(middleVsSplatRender > 30) { out.append("middle frame vs splat render \(middleVsSplatRender) dB <= 30 dB") }
        if !(middleVsSplatRender > middleVsVideoA + 3 && middleVsSplatRender > middleVsVideoB + 3) {
            out.append("middle frame is not closer to the splat render than to the videos")
        }
        return out
    }
}

public enum TransitionVerification {
    public static func verify(sessionA: URL, sessionB: URL, splat: URL, video: URL,
                              context: MetalContext? = nil) async throws -> TransitionReport {
        let ctx = try context ?? MetalContext.shared()
        let logs = try JSONDecoder().decode([ProgramFrameLog].self, from: Data(contentsOf: URL(fileURLWithPath: video.path + ".json")))
        let out = try await VideoFileReader(url: video)
        guard out.frameCount == logs.count, logs.count > 2 else {
            throw RenderError.renderSkipped("output has \(out.frameCount) frames, log has \(logs.count)")
        }
        let probeA = try SessionIO.readMeta(sessionA), probeB = try SessionIO.readMeta(sessionB)
        let tb: RecordedSource.TimeBase = (probeA.clockOffset != nil && probeB.clockOffset != nil) ? .macClock : .sessionStart
        let a = try await RecordedSource(folder: sessionA, cameraID: 0, timeBase: tb)
        let b = try await RecordedSource(folder: sessionB, cameraID: 1, timeBase: tb)

        func check(_ k: Int, _ src: RecordedSource) throws -> TransitionReport.FrameCheck {
            let f = try src.frame(nearest: logs[k].time)!
            return TransitionReport.FrameCheck(outputFrame: k, sourceFrame: f.index,
                                               psnr: psnr(bgraBytes(of: try out.frame(at: k)), bgraBytes(of: f.pixelBuffer)))
        }
        guard let take = logs.firstIndex(where: { $0.u != nil }),
              let landing = logs.lastIndex(where: { $0.u != nil }) else {
            throw RenderError.renderSkipped("log has no flight")
        }
        let first = try check(0, a)
        let takeC = try check(take, a)
        let landingC = try check(landing, b)
        let last = try check(logs.count - 1, b)

        // Middle: the frame with s nearest 0.5.
        let mid = logs.indices.filter { logs[$0].s != nil }.min(by: { abs(logs[$0].s! - 0.5) < abs(logs[$1].s! - 0.5) })!
        let ml = logs[mid]
        let midBytes = bgraBytes(of: try out.frame(at: mid))
        let cam = PinholeCamera(intrinsics: Intrinsics(fx: ml.fx!, fy: ml.fy!, cx: ml.cx!, cy: ml.cy!, width: a.width, height: a.height),
                                c2w: Mat4(columnMajor: ml.c2w!))
        let scene = try await SplatScene.load(url: splat, context: ctx)
        let targets = try SplatRenderTargets(context: ctx, width: a.width, height: a.height)
        try scene.renderSettled(camera: cam, targets: targets)
        let comp = try Compositor(context: ctx)
        let background = SIMD4<Float>(0.05, 0.05, 0.06, 1)
        comp.background = background
        func mixToBytes(_ render: SplatRenderTargets?) throws -> [UInt8] {
            let pb = try makeBGRAPixelBuffer(width: a.width, height: a.height)
            let tex = try ctx.texture(for: pb)
            let cb = ctx.queue.makeCommandBuffer()!
            comp.encodeMix(videoA: nil, render: render, videoB: nil, weights: .renderOnly,
                           output: CVMetalTextureGetTexture(tex)!, commandBuffer: cb)
            try ctx.commitAndWait(cb)
            return bgraBytes(of: pb)
        }
        let reference = try mixToBytes(targets)
        let empty = try mixToBytes(nil)
        var covered = 0
        for i in stride(from: 0, to: midBytes.count, by: 4) {
            let d = (0..<3).map { abs(Int(midBytes[i + $0]) - Int(empty[i + $0])) }.max()!
            if d > 8 { covered += 1 }
        }
        let fa = try a.frame(nearest: ml.time)!, fb = try b.frame(nearest: ml.time)!
        return TransitionReport(firstVsA: first, takeVsA: takeC, landingVsB: landingC, lastVsB: last,
                                middleFrame: mid, middleS: ml.s!,
                                middleCoverage: Double(covered) / Double(midBytes.count / 4),
                                middleVsSplatRender: psnr(midBytes, reference),
                                middleVsVideoA: psnr(midBytes, bgraBytes(of: fa.pixelBuffer)),
                                middleVsVideoB: psnr(midBytes, bgraBytes(of: fb.pixelBuffer)))
    }
}
