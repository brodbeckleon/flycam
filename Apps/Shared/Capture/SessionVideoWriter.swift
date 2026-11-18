// HEVC writer for video.mov of a session folder (docs/protocol.md 2.3): one video track, no frame
// reordering (decode order = presentation order, so video frame i is line i of frames.jsonl).
// Used by the CaptureApp recorder (input: ARFrame.capturedImage) and by the Mac fixture generator (BGRA).

import Foundation
import AVFoundation
import CoreVideo

public enum SessionVideoWriterError: Error, CustomStringConvertible {
    case cannotStart(String)
    case appendFailed(String)
    case notMonotonic(Double)

    public var description: String {
        switch self {
        case .cannotStart(let s): return "cannot start video writer: \(s)"
        case .appendFailed(let s): return "cannot append video frame: \(s)"
        case .notMonotonic(let t): return "frame time \(t) is not after the previous frame"
        }
    }
}

public final class SessionVideoWriter {
    public let url: URL
    public let width: Int
    public let height: Int
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var firstTime: Double?
    private var lastPTS: CMTime?
    public private(set) var frameCount = 0

    /// - Parameters:
    ///   - bitRate: bits per second (default 20 Mbit/s at 1080p, plan Phase 5 range).
    ///   - fps: expected frame rate, also used for the keyframe interval (1 s).
    public init(url: URL, width: Int, height: Int, fps: Double, bitRate: Int? = nil, quality: Double? = nil) throws {
        self.url = url
        self.width = width
        self.height = height
        try? FileManager.default.removeItem(at: url)
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        } catch {
            throw SessionVideoWriterError.cannotStart(String(describing: error))
        }
        var compression: [String: Any] = [
            AVVideoAllowFrameReorderingKey: false,
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalKey: max(1, Int(fps.rounded())),
        ]
        if let q = quality {
            compression[AVVideoQualityKey] = q
        } else {
            compression[AVVideoAverageBitRateKey] = bitRate ?? Int(20_000_000 * Double(width * height) / (1920 * 1080))
        }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
        ]
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(input) else { throw SessionVideoWriterError.cannotStart("cannot add video input") }
        writer.add(input)
        guard writer.startWriting() else {
            throw SessionVideoWriterError.cannotStart(String(describing: writer.error))
        }
        writer.startSession(atSourceTime: .zero)
    }

    /// Appends a frame captured at `time` seconds (any clock; the first frame is at 0 in the file).
    /// Blocks briefly while the encoder is busy so that no frame is dropped.
    public func append(_ pixelBuffer: CVPixelBuffer, time: Double) throws {
        if firstTime == nil { firstTime = time }
        let pts = CMTime(seconds: time - firstTime!, preferredTimescale: 600_000)
        if let last = lastPTS, pts <= last { throw SessionVideoWriterError.notMonotonic(time) }
        var waited = 0
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed { throw SessionVideoWriterError.appendFailed(String(describing: writer.error)) }
            usleep(1000)
            waited += 1
            if waited > 5000 { throw SessionVideoWriterError.appendFailed("encoder not ready for 5 s") }
        }
        guard adaptor.append(pixelBuffer, withPresentationTime: pts) else {
            throw SessionVideoWriterError.appendFailed(String(describing: writer.error))
        }
        lastPTS = pts
        frameCount += 1
    }

    public func finish() async throws {
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            throw SessionVideoWriterError.appendFailed("finish: \(String(describing: writer.error))")
        }
    }

    /// Blocking variant for command-line use and non-async callers.
    public func finishBlocking() throws {
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        if writer.status != .completed {
            throw SessionVideoWriterError.appendFailed("finish: \(String(describing: writer.error))")
        }
    }
}
