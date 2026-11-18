// Static scene splat (plan.md Phase 2) loaded with MetalSplatter, rendered offscreen into colour and
// depth for a camera given by explicit intrinsics fx, fy, cx, cy and a c2w pose.

import Foundation
import Metal
import simd
import FlyCamKit
import MetalSplatter
import SplatIO

/// Offscreen targets of one splat render.
public final class SplatRenderTargets {
    public let width: Int
    public let height: Int
    /// Linear premultiplied colour of the splat, rgba16Float.
    public let color: MTLTexture
    /// MetalSplatter's depth attachment (NDC depth, depth32Float).
    public let ndcDepth: MTLTexture
    /// Metric depth along the viewing axis (r32Float), 0 where the splat has no content.
    /// Written by the depth pass after the splat pass; readable by any later pass.
    public let depth: MTLTexture

    public init(context: MetalContext, width: Int, height: Int) throws {
        self.width = width
        self.height = height
        color = try context.makeTexture(SplatScene.colorFormat, width: width, height: height, usage: [.renderTarget, .shaderRead])
        ndcDepth = try context.makeTexture(SplatScene.depthFormat, width: width, height: height, usage: [.renderTarget, .shaderRead])
        depth = try context.makeTexture(.r32Float, width: width, height: height, usage: [.shaderWrite, .shaderRead])
    }
}

public final class SplatScene: @unchecked Sendable {
    public static let colorFormat: MTLPixelFormat = .rgba16Float
    public static let depthFormat: MTLPixelFormat = .depth32Float

    public let context: MetalContext
    public let renderer: SplatRenderer
    public let splatCount: Int
    public var depthRange = DepthRange()
    /// Pixels with accumulated alpha below this count as empty in the depth pass.
    public var minDepthAlpha: Float = 1.0 / 255

    private let depthPipeline: MTLComputePipelineState

    /// Loads a splat file (`.ply` in the 3DGS layout, also `.splat` / `.spz`) with MetalSplatter's SplatIO.
    public static func load(url: URL, context: MetalContext) async throws -> SplatScene {
        let points = try await AutodetectSceneReader(url).readAll()
        return try await SplatScene(points: points, context: context)
    }

    public init(points: [SplatPoint], context: MetalContext) async throws {
        self.context = context
        renderer = try SplatRenderer(device: context.device,
                                     colorFormat: Self.colorFormat,
                                     depthFormat: Self.depthFormat,
                                     sampleCount: 1,
                                     maxViewCount: 1,
                                     maxSimultaneousRenders: 3,
                                     highQualityDepth: true)
        let chunk = try SplatChunk(device: context.device, from: points)
        splatCount = points.count
        depthPipeline = try await context.device.makeComputePipelineState(function: try context.function("linearizeDepth"))
        if !points.isEmpty {
            await renderer.addChunk(chunk, sortByLocality: false)
        }
    }

    func viewport(for camera: PinholeCamera) -> SplatRenderer.ViewportDescriptor {
        let k = camera.intrinsics
        let proj = camera.projectionMatrix(near: depthRange.near, far: depthRange.far).simdFloat
        let view = camera.viewMatrix.simdFloat
        return SplatRenderer.ViewportDescriptor(
            viewport: MTLViewport(originX: 0, originY: 0, width: Double(k.width), height: Double(k.height), znear: 0, zfar: 1),
            projectionMatrix: proj, viewMatrix: view, screenSize: SIMD2(k.width, k.height))
    }

    /// Encodes the splat pass and the depth pass into `commandBuffer`.
    /// Returns false when MetalSplatter skipped the frame (no sorted indices yet or busy).
    @discardableResult
    public func encode(camera: PinholeCamera, targets: SplatRenderTargets, commandBuffer: MTLCommandBuffer) throws -> Bool {
        precondition(camera.intrinsics.width == targets.width && camera.intrinsics.height == targets.height,
                     "intrinsics are for \(camera.intrinsics.width)x\(camera.intrinsics.height), targets are \(targets.width)x\(targets.height)")
        let ok = try renderer.render(viewports: [viewport(for: camera)],
                                     colorTexture: targets.color,
                                     colorStoreAction: .store,
                                     depthTexture: targets.ndcDepth,
                                     rasterizationRateMap: nil,
                                     renderTargetArrayLength: 0,
                                     accessTimeout: 1,
                                     sortTimeout: 2,
                                     to: commandBuffer)
        if !ok {
            clear(targets: targets, commandBuffer: commandBuffer)
        }
        encodeDepthPass(targets: targets, commandBuffer: commandBuffer)
        return ok
    }

    /// Depth pass: NDC depth + alpha -> metric depth texture.
    public func encodeDepthPass(targets: SplatRenderTargets, commandBuffer: MTLCommandBuffer) {
        guard let enc = commandBuffer.makeComputeCommandEncoder() else { return }
        enc.label = "Splat depth to metric"
        enc.setComputePipelineState(depthPipeline)
        enc.setTexture(targets.ndcDepth, index: 0)
        enc.setTexture(targets.color, index: 1)
        enc.setTexture(targets.depth, index: 2)
        var p = SIMD4<Float>(Float(depthRange.near), Float(depthRange.far), minDepthAlpha, 0)
        enc.setBytes(&p, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        enc.dispatchThreads(MTLSize(width: targets.width, height: targets.height, depth: 1), threadsPerThreadgroup: tg)
        enc.endEncoding()
    }

    private func clear(targets: SplatRenderTargets, commandBuffer: MTLCommandBuffer) {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = targets.color
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rp.colorAttachments[0].storeAction = .store
        rp.depthAttachment.texture = targets.ndcDepth
        rp.depthAttachment.loadAction = .clear
        rp.depthAttachment.clearDepth = 0
        rp.depthAttachment.storeAction = .store
        commandBuffer.makeRenderCommandEncoder(descriptor: rp)?.endEncoding()
    }

    /// Offscreen render that waits for a depth sort made for exactly this camera, so the result is
    /// deterministic (used for offline transitions, exports and tests). Renders up to three times.
    public func renderSettled(camera: PinholeCamera, targets: SplatRenderTargets) throws {
        guard splatCount > 0 else {
            let cb = context.queue.makeCommandBuffer()!
            clear(targets: targets, commandBuffer: cb)
            encodeDepthPass(targets: targets, commandBuffer: cb)
            try context.commitAndWait(cb)
            return
        }
        // Each render() hands the camera pose to the sorter. A sort that completes after the second
        // render was started after the first render set this pose, so its order is for this camera.
        for _ in 0..<2 {
            let cb = context.queue.makeCommandBuffer()!
            let sem = DispatchSemaphore(value: 0)
            renderer.afterNextSort { sem.signal() }
            try encode(camera: camera, targets: targets, commandBuffer: cb)
            try context.commitAndWait(cb)
            _ = sem.wait(timeout: .now() + 5)
        }
        let cb = context.queue.makeCommandBuffer()!
        guard try encode(camera: camera, targets: targets, commandBuffer: cb) else {
            try context.commitAndWait(cb)
            throw RenderError.renderSkipped("MetalSplatter returned no sorted indices")
        }
        try context.commitAndWait(cb)
    }
}
