// Media channel packet codec (docs/protocol.md 3.3).

import Foundation

public enum TrackingState: String, Sendable, Codable, CaseIterable {
    case notAvailable
    case limited
    case normal

    public var wireValue: UInt16 {
        switch self {
        case .notAvailable: return 0
        case .limited: return 1
        case .normal: return 2
        }
    }

    public init?(wireValue: UInt16) {
        switch wireValue {
        case 0: self = .notAvailable
        case 1: self = .limited
        case 2: self = .normal
        default: return nil
        }
    }
}

public enum WireError: Error, Equatable {
    case badMagic([UInt8])
    case unsupportedVersion(UInt16)
    case payloadTooLarge(UInt32)
    case invalidTrackingState(UInt16)
    case badPreamble([UInt8])
    case messageTooLarge(UInt32)
    case emptyMessage
    case invalidNALLength
    case invalidJSON(String)
    case truncated
}

public enum MediaProtocol {
    public static let magic: [UInt8] = Array("FCAM".utf8)
    public static let version: UInt16 = 1
    public static let headerSize = 110
    public static let maxPayload: UInt32 = 16 * 1024 * 1024
}

public struct MediaPacketHeader: Equatable, Sendable {
    public var version: UInt16 = MediaProtocol.version
    public var cameraID: UInt16
    public var frameIndex: UInt32
    /// Capture time on the phone clock, seconds.
    public var timestamp: Double
    /// Camera-to-world, column-major, float32 on the wire.
    public var c2w: [Float]
    public var fx: Float
    public var fy: Float
    public var cx: Float
    public var cy: Float
    public var width: UInt16
    public var height: UInt16
    public var keyframe: Bool
    public var tracking: TrackingState
    public var hasParameterSets: Bool
    public var payloadLength: UInt32

    public init(cameraID: UInt16, frameIndex: UInt32, timestamp: Double, c2w: [Float],
                fx: Float, fy: Float, cx: Float, cy: Float, width: UInt16, height: UInt16,
                keyframe: Bool, tracking: TrackingState, hasParameterSets: Bool, payloadLength: UInt32) {
        precondition(c2w.count == 16, "c2w needs 16 values")
        self.cameraID = cameraID
        self.frameIndex = frameIndex
        self.timestamp = timestamp
        self.c2w = c2w
        self.fx = fx
        self.fy = fy
        self.cx = cx
        self.cy = cy
        self.width = width
        self.height = height
        self.keyframe = keyframe
        self.tracking = tracking
        self.hasParameterSets = hasParameterSets
        self.payloadLength = payloadLength
    }

    public var flags: UInt16 {
        var f: UInt16 = 0
        if keyframe { f |= 1 }
        f |= tracking.wireValue << 1
        if hasParameterSets { f |= 1 << 3 }
        return f
    }

    public var c2wMatrix: Mat4 { Mat4(columnMajor: c2w.map(Double.init)) }

    public var intrinsics: Intrinsics {
        Intrinsics(fx: Double(fx), fy: Double(fy), cx: Double(cx), cy: Double(cy), width: Int(width), height: Int(height))
    }

    public func encode() -> [UInt8] {
        var w = ByteWriter(capacity: MediaProtocol.headerSize)
        w.write(MediaProtocol.magic)
        w.writeLE(version)
        w.writeLE(cameraID)
        w.writeLE(frameIndex)
        w.writeF64(timestamp)
        for v in c2w { w.writeF32(v) }
        w.writeF32(fx)
        w.writeF32(fy)
        w.writeF32(cx)
        w.writeF32(cy)
        w.writeLE(width)
        w.writeLE(height)
        w.writeLE(flags)
        w.writeLE(payloadLength)
        assert(w.bytes.count == MediaProtocol.headerSize)
        return w.bytes
    }

    public static func decode(_ bytes: [UInt8]) throws -> MediaPacketHeader {
        var r = ByteReader(bytes)
        return try decode(&r)
    }

