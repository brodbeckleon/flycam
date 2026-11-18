// Phone-side logic without ARKit, so it is unit-tested on the Mac (DirectorCoreTests/CaptureLogicTests).

import Foundation
import simd
import FlyCamKit

// MARK: - ARKit conversions (plan.md section 5)

public enum ARConvert {
    /// `ARCamera.transform` (c2w, column-major simd) to FlyCamKit.
    public static func c2w(_ m: simd_float4x4) -> Mat4 {
        var v = [Double]()
        v.reserveCapacity(16)
        for c in 0..<4 { for r in 0..<4 { v.append(Double(m[c][r])) } }
        return Mat4(columnMajor: v)
    }

    /// `ARCamera.intrinsics` (column-major 3x3: fx = K[0][0], fy = K[1][1], cx = K[2][0], cy = K[2][1])
    /// for `ARCamera.imageResolution`.
    public static func intrinsics(_ k: simd_float3x3, width: Int, height: Int) -> Intrinsics {
        Intrinsics(fx: Double(k[0][0]), fy: Double(k[1][1]), cx: Double(k[2][0]), cy: Double(k[2][1]),
                   width: width, height: height)
    }
}

// MARK: - Scan keyframes (plan.md Phase 1, scan mode)

/// Saves a still when the camera has moved at least 10 cm or turned at least 8 degrees since the last saved
/// still, and skips frames taken during fast rotation (motion blur).
public struct ScanKeyframeSelector: Sendable {
    public var minTranslation: Double = 0.10
    public var minRotationDegrees: Double = 8
    /// Frames with an angular speed above this (degrees per second, from the previous frame) are skipped.
    public var maxAngularSpeedDegrees: Double = 30
    /// Only frames with normal tracking are saved.
    public var requireNormalTracking = true

    private var lastSaved: Mat4?
    private var previous: (t: Double, c2w: Mat4)?
    public private(set) var savedCount = 0

    public init() {}

    public static func rotationDegrees(_ a: Mat4, _ b: Mat4) -> Double {
        Quat(a.rotation).angle(to: Quat(b.rotation)) * 180 / .pi
    }

    /// Feeds every frame; returns true when this frame should be saved as a scan still.
    public mutating func shouldSave(time t: Double, c2w: Mat4, tracking: TrackingState) -> Bool {
        defer { previous = (t, c2w) }
        if requireNormalTracking && tracking != .normal { return false }
        if let p = previous, t > p.t {
            let speed = Self.rotationDegrees(p.c2w, c2w) / (t - p.t)
            if speed > maxAngularSpeedDegrees { return false }
        }
        guard let last = lastSaved else {
            lastSaved = c2w
            savedCount += 1
            return true
        }
        let moved = (c2w.translation - last.translation).length
        let turned = Self.rotationDegrees(last, c2w)
        guard moved >= minTranslation || turned >= minRotationDegrees else { return false }
        lastSaved = c2w
        savedCount += 1
        return true
    }
}

// MARK: - Floor height (plan.md Phase 1, scan mode)

public struct PlaneObservation: Sendable, Equatable {
    public var identifier: UUID
    /// World Y of the plane (horizontal planes only).
    public var y: Double
    /// Extent area in square metres.
    public var area: Double
    /// ARKit classified it as floor.
    public var isFloor: Bool

    public init(identifier: UUID = UUID(), y: Double, area: Double, isFloor: Bool) {
        self.identifier = identifier
        self.y = y
        self.area = area
        self.isFloor = isFloor
    }
}

public enum FloorEstimator {
    /// Y of the largest plane classified as floor. Without a classified floor (classification needs a
    /// supported device), the largest horizontal plane at least `minDepthBelowCamera` below the lowest camera.
    public static func floorY(planes: [PlaneObservation], lowestCameraY: Double? = nil, minDepthBelowCamera: Double = 0.5) -> Double? {
        if let f = planes.filter(\.isFloor).max(by: { $0.area < $1.area }) { return f.y }
        let candidates = planes.filter { p in lowestCameraY.map { p.y <= $0 - minDepthBelowCamera } ?? true }
        return candidates.max(by: { $0.area < $1.area })?.y
    }
}

