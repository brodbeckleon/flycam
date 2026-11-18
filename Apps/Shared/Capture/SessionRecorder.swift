// Writes a session folder while recording (docs/protocol.md 2): clip sessions get video.mov + frames.jsonl,
// scan sessions get images/ + frames.jsonl + worldmap.bin + points.ply. meta.json is written at the end.
// Used by the CaptureApp; tested on the Mac with synthetic frames.

import Foundation
import CoreVideo
import CoreImage
import ImageIO
import FlyCamKit

public final class SessionRecorder {
    public let folder: URL
    public let kind: SessionKind
    public var deviceModel: String
    public var osVersion: String
    public var cameraID: Int?
    public var videoFormat: VideoFormat
    public var cameraSettings = CameraSettings(locked: false)
    public var floorY: Double?
    public var clockOffset: Double?
    public let created: Date

    private var video: SessionVideoWriter?
    private let frames: FramesWriter
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    public private(set) var frameCount = 0
    public private(set) var finished = false

    public init(parent: URL, kind: SessionKind, deviceModel: String, osVersion: String, videoFormat: VideoFormat,
                cameraID: Int? = nil, clockOffset: Double? = nil, folderName: String? = nil, date: Date = Date()) throws {
        created = date
        let name = folderName ?? SessionNaming.folderName(date: date, device: deviceModel) + (kind == .scan ? "_scan" : "")
        folder = parent.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if kind == .scan {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("images"), withIntermediateDirectories: true)
        }
        self.kind = kind
        self.deviceModel = deviceModel
        self.osVersion = osVersion
        self.videoFormat = videoFormat
        self.cameraID = cameraID
        self.clockOffset = clockOffset
        frames = try FramesWriter(url: folder.appendingPathComponent(SessionIO.framesFile))
    }

    /// Clip sessions: appends one video frame (`capturedImage` on the phone) and its frames.jsonl line.
    public func appendVideoFrame(_ pb: CVPixelBuffer, time: Double, c2w: Mat4, intrinsics: Intrinsics,
                                 tracking: TrackingState, iso: Double? = nil, shutter: Double? = nil) throws {
        precondition(kind == .clip, "video frames belong to clip sessions")
        if video == nil {
            video = try SessionVideoWriter(url: folder.appendingPathComponent("video.mov"),
                                           width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb),
                                           fps: videoFormat.fps)
        }
        try video!.append(pb, time: time)
        try frames.append(FrameRecord(i: frameCount, t: time, c2w: c2w, intrinsics: intrinsics, tracking: tracking,
                                      iso: iso, shutter: shutter))
        frameCount += 1
    }

    /// Scan sessions: saves `images/<i:05d>.jpg` and its frames.jsonl line.
    public func appendStill(_ pb: CVPixelBuffer, time: Double, c2w: Mat4, intrinsics: Intrinsics,
                            tracking: TrackingState, iso: Double? = nil, shutter: Double? = nil, quality: Double = 0.92) throws {
        precondition(kind == .scan, "stills belong to scan sessions")
        let url = folder.appendingPathComponent("images").appendingPathComponent(String(format: "%05d.jpg", frameCount))
        let image = CIImage(cvPixelBuffer: pb)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let jpeg = ciContext.jpegRepresentation(of: image, colorSpace: cs,
                                                      options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality]) else {
            throw SessionVideoWriterError.appendFailed("JPEG encoding of still \(frameCount)")
        }
        try jpeg.write(to: url)
        try frames.append(FrameRecord(i: frameCount, t: time, c2w: c2w, intrinsics: intrinsics, tracking: tracking,
                                      iso: iso, shutter: shutter))
        frameCount += 1
    }

    /// Finishes the video and writes meta.json, and for scans worldmap.bin and points.ply.
    @discardableResult
    public func finish(worldMap: Data? = nil, points: [ColoredPoint]? = nil) throws -> URL {
        guard !finished else { return folder }
        finished = true
        try video?.finishBlocking()
        try frames.close()
        if let w = worldMap { try w.write(to: folder.appendingPathComponent("worldmap.bin")) }
        if let p = points { try PointCloudPLY.encode(p).write(to: folder.appendingPathComponent("points.ply")) }
        let meta = SessionMeta(kind: kind, deviceModel: deviceModel, osVersion: osVersion, cameraID: cameraID,
                               videoFormat: videoFormat, cameraSettings: cameraSettings, floorY: floorY,
                               clockOffset: clockOffset, created: SessionNaming.iso8601(created))
        try SessionIO.encodeMeta(meta).write(to: folder.appendingPathComponent(SessionIO.metaFile))
        return folder
    }
}
