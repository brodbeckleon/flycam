// Session folder reading and writing (docs/protocol.md section 2).
// Video and images are not handled here (they need AVFoundation / ImageIO on the device).

import Foundation

public struct CameraSettings: Equatable, Sendable, Codable {
    public var locked: Bool
    public var iso: Double?
    public var shutter: Double?
    public var wbTemperature: Double?
    public var wbTint: Double?

    public init(locked: Bool, iso: Double? = nil, shutter: Double? = nil, wbTemperature: Double? = nil, wbTint: Double? = nil) {
        self.locked = locked
        self.iso = iso
        self.shutter = shutter
        self.wbTemperature = wbTemperature
        self.wbTint = wbTint
    }

    enum CodingKeys: String, CodingKey {
        case locked, iso, shutter, wbTemperature = "wb_temperature", wbTint = "wb_tint"
    }
}

public enum SessionKind: String, Sendable, Codable {
    case scan
    case clip
}

public struct SessionMeta: Equatable, Sendable, Codable {
    public var formatVersion: Int
    public var kind: SessionKind
    public var deviceModel: String
    public var osVersion: String
    public var cameraID: Int?
    public var videoFormat: VideoFormat
    public var cameraSettings: CameraSettings
    public var floorY: Double?
    public var clockOffset: Double?
    public var created: String

    public init(formatVersion: Int = 1, kind: SessionKind, deviceModel: String, osVersion: String, cameraID: Int?,
                videoFormat: VideoFormat, cameraSettings: CameraSettings, floorY: Double?, clockOffset: Double?, created: String) {
        self.formatVersion = formatVersion
        self.kind = kind
        self.deviceModel = deviceModel
        self.osVersion = osVersion
        self.cameraID = cameraID
        self.videoFormat = videoFormat
        self.cameraSettings = cameraSettings
        self.floorY = floorY
        self.clockOffset = clockOffset
        self.created = created
    }

    enum CodingKeys: String, CodingKey {
        case formatVersion = "format_version", kind, deviceModel = "device_model", osVersion = "os_version"
        case cameraID = "camera_id", videoFormat = "video_format", cameraSettings = "camera_settings"
        case floorY = "floor_y", clockOffset = "clock_offset", created
    }

    public func encode(to encoder: Encoder) throws {
        // Explicit nulls for optional top-level values, as documented.
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(formatVersion, forKey: .formatVersion)
        try c.encode(kind, forKey: .kind)
        try c.encode(deviceModel, forKey: .deviceModel)
        try c.encode(osVersion, forKey: .osVersion)
        try c.encode(cameraID, forKey: .cameraID)
        try c.encode(videoFormat, forKey: .videoFormat)
        try c.encode(cameraSettings, forKey: .cameraSettings)
        try c.encode(floorY, forKey: .floorY)
        try c.encode(clockOffset, forKey: .clockOffset)
        try c.encode(created, forKey: .created)
    }
}

/// One line of frames.jsonl.
public struct FrameRecord: Equatable, Sendable, Codable {
    public var i: Int
    public var t: Double
    /// Camera-to-world, column-major.
    public var c2w: [Double]
    public var fx: Double
    public var fy: Double
    public var cx: Double
    public var cy: Double
    public var w: Int
    public var h: Int
    public var tracking: TrackingState
    public var iso: Double?
    public var shutter: Double?

    public init(i: Int, t: Double, c2w: Mat4, intrinsics k: Intrinsics, tracking: TrackingState,
                iso: Double? = nil, shutter: Double? = nil) {
        self.i = i
        self.t = t
        self.c2w = c2w.columnMajor
        fx = k.fx
        fy = k.fy
        cx = k.cx
        cy = k.cy
        w = k.width
        h = k.height
        self.tracking = tracking
        self.iso = iso
        self.shutter = shutter
    }

    public var c2wMatrix: Mat4 { Mat4(columnMajor: c2w) }
    public var intrinsics: Intrinsics { Intrinsics(fx: fx, fy: fy, cx: cx, cy: cy, width: w, height: h) }
    public var camera: PinholeCamera { PinholeCamera(intrinsics: intrinsics, c2w: c2wMatrix) }

    /// Packet header for this frame (float32 on the wire).
    public func packetHeader(cameraID: UInt16, keyframe: Bool, hasParameterSets: Bool, payloadLength: UInt32 = 0) -> MediaPacketHeader {
        MediaPacketHeader(cameraID: cameraID, frameIndex: UInt32(i), timestamp: t, c2w: c2w.map(Float.init),
                          fx: Float(fx), fy: Float(fy), cx: Float(cx), cy: Float(cy),
                          width: UInt16(w), height: UInt16(h), keyframe: keyframe, tracking: tracking,
                          hasParameterSets: hasParameterSets, payloadLength: payloadLength)
    }
}

