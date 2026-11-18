// Decodes video.mov to 32BGRA pixel buffers by frame index (frame i = i-th sample in presentation order,
// docs/protocol.md 2.3). Sequential access is cheap; going backwards or jumping far ahead seeks.

import Foundation
import AVFoundation
import CoreVideo

public enum VideoFileError: Error, CustomStringConvertible {
    case noVideoTrack(URL)
    case readerFailed(String)
    case frameOutOfRange(Int, Int)

    public var description: String {
        switch self {
        case .noVideoTrack(let u): return "no video track in \(u.path)"
        case .readerFailed(let s): return "video reader failed: \(s)"
        case .frameOutOfRange(let i, let n): return "frame \(i) out of range (video has \(n) frames)"
        }
    }
}

public final class VideoFileReader {
    public let url: URL
    public let width: Int
    public let height: Int
    /// Presentation times of all samples, in order.
    public let sampleTimes: [CMTime]
    public var frameCount: Int { sampleTimes.count }

    private let asset: AVURLAsset
    private let track: AVAssetTrack
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    /// Index of the next frame `output` will deliver.
    private var nextIndex = 0
    private var cache: (index: Int, buffer: CVPixelBuffer)?
    /// Seek instead of decoding forward when the target is more than this many frames ahead.
    public var maxForwardDecode = 90

    public init(url: URL) async throws {
        self.url = url
        asset = AVURLAsset(url: url)
        guard let t = try await asset.loadTracks(withMediaType: .video).first else { throw VideoFileError.noVideoTrack(url) }
        track = t
        let size = try await t.load(.naturalSize)
        width = Int(size.width.rounded())
        height = Int(size.height.rounded())
        sampleTimes = try Self.readSampleTimes(asset: asset, track: t)
    }

    /// Presentation times without decoding (compressed samples).
    private static func readSampleTimes(asset: AVAsset, track: AVAssetTrack) throws -> [CMTime] {
        let r = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        out.alwaysCopiesSampleData = false
        r.add(out)
        guard r.startReading() else { throw VideoFileError.readerFailed(String(describing: r.error)) }
        var times = [CMTime]()
        while let sb = out.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sb) > 0 { times.append(CMSampleBufferGetPresentationTimeStamp(sb)) }
        }
        if r.status == .failed { throw VideoFileError.readerFailed(String(describing: r.error)) }
        return times.sorted()
    }

    private func startReader(at index: Int) throws {
        reader?.cancelReading()
        let r = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ])
        out.alwaysCopiesSampleData = false
        r.add(out)
        if index > 0 {
            r.timeRange = CMTimeRange(start: sampleTimes[index], duration: .positiveInfinity)
        }
        guard r.startReading() else { throw VideoFileError.readerFailed(String(describing: r.error)) }
        reader = r
        output = out
        nextIndex = index
    }

    /// The decoded frame `index` (32BGRA).
    public func frame(at index: Int) throws -> CVPixelBuffer {
        guard index >= 0 && index < frameCount else { throw VideoFileError.frameOutOfRange(index, frameCount) }
        if let c = cache, c.index == index { return c.buffer }
        if output == nil || index < nextIndex || index - nextIndex > maxForwardDecode {
            try startReader(at: index)
        }
        while let sb = output?.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            // Identify the frame by its presentation time (robust against where the reader started).
            let i = sampleTimes.firstIndex(where: { $0 >= pts }) ?? nextIndex
            nextIndex = i + 1
            if i == index {
                cache = (index, pb)
                return pb
            }
            if i > index { break }
        }
        if let r = reader, r.status == .failed { throw VideoFileError.readerFailed(String(describing: r.error)) }
        throw VideoFileError.readerFailed("frame \(index) not delivered")
    }
}
