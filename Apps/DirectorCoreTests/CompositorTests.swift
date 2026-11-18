import XCTest
import Metal
import FlyCamKit
@testable import DirectorCore

final class CompositorTests: XCTestCase {
    /// A smooth synthetic video frame, BGRA.
    func pattern(width: Int, height: Int, phase: Int) -> [UInt8] {
        var b = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                b[i] = UInt8((x * 255) / max(1, width - 1))
                b[i + 1] = UInt8((y * 255) / max(1, height - 1))
                b[i + 2] = UInt8(((x + y + phase) * 3) % 256)
            }
        }
        return b
    }

    func testVideoPassAndMixAtEndpointsReproduceVideo() throws {
        let ctx = try MetalContext.shared()
        let comp = try Compositor(context: ctx)
        let w = 160, h = 90
        let pbA = try makeBGRAPixelBuffer(width: w, height: h)
        let pbB = try makeBGRAPixelBuffer(width: w, height: h)
        let bytesA = pattern(width: w, height: h, phase: 0)
        let bytesB = pattern(width: w, height: h, phase: 77)
        fill(pbA, bgra: bytesA)
        fill(pbB, bgra: bytesB)
        let texA = try ctx.texture(for: pbA), texB = try ctx.texture(for: pbB)
        let layerA = try VideoLayer(context: ctx, width: w, height: h)
        let layerB = try VideoLayer(context: ctx, width: w, height: h)
        let out = try makeBGRAPixelBuffer(width: w, height: h)
        let outTex = try ctx.texture(for: out)

        func mix(_ wts: MixWeights) throws -> [UInt8] {
            let cb = ctx.queue.makeCommandBuffer()!
            comp.encodeVideo(CVMetalTextureGetTexture(texA)!, into: layerA, commandBuffer: cb)
            comp.encodeVideo(CVMetalTextureGetTexture(texB)!, into: layerB, commandBuffer: cb)
            comp.encodeMix(videoA: layerA, render: nil, videoB: layerB, weights: wts,
                           output: CVMetalTextureGetTexture(outTex)!, commandBuffer: cb)
            try ctx.commitAndWait(cb)
            return bgraBytes(of: out)
        }

        let atA = try mix(MixWeights(videoA: 1, render: 0, videoB: 0))
        let atB = try mix(MixWeights(videoA: 0, render: 0, videoB: 1))
        let maxDiffA = zip(atA, bytesA).map { abs(Int($0) - Int($1)) }.max()!
        let maxDiffB = zip(atB, bytesB).map { abs(Int($0) - Int($1)) }.max()!
        XCTAssertLessThanOrEqual(maxDiffA, 1, "video A through video + mix pass")
        XCTAssertLessThanOrEqual(maxDiffB, 1, "video B through video + mix pass")

        // Half-way mix is the average in linear light.
        let half = try mix(MixWeights(videoA: 0.5, render: 0, videoB: 0.5))
        func lin(_ v: UInt8) -> Double { let c = Double(v) / 255; return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        func srgb(_ l: Double) -> Double { (l <= 0.0031308 ? l * 12.92 : 1.055 * pow(l, 1 / 2.4) - 0.055) * 255 }
        var worst = 0.0
        for i in stride(from: 0, to: half.count, by: 4) {
            for c in 0..<3 {
                let e = srgb(0.5 * lin(bytesA[i + c]) + 0.5 * lin(bytesB[i + c]))
                worst = max(worst, abs(e - Double(half[i + c])))
            }
        }
        XCTAssertLessThan(worst, 1.01)
    }

    func testRenderWeightShowsSplatOverBackground() async throws {
        let ctx = try MetalContext.shared()
        let comp = try Compositor(context: ctx)
        comp.background = SIMD4(0, 0, 1, 1)
        let k = Intrinsics(fx: 100, fy: 100, cx: 63.5, cy: 35.5, width: 128, height: 72)
        let scene = try await SplatScene(points: [], context: ctx)
        _ = scene
        // One large red Gaussian 2 m in front of the camera.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("flycam-red-\(UUID().uuidString).ply")
        try GaussianPLY.write([Gaussian(position: SIMD3(0, 0, -2), color: SIMD3(1, 0, 0), opacity: 0.999999, radius: 0.15)], to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let red = try await SplatScene.load(url: url, context: ctx)
        let targets = try SplatRenderTargets(context: ctx, width: k.width, height: k.height)
        try red.renderSettled(camera: PinholeCamera(intrinsics: k, c2w: .identity), targets: targets)
        let out = try makeBGRAPixelBuffer(width: k.width, height: k.height)
        let outTex = try ctx.texture(for: out)
        let cb = ctx.queue.makeCommandBuffer()!
        comp.encodeMix(videoA: nil, render: targets, videoB: nil, weights: MixWeights(videoA: 0, render: 1, videoB: 0),
                       output: CVMetalTextureGetTexture(outTex)!, commandBuffer: cb)
        try ctx.commitAndWait(cb)
        let b = bgraBytes(of: out)
        let centre = (35 * k.width + 63) * 4
        XCTAssertGreaterThan(b[centre + 2], 240, "red at the centre")
        XCTAssertLessThan(b[centre + 0], 15)
        let corner = 0
        XCTAssertGreaterThan(b[corner + 0], 240, "background blue in the corner")
        XCTAssertLessThan(b[corner + 2], 15)
    }
}