public struct PoseOverride: Equatable, Sendable, Codable {
    public var formatVersion: Int
    public var c2w: [Double]
    public var source: String
    public var frameIndex: Int?
    public var inliers: Int?
    public var medianReprojectionPx: Double?
    public var created: String?

    enum CodingKeys: String, CodingKey {
        case formatVersion = "format_version", c2w, source, frameIndex = "frame_index", inliers
        case medianReprojectionPx = "median_reprojection_px", created
    }
}

public enum SessionError: Error, Equatable {
    case invalidLine(Int, String)
    case invalidMatrix(Int)
}

public enum SessionIO {
    public static let metaFile = "meta.json"
    public static let framesFile = "frames.jsonl"
    public static let poseOverrideFile = "pose_override.json"

    public static func decodeFrames(_ data: Data) throws -> [FrameRecord] {
        let dec = JSONDecoder()
        var out = [FrameRecord]()
        var lineNo = 0
        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
            lineNo += 1
            if line.allSatisfy({ $0 == 32 || $0 == 13 || $0 == 9 }) { continue }
            do {
                let r = try dec.decode(FrameRecord.self, from: Data(line))
                guard r.c2w.count == 16 else { throw SessionError.invalidMatrix(lineNo) }
                out.append(r)
            } catch let e as SessionError {
                throw e
            } catch {
                throw SessionError.invalidLine(lineNo, String(describing: error))
            }
        }
        return out
    }

    public static func encodeFrames(_ frames: [FrameRecord]) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var out = Data()
        for f in frames {
            out.append(try enc.encode(f))
            out.append(UInt8(ascii: "\n"))
        }
        return out
    }

    public static func encodeMeta(_ meta: SessionMeta) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        var d = try enc.encode(meta)
        d.append(UInt8(ascii: "\n"))
        return d
    }

    public static func decodeMeta(_ data: Data) throws -> SessionMeta {
        try JSONDecoder().decode(SessionMeta.self, from: data)
    }

    public static func readMeta(_ dir: URL) throws -> SessionMeta {
        try decodeMeta(Data(contentsOf: dir.appendingPathComponent(metaFile)))
    }

    public static func readFrames(_ dir: URL) throws -> [FrameRecord] {
        try decodeFrames(Data(contentsOf: dir.appendingPathComponent(framesFile)))
    }

    public static func readPoseOverride(_ dir: URL) throws -> PoseOverride? {
        let url = dir.appendingPathComponent(poseOverrideFile)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(PoseOverride.self, from: Data(contentsOf: url))
    }

    public static func write(meta: SessionMeta, frames: [FrameRecord], to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encodeMeta(meta).write(to: dir.appendingPathComponent(metaFile))
        try encodeFrames(frames).write(to: dir.appendingPathComponent(framesFile))
    }
}

/// Appends frames.jsonl line by line while recording. Each line is flushed on append,
/// so an interrupted recording keeps every completed line.
public final class FramesWriter {
    private let handle: FileHandle
    private let encoder: JSONEncoder
    public private(set) var count = 0

    public init(url: URL) throws {
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    public func append(_ f: FrameRecord) throws {
        var d = try encoder.encode(f)
        d.append(UInt8(ascii: "\n"))
        try handle.write(contentsOf: d)
        count += 1
    }

    public func close() throws {
        try handle.close()
    }
}

/// Checks from Tools/inspect_session.py that do not need the video.
public struct SessionValidation: Equatable, Sendable {
    public var problems: [String] = []
    public var isValid: Bool { problems.isEmpty }

    public static func validate(_ frames: [FrameRecord], rigidTolerance: Double = 1e-4) -> SessionValidation {
        var v = SessionValidation()
        for (n, f) in frames.enumerated() {
            if f.i != n { v.problems.append("frame \(n): index \(f.i), expected \(n)") }
            if n > 0 && !(f.t > frames[n - 1].t) { v.problems.append("frame \(n): timestamp not increasing") }
            if f.c2wMatrix.rigidityError > rigidTolerance { v.problems.append("frame \(n): c2w is not rigid") }
            if !(f.fx > 0 && f.fy > 0 && f.w > 0 && f.h > 0) { v.problems.append("frame \(n): invalid intrinsics") }
        }
        return v
    }
}
