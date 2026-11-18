// Metal device, queue and the DirectorCore shader library.
// Shaders are compiled from source at runtime because this Mac has no Metal Toolchain
// (docs/track-m/status.md, "Metal Toolchain missing").

import Foundation
import Metal
import CoreVideo

public enum RenderError: Error, CustomStringConvertible {
    case noMetalDevice
    case shaderCompilation(String)
    case missingFunction(String)
    case resourceCreation(String)
    case renderSkipped(String)
    case commandBufferFailed(String)

    public var description: String {
        switch self {
        case .noMetalDevice: return "no Metal device"
        case .shaderCompilation(let s): return "shader compilation failed: \(s)"
        case .missingFunction(let s): return "missing shader function \(s)"
        case .resourceCreation(let s): return "could not create \(s)"
        case .renderSkipped(let s): return "render skipped: \(s)"
        case .commandBufferFailed(let s): return "command buffer failed: \(s)"
        }
    }
}

public final class MetalContext: @unchecked Sendable {
    public let device: MTLDevice
    public let queue: MTLCommandQueue
    public let library: MTLLibrary
    public let textureCache: CVMetalTextureCache

    private static let sharedLock = NSLock()
    nonisolated(unsafe) private static var sharedInstance: MetalContext?

    /// One context per process; compiling the shaders takes a moment.
    public static func shared() throws -> MetalContext {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        if let s = sharedInstance { return s }
        let s = try MetalContext()
        sharedInstance = s
        return s
    }

    public init(device: MTLDevice? = nil) throws {
        guard let dev = device ?? MTLCreateSystemDefaultDevice() else { throw RenderError.noMetalDevice }
        self.device = dev
        guard let q = dev.makeCommandQueue() else { throw RenderError.resourceCreation("command queue") }
        queue = q
        do {
            let options = MTLCompileOptions()
            options.mathMode = .safe
            library = try dev.makeLibrary(source: DirectorShaders.source, options: options)
        } catch {
            throw RenderError.shaderCompilation(String(describing: error))
        }
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, dev, nil, &cache)
        guard let c = cache else { throw RenderError.resourceCreation("CVMetalTextureCache") }
        textureCache = c
    }

    public func function(_ name: String) throws -> MTLFunction {
        guard let f = library.makeFunction(name: name) else { throw RenderError.missingFunction(name) }
        return f
    }

    public func makeTexture(_ format: MTLPixelFormat, width: Int, height: Int,
                            usage: MTLTextureUsage, storage: MTLStorageMode = .private) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        d.usage = usage
        d.storageMode = storage
        guard let t = device.makeTexture(descriptor: d) else {
            throw RenderError.resourceCreation("texture \(format.rawValue) \(width)x\(height)")
        }
        return t
    }

    /// Wraps a BGRA IOSurface-backed pixel buffer as a Metal texture (zero copy).
    /// `srgb` selects the `_srgb` view so that sampling returns linear light and writes encode to sRGB.
    public func texture(for pixelBuffer: CVPixelBuffer, srgb: Bool = true) throws -> CVMetalTexture {
        let w = CVPixelBufferGetWidth(pixelBuffer), h = CVPixelBufferGetHeight(pixelBuffer)
        let fmt = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard fmt == kCVPixelFormatType_32BGRA else {
            throw RenderError.resourceCreation("texture for pixel format \(fmt) (need 32BGRA)")
        }
        var tex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, pixelBuffer, nil,
                                                               srgb ? .bgra8Unorm_srgb : .bgra8Unorm, w, h, 0, &tex)
        guard status == kCVReturnSuccess, let t = tex else {
            throw RenderError.resourceCreation("CVMetalTexture (\(status))")
        }
        return t
    }

    /// Commits and waits; throws if the GPU reported an error.
    public func commitAndWait(_ cb: MTLCommandBuffer) throws {
        cb.commit()
        cb.waitUntilCompleted()
        if let e = cb.error { throw RenderError.commandBufferFailed(String(describing: e)) }
    }
}

/// IOSurface-backed BGRA pixel buffers usable as Metal render targets and as AVAssetWriter input.
public func makeBGRAPixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
    let attrs: [CFString: Any] = [
        kCVPixelBufferMetalCompatibilityKey: true,
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        kCVPixelBufferCGImageCompatibilityKey: true,
    ]
    var pb: CVPixelBuffer?
    let st = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
    guard st == kCVReturnSuccess, let p = pb else { throw RenderError.resourceCreation("pixel buffer (\(st))") }
    return p
}