    public static func decode(_ r: inout ByteReader) throws -> MediaPacketHeader {
        guard r.remaining >= MediaProtocol.headerSize else { throw WireError.truncated }
        let magic = try r.read(count: 4)
        guard magic == MediaProtocol.magic else { throw WireError.badMagic(magic) }
        let version = try r.readLE(UInt16.self)
        guard version == MediaProtocol.version else { throw WireError.unsupportedVersion(version) }
        let cameraID = try r.readLE(UInt16.self)
        let frameIndex = try r.readLE(UInt32.self)
        let timestamp = try r.readF64()
        var c2w = [Float]()
        c2w.reserveCapacity(16)
        for _ in 0..<16 { c2w.append(try r.readF32()) }
        let fx = try r.readF32(), fy = try r.readF32(), cx = try r.readF32(), cy = try r.readF32()
        let width = try r.readLE(UInt16.self)
        let height = try r.readLE(UInt16.self)
        let flags = try r.readLE(UInt16.self)
        let payloadLength = try r.readLE(UInt32.self)
        guard payloadLength <= MediaProtocol.maxPayload else { throw WireError.payloadTooLarge(payloadLength) }
        let trackingBits = (flags >> 1) & 0x3
        guard let tracking = TrackingState(wireValue: trackingBits) else { throw WireError.invalidTrackingState(trackingBits) }
        return MediaPacketHeader(cameraID: cameraID, frameIndex: frameIndex, timestamp: timestamp, c2w: c2w,
                                 fx: fx, fy: fy, cx: cx, cy: cy, width: width, height: height,
                                 keyframe: flags & 1 != 0, tracking: tracking,
                                 hasParameterSets: flags & (1 << 3) != 0, payloadLength: payloadLength)
    }
}

public struct MediaPacket: Equatable, Sendable {
    public var header: MediaPacketHeader
    public var payload: [UInt8]

    /// Builds a packet; `header.payloadLength` is set from `payload`.
    public init(header: MediaPacketHeader, payload: [UInt8]) {
        var h = header
        h.payloadLength = UInt32(payload.count)
        self.header = h
        self.payload = payload
    }

    public func encode() -> [UInt8] {
        header.encode() + payload
    }

    public static func decode(_ bytes: [UInt8]) throws -> MediaPacket {
        var r = ByteReader(bytes)
        let h = try MediaPacketHeader.decode(&r)
        guard r.remaining >= Int(h.payloadLength) else { throw WireError.truncated }
        return MediaPacket(header: h, payload: try r.read(count: Int(h.payloadLength)))
    }
}

/// HEVC access unit helpers: payload = NAL units, each with a 4-byte big-endian length.
public enum HEVCPayload {
    public static func join(nalUnits: [[UInt8]]) -> [UInt8] {
        var w = ByteWriter()
        for n in nalUnits {
            w.writeBE(UInt32(n.count))
            w.write(n)
        }
        return w.bytes
    }

    public static func split(_ payload: [UInt8]) throws -> [[UInt8]] {
        var r = ByteReader(payload)
        var out = [[UInt8]]()
        while r.remaining > 0 {
            guard r.remaining >= 4 else { throw WireError.invalidNALLength }
            let n = Int(try r.readBE(UInt32.self))
            guard n > 0, n <= r.remaining else { throw WireError.invalidNALLength }
            out.append(try r.read(count: n))
        }
        return out
    }

    /// HEVC nal_unit_type (ITU-T H.265 7.3.1.2).
    public static func nalType(_ nal: [UInt8]) -> Int? {
        guard let first = nal.first else { return nil }
        return Int((first >> 1) & 0x3f)
    }

    /// True when the first NAL units are VPS (32), SPS (33) and PPS (34).
    public static func startsWithParameterSets(_ payload: [UInt8]) -> Bool {
        guard let nals = try? split(payload), nals.count >= 3 else { return false }
        return nals.prefix(3).compactMap(nalType) == [32, 33, 34]
    }
}