// MARK: - points.ply (docs/protocol.md 2.4)

public struct ColoredPoint: Sendable, Equatable {
    public var position: SIMD3<Float>
    public var color: SIMD3<UInt8>
    public init(position: SIMD3<Float>, color: SIMD3<UInt8>) {
        self.position = position
        self.color = color
    }
}

public enum PointCloudPLY {
    /// Binary little-endian PLY, element vertex with float x, y, z and uchar red, green, blue.
    public static func encode(_ points: [ColoredPoint]) -> Data {
        var d = Data(("ply\nformat binary_little_endian 1.0\nelement vertex \(points.count)\n"
                      + "property float x\nproperty float y\nproperty float z\n"
                      + "property uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n").utf8)
        d.reserveCapacity(d.count + points.count * 15)
        for p in points {
            for v in [p.position.x, p.position.y, p.position.z] {
                withUnsafeBytes(of: v.bitPattern.littleEndian) { d.append(contentsOf: $0) }
            }
            d.append(contentsOf: [p.color.x, p.color.y, p.color.z])
        }
        return d
    }

    public static func decode(_ data: Data) throws -> [ColoredPoint] {
        guard let range = data.range(of: Data("end_header\n".utf8)) else { throw WireError.truncated }
        let header = String(decoding: data[..<range.lowerBound], as: UTF8.self)
        guard header.contains("format binary_little_endian 1.0"),
              let line = header.split(separator: "\n").first(where: { $0.hasPrefix("element vertex ") }),
              let n = Int(line.split(separator: " ")[2]) else { throw WireError.truncated }
        let body = data[range.upperBound...]
        guard body.count >= n * 15 else { throw WireError.truncated }
        var out = [ColoredPoint]()
        out.reserveCapacity(n)
        let bytes = [UInt8](body)
        for i in 0..<n {
            let o = i * 15
            func f(_ k: Int) -> Float {
                let b = o + 4 * k
                return Float(bitPattern: UInt32(bytes[b]) | UInt32(bytes[b + 1]) << 8 | UInt32(bytes[b + 2]) << 16 | UInt32(bytes[b + 3]) << 24)
            }
            out.append(ColoredPoint(position: SIMD3(f(0), f(1), f(2)), color: SIMD3(bytes[o + 12], bytes[o + 13], bytes[o + 14])))
        }
        return out
    }
}

// MARK: - Session naming and video format choice

public enum SessionNaming {
    /// `session_<date>_<device>` (plan.md section 8), date as yyyyMMdd-HHmmss UTC, device sanitised.
    public static func folderName(date: Date, device: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let dev = device.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return "session_\(f.string(from: date))_\(String(dev))"
    }

    public static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

public struct VideoFormatCandidate: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var fps: Int
    public init(width: Int, height: Int, fps: Int) {
        self.width = width
        self.height = height
        self.fps = fps
    }
}

public enum VideoFormatChooser {
    /// Prefers 16:9, then 60 fps, then the resolution closest to 1920x1080 (plan.md Phase 0).
    public static func choose(_ formats: [VideoFormatCandidate], preferredFPS: Int = 60) -> Int? {
        func score(_ f: VideoFormatCandidate) -> (Int, Int, Int) {
            let is169 = abs(Double(f.width) / Double(f.height) - 16.0 / 9.0) < 0.01 ? 1 : 0
            let fpsOK = f.fps == preferredFPS ? 1 : 0
            let closeness = -abs(f.width * f.height - 1920 * 1080)
            return (is169, fpsOK, closeness)
        }
        return formats.indices.max(by: { score(formats[$0]) < score(formats[$1]) })
    }
}
