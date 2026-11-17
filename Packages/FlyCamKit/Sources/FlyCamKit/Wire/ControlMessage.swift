// Control channel messages (docs/protocol.md 3.1-3.2).

import Foundation

public struct VideoFormat: Equatable, Sendable, Codable {
    public var width: Int
    public var height: Int
    public var fps: Double

    public init(width: Int, height: Int, fps: Double) {
        self.width = width
        self.height = height
        self.fps = fps
    }
}

public enum ControlMessage: Equatable, Sendable {
    public struct Hello: Equatable, Sendable, Codable {
        public var protocolVersion: Int
        public var deviceID: String
        public var deviceModel: String
        public var osVersion: String
        public var videoFormat: VideoFormat

        public init(protocolVersion: Int = 1, deviceID: String, deviceModel: String, osVersion: String, videoFormat: VideoFormat) {
            self.protocolVersion = protocolVersion
            self.deviceID = deviceID
            self.deviceModel = deviceModel
            self.osVersion = osVersion
            self.videoFormat = videoFormat
        }

        enum CodingKeys: String, CodingKey {
            case protocolVersion = "protocol_version", deviceID = "device_id", deviceModel = "device_model"
            case osVersion = "os_version", videoFormat = "video_format"
        }
    }

    public struct HelloAck: Equatable, Sendable, Codable {
        public var protocolVersion: Int
        public var cameraID: Int

        public init(protocolVersion: Int = 1, cameraID: Int) {
            self.protocolVersion = protocolVersion
            self.cameraID = cameraID
        }

        enum CodingKeys: String, CodingKey {
            case protocolVersion = "protocol_version", cameraID = "camera_id"
        }
    }

    public struct Ping: Equatable, Sendable, Codable {
        public var seq: Int
        public var t1: Double

        public init(seq: Int, t1: Double) {
            self.seq = seq
            self.t1 = t1
        }
    }

    public struct Pong: Equatable, Sendable, Codable {
        public var seq: Int
        public var t1: Double
        public var t2: Double
        public var t3: Double

        public init(seq: Int, t1: Double, t2: Double, t3: Double) {
            self.seq = seq
            self.t1 = t1
            self.t2 = t2
            self.t3 = t3
        }
    }

    public struct Status: Equatable, Sendable, Codable {
        public var battery: Double
        public var thermalState: String
        public var tracking: TrackingState
        public var fps: Double
        public var recording: Bool

        public init(battery: Double, thermalState: String, tracking: TrackingState, fps: Double, recording: Bool) {
            self.battery = battery
            self.thermalState = thermalState
            self.tracking = tracking
            self.fps = fps
            self.recording = recording
        }

        enum CodingKeys: String, CodingKey {
            case battery, thermalState = "thermal_state", tracking, fps, recording
        }
    }

    public struct Ack: Equatable, Sendable, Codable {
        public var ref: String
        public var ok: Bool
        public var message: String?

        public init(ref: String, ok: Bool, message: String? = nil) {
            self.ref = ref
            self.ok = ok
            self.message = message
        }
    }

    public struct SetCameraSettings: Equatable, Sendable, Codable {
        public var lock: Bool
        public var iso: Double?
        public var shutter: Double?
        public var wbTemperature: Double?
        public var wbTint: Double?

        public init(lock: Bool, iso: Double? = nil, shutter: Double? = nil, wbTemperature: Double? = nil, wbTint: Double? = nil) {
            self.lock = lock
            self.iso = iso
            self.shutter = shutter
            self.wbTemperature = wbTemperature
            self.wbTint = wbTint
        }

        enum CodingKeys: String, CodingKey {
            case lock, iso, shutter, wbTemperature = "wb_temperature", wbTint = "wb_tint"
        }
    }

    public struct StartRecording: Equatable, Sendable, Codable {
        public var sessionName: String
        public var clockOffset: Double

        public init(sessionName: String, clockOffset: Double) {
            self.sessionName = sessionName
            self.clockOffset = clockOffset
        }

        enum CodingKeys: String, CodingKey {
            case sessionName = "session_name", clockOffset = "clock_offset"
        }
    }

    case hello(Hello)
    case helloAck(HelloAck)
    case ping(Ping)
    case pong(Pong)
    case status(Status)
    case ack(Ack)
    case setCameraSettings(SetCameraSettings)
    case startRecording(StartRecording)
    case stopRecording
    /// A message with a `type` this version does not know. Receivers log and skip it.
    case unknown(type: String)

    public var type: String {
        switch self {
        case .hello: return "hello"
        case .helloAck: return "hello_ack"
        case .ping: return "ping"
        case .pong: return "pong"
        case .status: return "status"
        case .ack: return "ack"
        case .setCameraSettings: return "set_camera_settings"
        case .startRecording: return "start_recording"
        case .stopRecording: return "stop_recording"
        case .unknown(let t): return t
        }
    }
}

extension ControlMessage: Codable {
    private enum TypeKey: String, CodingKey { case type }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: TypeKey.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "hello": self = .hello(try Hello(from: decoder))
        case "hello_ack": self = .helloAck(try HelloAck(from: decoder))
        case "ping": self = .ping(try Ping(from: decoder))
        case "pong": self = .pong(try Pong(from: decoder))
        case "status": self = .status(try Status(from: decoder))
        case "ack": self = .ack(try Ack(from: decoder))
        case "set_camera_settings": self = .setCameraSettings(try SetCameraSettings(from: decoder))
        case "start_recording": self = .startRecording(try StartRecording(from: decoder))
        case "stop_recording": self = .stopRecording
        default: self = .unknown(type: type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .hello(let m): try m.encode(to: encoder)
        case .helloAck(let m): try m.encode(to: encoder)
        case .ping(let m): try m.encode(to: encoder)
        case .pong(let m): try m.encode(to: encoder)
        case .status(let m): try m.encode(to: encoder)
        case .ack(let m): try m.encode(to: encoder)
        case .setCameraSettings(let m): try m.encode(to: encoder)
        case .startRecording(let m): try m.encode(to: encoder)
        case .stopRecording, .unknown: break
        }
        var c = encoder.container(keyedBy: TypeKey.self)
        try c.encode(type, forKey: .type)
    }
}

public enum ControlProtocol {
    public static let maxMessage: UInt32 = 1024 * 1024

    /// JSON body (sorted keys, deterministic) of one message.
    public static func encodeJSON(_ m: ControlMessage) throws -> [UInt8] {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return Array(try enc.encode(m))
    }

    /// Length-prefixed frame: u32 little-endian length + JSON body.
    public static func frame(_ m: ControlMessage) throws -> [UInt8] {
        let body = try encodeJSON(m)
        var w = ByteWriter(capacity: body.count + 4)
        w.writeLE(UInt32(body.count))
        w.write(body)
        return w.bytes
    }

    public static func decodeJSON(_ body: [UInt8]) throws -> ControlMessage {
        do {
            return try JSONDecoder().decode(ControlMessage.self, from: Data(body))
        } catch {
            throw WireError.invalidJSON(String(describing: error))
        }
    }
}
