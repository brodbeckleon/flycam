// Renders one program frame: untouched video outside a flight; during a flight the static splat from the
// virtual camera, cross-faded with the real video at both ends (plan.md Phase 4 "Blend").
// Used offline (director-cli) and live (DirectorApp).

import Foundation
import Metal
import CoreVideo
import FlyCamKit

public final class ProgramRenderer {
    public let context: MetalContext
    public let scene: SplatScene?
    public let compositor: Compositor
    public let width: Int
    public let height: Int
    /// Offline: wait for a depth sort for every virtual camera (deterministic). Live: render with the latest sort.
    public var settled: Bool
    /// Floor height for the floor guard; nil disables it.
    public var floorY: Double?

    private let layerA: VideoLayer
    private let layerB: VideoLayer
    private var splatTargets: SplatRenderTargets?

    public init(context: MetalContext, scene: SplatScene?, width: Int, height: Int, settled: Bool, floorY: Double?) throws {
        self.context = context
        self.scene = scene
        compositor = try Compositor(context: context)
        self.width = width
        self.height = height
        self.settled = settled
        self.floorY = floorY
        layerA = try VideoLayer(context: context, width: width, height: height)
        layerB = try VideoLayer(context: context, width: width, height: height)
    }

    private func targets(for k: Intrinsics) throws -> SplatRenderTargets {
        if let t = splatTargets, t.width == k.width, t.height == k.height { return t }
        let t = try SplatRenderTargets(context: context, width: k.width, height: k.height)
        splatTargets = t
        return t
    }

    /// Renders the program at `time` for `state` into `output` (bgra8Unorm_srgb, `width` x `height`).
    /// Waits for the GPU. Returns the frame log (weights, virtual camera, source frames).
    @discardableResult
    public func render(state: ProgramState, time: Double, sources: [UInt16: FrameSource],
                       controller: TransitionController, output: MTLTexture, frameNumber: Int = 0) throws -> ProgramFrameLog {
        var log = ProgramFrameLog(frame: frameNumber, time: time, u: nil, s: nil, videoA: 1, render: 0, videoB: 0,
                                  programCamera: Int(controller.program))
        var keepAlive = [CVMetalTexture]()
        switch state {
        case .video(let id):
            log.programCamera = Int(id)
            let cb = context.queue.makeCommandBuffer()!
            if let src = sources[id], let f = try src.frame(nearest: time) {
                let tex = try context.texture(for: f.pixelBuffer)
                keepAlive.append(tex)
                compositor.encodeVideo(CVMetalTextureGetTexture(tex)!, into: layerA, commandBuffer: cb)
                log.sourceA = f.index
                compositor.encodeMix(videoA: layerA, render: nil, videoB: nil, weights: .videoAOnly, output: output, commandBuffer: cb)
            } else {
                compositor.encodeMix(videoA: nil, render: nil, videoB: nil, weights: .videoAOnly, output: output, commandBuffer: cb)
            }
            try context.commitAndWait(cb)

        case .transition(let a, let elapsed):
            log.programCamera = Int(a.from)
            guard let srcA = sources[a.from], let srcB = sources[a.to],
                  let fA = try srcA.frame(nearest: time), let fB = try srcB.frame(nearest: time) else {
                throw RenderError.renderSkipped("transition sources have no frames at \(time)")
            }
            let path = controller.path(from: fA.camera, to: fB.camera, floorY: floorY)
            let s = path.progress(atTime: elapsed)
            let cam = path.camera(atProgress: s)
            let w = MixWeights(path.blendWeights(atTime: elapsed))
            log.u = elapsed / a.duration
            log.s = s
            log.videoA = w.videoA
            log.render = w.render
            log.videoB = w.videoB
            log.sourceA = fA.index
            log.sourceB = fB.index
            log.c2w = cam.c2w.columnMajor
            log.fx = cam.intrinsics.fx
            log.fy = cam.intrinsics.fy
            log.cx = cam.intrinsics.cx
            log.cy = cam.intrinsics.cy
            log.interestPoint = path.interestPoint.array
            log.interestMethod = path.interestMethod.rawValue

            var renderTargets: SplatRenderTargets?
            if w.render > 0, let scene {
                let t = try targets(for: cam.intrinsics)
                if settled {
                    try scene.renderSettled(camera: cam, targets: t)
                } else {
                    let cb = context.queue.makeCommandBuffer()!
                    try scene.encode(camera: cam, targets: t, commandBuffer: cb)
                    try context.commitAndWait(cb)
                }
                renderTargets = t
            }
            let cb = context.queue.makeCommandBuffer()!
            var la: VideoLayer?, lb: VideoLayer?
            if w.videoA > 0 {
                let tex = try context.texture(for: fA.pixelBuffer)
                keepAlive.append(tex)
                compositor.encodeVideo(CVMetalTextureGetTexture(tex)!, into: layerA, commandBuffer: cb)
                la = layerA
            }
            if w.videoB > 0 {
                let tex = try context.texture(for: fB.pixelBuffer)
                keepAlive.append(tex)
                compositor.encodeVideo(CVMetalTextureGetTexture(tex)!, into: layerB, commandBuffer: cb)
                lb = layerB
            }
            compositor.encodeMix(videoA: la, render: renderTargets, videoB: lb, weights: w, output: output, commandBuffer: cb)
            try context.commitAndWait(cb)
        }
        _ = keepAlive
        return log
    }
}
