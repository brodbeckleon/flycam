// Writes session folders (docs/protocol.md 2) whose video is rendered from a splat: the generated
// stand-in for a phone recording of the static scene. Used by the tests and by `director-cli make-fixture`.

import Foundation
import CoreVideo
import FlyCamKit

public struct SyntheticSessionSpec {
    public var name: String
    public var cameraID: Int
    public var frameCount: Int
    public var fps: Double
    /// Phone clock time of the first frame.
    public var startTime: Double
    /// `t_mac - t_phone`, written to meta.json (nil = recorded standalone).
    public var clockOffset: Double?
    /// Camera for frame i (fixed tripod: return the same camera).
    public var camera: (Int) -> PinholeCamera
    /// Stamp the frame index into the top-left corner (FrameCode).
    public var stampFrameIndex: Bool = true

    public init(name: String, cameraID: Int, frameCount: Int, fps: Double, startTime: Double,
                clockOffset: Double?, camera: @escaping (Int) -> PinholeCamera) {
        self.name = name
        self.cameraID = cameraID
        self.frameCount = frameCount
        self.fps = fps
        self.startTime = startTime
        self.clockOffset = clockOffset
        self.camera = camera
    }
}

public enum SyntheticSession {
    /// Renders and writes the session; returns its folder (`parent/spec.name`).
    @discardableResult
    public static func write(_ spec: SyntheticSessionSpec, scene: SplatScene, floorY: Double?, to parent: URL) throws -> URL {
        let ctx = scene.context
        let compositor = try Compositor(context: ctx)
        compositor.background = SIMD4(0.05, 0.05, 0.06, 1)
        let folder = parent.appendingPathComponent(spec.name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let first = spec.camera(0)
        let w = first.intrinsics.width, h = first.intrinsics.height
        let video = try SessionVideoWriter(url: folder.appendingPathComponent("video.mov"), width: w, height: h,
                                           fps: spec.fps, quality: 0.95)
        let targets = try SplatRenderTargets(context: ctx, width: w, height: h)
        var records = [FrameRecord]()
        var lastCamera: PinholeCamera?
        for i in 0..<spec.frameCount {
            let cam = spec.camera(i)
            if cam != lastCamera {
                try scene.renderSettled(camera: cam, targets: targets)
                lastCamera = cam
            }
            let pb = try makeBGRAPixelBuffer(width: w, height: h)
            let tex = try ctx.texture(for: pb)
            let cb = ctx.queue.makeCommandBuffer()!
            compositor.encodeMix(videoA: nil, render: targets, videoB: nil, weights: .renderOnly,
                                 output: CVMetalTextureGetTexture(tex)!, commandBuffer: cb)
            try ctx.commitAndWait(cb)
            if spec.stampFrameIndex { FrameCode.stamp(i, into: pb) }
            let t = spec.startTime + Double(i) / spec.fps
            try video.append(pb, time: t)
            records.append(FrameRecord(i: i, t: t, c2w: cam.c2w, intrinsics: cam.intrinsics, tracking: .normal,
                                       iso: 100, shutter: 1 / 120))
        }
        try video.finishBlocking()
        let meta = SessionMeta(kind: .clip, deviceModel: "synthetic", osVersion: "n/a", cameraID: spec.cameraID,
                               videoFormat: VideoFormat(width: w, height: h, fps: spec.fps),
                               cameraSettings: CameraSettings(locked: true, iso: 100, shutter: 1 / 120, wbTemperature: 5000, wbTint: 0),
                               floorY: floorY, clockOffset: spec.clockOffset,
                               created: ISO8601DateFormatter().string(from: Date()))
        try SessionIO.write(meta: meta, frames: records, to: folder)
        return folder
    }

    /// The standard fixture: the synthetic room as `splat.ply` plus two tripod sessions recorded together
    /// (shared Mac clock, different phone clocks). Returns (splat, sessionA, sessionB).
    @discardableResult
    public static func writeTwoCameraFixture(to dir: URL, frameCount: Int = 60, fps: Double = 30,
                                             spacing: Float = 0.04, context: MetalContext) async throws -> (URL, URL, URL) {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let room = SyntheticRoom(spacing: spacing)
        let splatURL = dir.appendingPathComponent("splat.ply")
        try GaussianPLY.write(room.gaussians(), to: splatURL)
        let scene = try await SplatScene.load(url: splatURL, context: context)
        let (camA, camB) = SyntheticRoom.tripodCameras()
        // Phone clocks differ; offsets map both to the same Mac clock (Mac time 5000 at the first frame).
        let a = SyntheticSessionSpec(name: "session_synth_A", cameraID: 0, frameCount: frameCount, fps: fps,
                                     startTime: 1200.0, clockOffset: 3800.0, camera: { _ in camA })
        let b = SyntheticSessionSpec(name: "session_synth_B", cameraID: 1, frameCount: frameCount, fps: fps,
                                     startTime: 77.5 + 0.004, clockOffset: 4922.5, camera: { _ in camB })
        let fa = try write(a, scene: scene, floorY: Double(room.floorY), to: dir)
        let fb = try write(b, scene: scene, floorY: Double(room.floorY), to: dir)
        return (splatURL, fa, fb)
    }
}
