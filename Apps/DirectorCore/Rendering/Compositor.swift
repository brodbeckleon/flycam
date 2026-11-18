// Video frame pass and mix pass (plan.md section 4, SceneRenderer: video pass, final mix).
// Everything runs offscreen; the program output is a BGRA (sRGB) texture or pixel buffer.

import Foundation
import Metal
import CoreVideo
import FlyCamKit

/// A linear-light layer at program resolution (rgba16Float).
public final class VideoLayer {
    public let texture: MTLTexture
    public init(context: MetalContext, width: Int, height: Int) throws {
        texture = try context.makeTexture(.rgba16Float, width: width, height: height, usage: [.renderTarget, .shaderRead])
    }
}

public final class Compositor {
    public let context: MetalContext
    /// Linear colour shown where the splat has no content during the flight.
    public var background: SIMD4<Float> = SIMD4(0, 0, 0, 1)

    private let videoPipeline: MTLRenderPipelineState
    private let mixPipeline: MTLRenderPipelineState
    private let mixPipelineLinear: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private var placeholder: MTLTexture

    public init(context: MetalContext) throws {
        self.context = context
        let dev = context.device
        let vtx = try context.function("fullscreenVertex")

        let vd = MTLRenderPipelineDescriptor()
        vd.label = "Video frame pass"
        vd.vertexFunction = vtx
        vd.fragmentFunction = try context.function("videoFragment")
        vd.colorAttachments[0].pixelFormat = .rgba16Float
        videoPipeline = try dev.makeRenderPipelineState(descriptor: vd)

        let md = MTLRenderPipelineDescriptor()
        md.label = "Mix pass"
        md.vertexFunction = vtx
        md.fragmentFunction = try context.function("mixFragment")
        md.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        mixPipeline = try dev.makeRenderPipelineState(descriptor: md)
        md.colorAttachments[0].pixelFormat = .rgba16Float
        mixPipelineLinear = try dev.makeRenderPipelineState(descriptor: md)

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        guard let s = dev.makeSamplerState(descriptor: sd) else { throw RenderError.resourceCreation("sampler") }
        sampler = s
        placeholder = try context.makeTexture(.rgba16Float, width: 1, height: 1, usage: [.shaderRead])
    }

    /// Video frame pass: draws a video texture (sampled through its `_srgb` view) into a linear layer,
    /// resampling to the layer size. With equal sizes the copy is exact up to sRGB rounding.
    public func encodeVideo(_ video: MTLTexture, into layer: VideoLayer, commandBuffer: MTLCommandBuffer) {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = layer.texture
        rp.colorAttachments[0].loadAction = .dontCare
        rp.colorAttachments[0].storeAction = .store
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rp) else { return }
        enc.label = "Video frame pass"
        enc.setRenderPipelineState(videoPipeline)
        enc.setFragmentTexture(video, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    /// Mix pass: `output = wA * videoA + wR * (splat over background) + wB * videoB`.
    /// `output` is a bgra8Unorm_srgb (program) or rgba16Float (linear) texture.
    public func encodeMix(videoA: VideoLayer?, render: SplatRenderTargets?, videoB: VideoLayer?,
                          weights: MixWeights, output: MTLTexture, commandBuffer: MTLCommandBuffer) {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = output
        rp.colorAttachments[0].loadAction = .dontCare
        rp.colorAttachments[0].storeAction = .store
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rp) else { return }
        enc.label = "Mix pass"
        enc.setRenderPipelineState(output.pixelFormat == .rgba16Float ? mixPipelineLinear : mixPipeline)
        enc.setFragmentTexture(videoA?.texture ?? placeholder, index: 0)
        enc.setFragmentTexture(render?.color ?? placeholder, index: 1)
        enc.setFragmentTexture(videoB?.texture ?? placeholder, index: 2)
        var p = MixParams(videoA: videoA == nil ? 0 : Float(weights.videoA),
                          render: render == nil ? 0 : Float(weights.render),
                          videoB: videoB == nil ? 0 : Float(weights.videoB),
                          pad: 0, background: background)
        enc.setFragmentBytes(&p, length: MemoryLayout<MixParams>.stride, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }
}

/// Weights of the final mix. Same meaning as FlyCamKit's `BlendWeights` (which has no public
/// initialiser), plus arbitrary values for previews and tests.
public struct MixWeights: Equatable, Sendable {
    public var videoA: Double
    public var render: Double
    public var videoB: Double

    public init(videoA: Double, render: Double, videoB: Double) {
        self.videoA = videoA
        self.render = render
        self.videoB = videoB
    }

    public init(_ w: BlendWeights) {
        self.init(videoA: w.videoA, render: w.render, videoB: w.videoB)
    }

    public static let videoAOnly = MixWeights(videoA: 1, render: 0, videoB: 0)
    public static let renderOnly = MixWeights(videoA: 0, render: 1, videoB: 0)
    public static let videoBOnly = MixWeights(videoA: 0, render: 0, videoB: 1)
}

struct MixParams {
    var videoA: Float
    var render: Float
    var videoB: Float
    var pad: Float
    var background: SIMD4<Float>
}
