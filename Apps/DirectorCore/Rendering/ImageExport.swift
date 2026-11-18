// PNG export of renders (Phase 2/3 overlays and the colour render next to the .f32 depth for refine_pose).

import Foundation
import CoreGraphics
import CoreVideo
import ImageIO
import UniformTypeIdentifiers

public enum ImageExport {
    /// Writes a 32BGRA pixel buffer as an sRGB PNG.
    public static func writePNG(_ pb: CVPixelBuffer, to url: URL) throws {
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        var bytes = bgraBytes(of: pb)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        let image: CGImage? = bytes.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: cs, bitmapInfo: info.rawValue)?.makeImage()
        }
        guard let img = image,
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw RenderError.resourceCreation("PNG \(url.path)")
        }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { throw RenderError.resourceCreation("PNG \(url.path)") }
    }

    /// The splat colour over `background` as a PNG.
    public static func writePNG(renderTargets: SplatRenderTargets, to url: URL, context: MetalContext,
                                background: SIMD4<Float> = SIMD4(0, 0, 0, 1)) throws {
        let comp = try Compositor(context: context)
        comp.background = background
        let pb = try makeBGRAPixelBuffer(width: renderTargets.width, height: renderTargets.height)
        let tex = try context.texture(for: pb)
        let cb = context.queue.makeCommandBuffer()!
        comp.encodeMix(videoA: nil, render: renderTargets, videoB: nil, weights: .renderOnly,
                       output: CVMetalTextureGetTexture(tex)!, commandBuffer: cb)
        try context.commitAndWait(cb)
        try writePNG(pb, to: url)
    }
}
