// GPU -> CPU readback of offscreen results (tests, depth export for Tools/refine_pose.py).

import Foundation
import Metal
import CoreVideo

public struct FloatImage: Sendable {
    public let width: Int
    public let height: Int
    public let channels: Int
    /// Row-major, `channels` values per pixel.
    public var data: [Float]

    public init(width: Int, height: Int, channels: Int, data: [Float]) {
        precondition(data.count == width * height * channels)
        self.width = width
        self.height = height
        self.channels = channels
        self.data = data
    }

    public subscript(x: Int, y: Int, c: Int) -> Float {
        data[(y * width + x) * channels + c]
    }
}

public enum Readback {
    /// Copies a private texture to shared memory and returns its bytes (bytesPerPixel per pixel, tightly packed rows).
    static func bytes(of texture: MTLTexture, bytesPerPixel: Int, context: MetalContext) throws -> [UInt8] {
        let w = texture.width, h = texture.height
        let rowBytes = w * bytesPerPixel
        guard let buf = context.device.makeBuffer(length: rowBytes * h, options: .storageModeShared),
              let cb = context.queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else {
            throw RenderError.resourceCreation("readback buffer")
        }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: w, height: h, depth: 1), to: buf, destinationOffset: 0,
                  destinationBytesPerRow: rowBytes, destinationBytesPerImage: rowBytes * h)
        blit.endEncoding()
        try context.commitAndWait(cb)
        return Array(UnsafeBufferPointer(start: buf.contents().assumingMemoryBound(to: UInt8.self), count: rowBytes * h))
    }

    /// r32Float texture (e.g. `SplatRenderTargets.depth`).
    public static func r32Float(_ texture: MTLTexture, context: MetalContext) throws -> FloatImage {
        precondition(texture.pixelFormat == .r32Float)
        let b = try bytes(of: texture, bytesPerPixel: 4, context: context)
        let f = b.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        return FloatImage(width: texture.width, height: texture.height, channels: 1, data: f)
    }

    /// rgba16Float texture (e.g. `SplatRenderTargets.color`), linear premultiplied RGBA.
    public static func rgba16Float(_ texture: MTLTexture, context: MetalContext) throws -> FloatImage {
        precondition(texture.pixelFormat == .rgba16Float)
        let b = try bytes(of: texture, bytesPerPixel: 8, context: context)
        let h = b.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }
        return FloatImage(width: texture.width, height: texture.height, channels: 4, data: h.map(Float.init))
    }

    /// BGRA8 texture as bytes in B, G, R, A order.
    public static func bgra8(_ texture: MTLTexture, context: MetalContext) throws -> [UInt8] {
        try bytes(of: texture, bytesPerPixel: 4, context: context)
    }

    /// Raw float32 little-endian H x W, the `.f32` render depth format of docs/protocol.md 2.5a.
    public static func writeF32(_ depth: FloatImage, to url: URL) throws {
        precondition(depth.channels == 1)
        let d = depth.data.map { $0.isFinite ? $0 : 0 }.withUnsafeBufferPointer { Data(buffer: $0) }
        try d.write(to: url)
    }
}

/// BGRA bytes of a 32BGRA pixel buffer, tightly packed.
public func bgraBytes(of pb: CVPixelBuffer) -> [UInt8] {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
    let stride = CVPixelBufferGetBytesPerRow(pb)
    let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
    var out = [UInt8](repeating: 0, count: w * h * 4)
    for y in 0..<h {
        out.withUnsafeMutableBufferPointer { o in
            (o.baseAddress! + y * w * 4).update(from: base + y * stride, count: w * 4)
        }
    }
    return out
}

/// Writes tightly packed BGRA bytes into a 32BGRA pixel buffer.
public func fill(_ pb: CVPixelBuffer, bgra: [UInt8]) {
    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
    let stride = CVPixelBufferGetBytesPerRow(pb)
    let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
    bgra.withUnsafeBufferPointer { src in
        for y in 0..<h { (base + y * stride).update(from: src.baseAddress! + y * w * 4, count: w * 4) }
    }
}

/// Peak signal-to-noise ratio over the RGB channels of two BGRA images, dB.
public func psnr(_ a: [UInt8], _ b: [UInt8]) -> Double {
    precondition(a.count == b.count && a.count % 4 == 0)
    var se = 0.0
    var n = 0
    var i = 0
    while i < a.count {
        for c in 0..<3 {
            let d = Double(a[i + c]) - Double(b[i + c])
            se += d * d
        }
        n += 3
        i += 4
    }
    let mse = se / Double(n)
    return mse == 0 ? .infinity : 10 * log10(255 * 255 / mse)
}
