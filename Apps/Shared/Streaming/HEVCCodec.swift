// HEVC encode and decode with VideoToolbox (plan.md Phase 5). Shared by CaptureApp (encoder) and
// DirectorCore (decoder; the encoder also runs on the Mac for the loopback test).
// Wire payload: one access unit as 4-byte big-endian length-prefixed NAL units; keyframes start with
// VPS, SPS, PPS (docs/protocol.md 3.3).

import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo
import QuartzCore
import FlyCamKit

/// Monotonic uptime clock shared by phone and Mac code. On the phone `ARFrame.timestamp` is expected to use the
/// same timebase (plan.md section 5, Verify in Phase 1).
public enum MonotonicClock {
    public static func now() -> Double { CACurrentMediaTime() }
}

public enum CodecError: Error, CustomStringConvertible {
    case vt(String, OSStatus)
    case noParameterSets
    case invalidPayload(String)

    public var description: String {
        switch self {
        case .vt(let what, let st): return "\(what) failed (OSStatus \(st))"
        case .noParameterSets: return "no parameter sets received yet (waiting for a keyframe)"
        case .invalidPayload(let s): return "invalid payload: \(s)"
        }
    }
}

public struct EncodedAccessUnit: Sendable {
    /// Wire payload (length-prefixed NAL units, parameter sets first on keyframes).
    public var payload: [UInt8]
    public var keyframe: Bool
    public var hasParameterSets: Bool
    public var pts: CMTime
}

public final class HEVCEncoder {
    public let width: Int
    public let height: Int
    private var session: VTCompressionSession?
    private var forceKeyframe = true
    public private(set) var encodedCount = 0

    /// - Parameters: plan.md Phase 5: real-time, no frame reordering, keyframe every 1-2 s, 10-20 Mbit/s at 1080p.
    public init(width: Int, height: Int, fps: Double, bitRate: Int = 15_000_000, keyframeInterval: Double = 1.0) throws {
        self.width = width
        self.height = height
        var spec: [CFString: Any] = [:]
        #if os(macOS)
        spec[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder] = true
        #endif
        var s: VTCompressionSession?
        let st = VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
                                            codecType: kCMVideoCodecType_HEVC, encoderSpecification: spec as CFDictionary,
                                            imageBufferAttributes: nil, compressedDataAllocator: nil,
                                            outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard st == noErr, let session = s else { throw CodecError.vt("VTCompressionSessionCreate", st) }
        self.session = session
        let props: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_HEVC_Main_AutoLevel,
            kVTCompressionPropertyKey_AverageBitRate: bitRate,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: keyframeInterval,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: max(1, Int((fps * keyframeInterval).rounded())),
            kVTCompressionPropertyKey_ExpectedFrameRate: fps,
            kVTCompressionPropertyKey_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kVTCompressionPropertyKey_TransferFunction: kCVImageBufferTransferFunction_ITU_R_709_2,
            kVTCompressionPropertyKey_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        ]
        for (k, v) in props {
            let r = VTSessionSetProperty(session, key: k, value: v as CFTypeRef)
            if r != noErr && k != kVTCompressionPropertyKey_MaxKeyFrameInterval {
                throw CodecError.vt("VTSessionSetProperty \(k)", r)
            }
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    deinit {
        if let s = session {
            VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(s)
        }
    }

    /// The next frame will be a keyframe with parameter sets (e.g. after a receiver connected).
    public func requestKeyframe() { forceKeyframe = true }

    /// Encodes one frame. `completion` runs on a VideoToolbox thread, in frame order.
    public func encode(_ pb: CVPixelBuffer, pts: CMTime, completion: @escaping (Result<EncodedAccessUnit, Error>) -> Void) {
        guard let session else { return }
        var frameProps: CFDictionary?
        if forceKeyframe {
            frameProps = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            forceKeyframe = false
        }
        let st = VTCompressionSessionEncodeFrame(session, imageBuffer: pb, presentationTimeStamp: pts, duration: .invalid,
                                                 frameProperties: frameProps, infoFlagsOut: nil) { status, _, sb in
            guard status == noErr, let sb else {
                completion(.failure(CodecError.vt("encode", status)))
                return
            }
            do {
                completion(.success(try Self.accessUnit(from: sb)))
            } catch {
                completion(.failure(error))
            }
        }
        if st != noErr { completion(.failure(CodecError.vt("VTCompressionSessionEncodeFrame", st))) }
        encodedCount += 1
    }

    /// Blocking encode (tests and simple callers).
    public func encodeSync(_ pb: CVPixelBuffer, pts: CMTime) throws -> EncodedAccessUnit {
        var result: Result<EncodedAccessUnit, Error>?
        encode(pb, pts: pts) { result = $0 }
        if let s = session { VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: pts) }
        guard let r = result else { throw CodecError.vt("encode produced no output", -1) }
        return try r.get()
    }

    static func accessUnit(from sb: CMSampleBuffer) throws -> EncodedAccessUnit {
        guard let block = CMSampleBufferGetDataBuffer(sb), let fmt = CMSampleBufferGetFormatDescription(sb) else {
            throw CodecError.invalidPayload("sample buffer without data")
        }
        var keyframe = true
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]],
           let first = atts.first, let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            keyframe = !notSync
        }
        let len = CMBlockBufferGetDataLength(block)
        var data = [UInt8](repeating: 0, count: len)
        let st = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len, destination: &data)
        guard st == noErr else { throw CodecError.vt("CMBlockBufferCopyDataBytes", st) }

        var headerLength: Int32 = 4
        var count = 0
        CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                           parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                           nalUnitHeaderLengthOut: &headerLength)
        var nals = try splitNALs(data, lengthSize: Int(headerLength))
        var hasPS = false
        if keyframe {
            var ps = [[UInt8]]()
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                let r = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                                                                           parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                           nalUnitHeaderLengthOut: nil)
                guard r == noErr, let p = ptr else { throw CodecError.vt("HEVC parameter set \(i)", r) }
                ps.append(Array(UnsafeBufferPointer(start: p, count: size)))
            }
            // Keep VPS, SPS, PPS first and in that order (docs/protocol.md 3.3).
            ps.sort { (HEVCPayload.nalType($0) ?? 99) < (HEVCPayload.nalType($1) ?? 99) }
            nals = ps + nals
            hasPS = !ps.isEmpty
        }
        return EncodedAccessUnit(payload: HEVCPayload.join(nalUnits: nals), keyframe: keyframe, hasParameterSets: hasPS,
                                 pts: CMSampleBufferGetPresentationTimeStamp(sb))
    }

    static func splitNALs(_ data: [UInt8], lengthSize: Int) throws -> [[UInt8]] {
        var out = [[UInt8]]()
        var i = 0
        while i < data.count {
            guard i + lengthSize <= data.count else { throw CodecError.invalidPayload("truncated NAL length") }
            var n = 0
            for k in 0..<lengthSize { n = (n << 8) | Int(data[i + k]) }
            i += lengthSize
            guard n > 0, i + n <= data.count else { throw CodecError.invalidPayload("bad NAL length \(n)") }
            out.append(Array(data[i..<(i + n)]))
            i += n
        }
        return out
    }
}

public final class HEVCDecoder {
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var parameterSets: [[UInt8]] = []
    public let pixelFormat: OSType
    public private(set) var decodedCount = 0

    public init(pixelFormat: OSType = kCVPixelFormatType_32BGRA) {
        self.pixelFormat = pixelFormat
    }

    deinit {
        if let s = session { VTDecompressionSessionInvalidate(s) }
    }

    /// Decodes one wire payload. Returns nil while waiting for the first keyframe with parameter sets.
    public func decode(payload: [UInt8], pts: CMTime = .zero) throws -> CVPixelBuffer? {
        var nals = try HEVCPayload.split(payload)
        let ps = nals.prefix { [32, 33, 34].contains(HEVCPayload.nalType($0) ?? -1) }
        if !ps.isEmpty {
            let sets = Array(ps)
            if sets != parameterSets || session == nil { try configure(parameterSets: sets) }
            nals.removeFirst(sets.count)
        }
        guard let session, let format else { return nil }
        guard !nals.isEmpty else { return nil }
        let data = HEVCPayload.join(nalUnits: nals)
        var block: CMBlockBuffer?
        var st = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
                                                    blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                    dataLength: data.count, flags: 0, blockBufferOut: &block)
        guard st == noErr, let block else { throw CodecError.vt("CMBlockBufferCreateWithMemoryBlock", st) }
        st = data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count) }
        guard st == noErr else { throw CodecError.vt("CMBlockBufferReplaceDataBytes", st) }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sizes = [data.count]
        var sb: CMSampleBuffer?
        st = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                       sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                       sampleSizeArray: &sizes, sampleBufferOut: &sb)
        guard st == noErr, let sb else { throw CodecError.vt("CMSampleBufferCreateReady", st) }
        var output: CVPixelBuffer?
        var decodeStatus: OSStatus = noErr
        st = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sb, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
            decodeStatus = status
            output = image
        }
        guard st == noErr else { throw CodecError.vt("VTDecompressionSessionDecodeFrame", st) }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        guard decodeStatus == noErr else { throw CodecError.vt("decode", decodeStatus) }
        if output != nil { decodedCount += 1 }
        return output
    }

    private func configure(parameterSets sets: [[UInt8]]) throws {
        var fmt: CMFormatDescription?
        let st: OSStatus = withPointers(sets) { ptrs, sizes in
            CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                                                                parameterSetPointers: ptrs, parameterSetSizes: sizes,
                                                                nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fmt)
        }
        guard st == noErr, let fmt else { throw CodecError.vt("CMVideoFormatDescriptionCreateFromHEVCParameterSets", st) }
        if let s = session { VTDecompressionSessionInvalidate(s) }
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var s: VTDecompressionSession?
        let r = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: fmt, decoderSpecification: nil,
                                             imageBufferAttributes: attrs as CFDictionary, outputCallback: nil,
                                             decompressionSessionOut: &s)
        guard r == noErr, let s else { throw CodecError.vt("VTDecompressionSessionCreate", r) }
        VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = s
        format = fmt
        parameterSets = sets
    }

    private func withPointers<R>(_ sets: [[UInt8]], _ body: (UnsafePointer<UnsafePointer<UInt8>>, UnsafePointer<Int>) -> R) -> R {
        let buffers = sets.map { s -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: s.count)
            p.initialize(from: s, count: s.count)
            return p
        }
        defer { buffers.enumerated().forEach { $0.element.deallocate() } }
        let ptrs = buffers.map { UnsafePointer($0) }
        let sizes = sets.map(\.count)
        return ptrs.withUnsafeBufferPointer { p in sizes.withUnsafeBufferPointer { s in body(p.baseAddress!, s.baseAddress!) } }
    }
}
