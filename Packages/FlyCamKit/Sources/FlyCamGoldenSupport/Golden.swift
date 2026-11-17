// Golden files shared with Tools/ (docs/protocol.md section 6).
// `GoldenWriter.write(to:)` writes the Swift set (Tools/testdata/golden/from_swift),
// `GoldenVerifier.verify(_:)` checks any set (from Swift or from Python) against FlyCamKit.

import Foundation
import FlyCamKit

// MARK: - JSON helpers

/// JSON value parsed with JSONDecoder. JSONSerialization is not used for reading: on Linux
/// (swift-corelibs-foundation, Swift 6.4.2) it parses about half of all doubles to a neighbouring
/// value (e.g. 0.9845625162124634 -> 0.9845625162124637). JSONDecoder is correctly rounded.
enum AnyJSON: Decodable {
    case null, bool(Bool), number(Double), string(String), array([AnyJSON]), object([String: AnyJSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let d = try? c.decode(Double.self) { self = .number(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([AnyJSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: AnyJSON].self)) }
    }

    var any: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let d): return d
        case .string(let s): return s
        case .array(let a): return a.map(\.any)
        case .object(let o): return o.mapValues(\.any)
        }
    }
}

enum JSONValue {
    static func double(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let f = any as? Float { return Double(f) }
        if let n = any as? NSNumber, !(any is Bool) { return n.doubleValue }
        return nil
    }

    static func int(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double, d == d.rounded(), abs(d) < 1e15 { return Int(d) }
        return nil
    }

    static func doubles(_ any: Any?) -> [Double]? {
        guard let a = any as? [Any] else { return nil }
        let out = a.compactMap(double)
        return out.count == a.count ? out : nil
    }

    static func bool(_ any: Any?) -> Bool? {
        any as? Bool
    }

    static func write(_ obj: Any, to url: URL) throws {
        var d = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        d.append(UInt8(ascii: "\n"))
        try d.write(to: url)
    }

    static func read(_ url: URL) throws -> [String: Any] {
        guard let obj = try JSONDecoder().decode(AnyJSON.self, from: Data(contentsOf: url)).any as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return obj
    }
}

func close(_ a: [Double], _ b: [Double], tol: Double = 1e-9) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) <= tol * max(1, abs($1)) }
}

func intrinsicsJSON(_ k: Intrinsics) -> [String: Any] {
    ["fx": k.fx, "fy": k.fy, "cx": k.cx, "cy": k.cy, "width": k.width, "height": k.height]
}

func intrinsics(from d: Any?) -> Intrinsics? {
    guard let d = d as? [String: Any],
          let fx = JSONValue.double(d["fx"]), let fy = JSONValue.double(d["fy"]),
          let cx = JSONValue.double(d["cx"]), let cy = JSONValue.double(d["cy"]),
          let w = JSONValue.int(d["width"]), let h = JSONValue.int(d["height"]) else { return nil }
    return Intrinsics(fx: fx, fy: fy, cx: cx, cy: cy, width: w, height: h)
}

func configJSON(_ c: TransitionConfig) -> [String: Any] {
    ["duration": c.duration, "fade_fraction": c.fadeFraction, "floor_clearance": c.floorClearance,
     "max_interest_distance": c.maxInterestDistance, "parallel_angle": c.parallelAngle,
     "median_scene_depth": c.medianSceneDepth]
}

func config(from d: Any?) -> TransitionConfig? {
    guard let d = d as? [String: Any],
          let a = JSONValue.double(d["duration"]), let b = JSONValue.double(d["fade_fraction"]),
          let c = JSONValue.double(d["floor_clearance"]), let e = JSONValue.double(d["max_interest_distance"]),
          let f = JSONValue.double(d["parallel_angle"]), let g = JSONValue.double(d["median_scene_depth"]) else { return nil }
    return TransitionConfig(duration: a, fadeFraction: b, floorClearance: c, maxInterestDistance: e, parallelAngle: f, medianSceneDepth: g)
}

func headerJSON(_ h: MediaPacketHeader, payload: [UInt8]) -> [String: Any] {
    ["camera_id": Int(h.cameraID), "frame_index": Int(h.frameIndex), "timestamp": h.timestamp,
     "c2w": h.c2w.map(Double.init), "fx": Double(h.fx), "fy": Double(h.fy), "cx": Double(h.cx), "cy": Double(h.cy),
     "width": Int(h.width), "height": Int(h.height), "keyframe": h.keyframe, "tracking": h.tracking.rawValue,
     "has_parameter_sets": h.hasParameterSets, "payload_length": Int(h.payloadLength), "payload_hex": payload.hexString]
}

// MARK: - Shared reference content

public enum GoldenReference {
    public static let sValues: [Double] = [0, 0.1, 0.25, 0.5, 0.75, 0.9, 1]
    public static let uValues: [Double] = [0, 0.05, 0.15, 0.5, 0.9, 0.95, 1]
    public static let shutter = 0.008333333333333333

    /// The reference session. Tools/flycam_tools/golden.py `_session()` builds the same content.
    public static func session() -> (SessionMeta, [FrameRecord]) {
        let meta = SessionMeta(kind: .clip, deviceModel: "iPhone15,2", osVersion: "18.1", cameraID: 1,
                               videoFormat: VideoFormat(width: 1920, height: 1080, fps: 60),
                               cameraSettings: CameraSettings(locked: true, iso: 100, shutter: shutter, wbTemperature: 5000, wbTint: 0),
                               floorY: -1.32, clockOffset: 1234.5678, created: "2026-11-17T19:00:00Z")
        let k = Intrinsics(fx: 1500.5, fy: 1499.25, cx: 961.3, cy: 538.7, width: 1920, height: 1080)
        let frames = (0..<5).map { i in
            FrameRecord(i: i, t: 100.0 + Double(i) / 60,
                        c2w: Mat4.lookAt(eye: Vec3(0.1 * Double(i), 0, 0), target: Vec3(0, -0.5, -4)),
                        intrinsics: k, tracking: i == 0 ? .limited : .normal,
                        iso: i % 2 == 0 ? 100 : nil, shutter: shutter)
        }
        return (meta, frames)
    }
}

// MARK: - Writer

public enum GoldenWriter {
    static func packets() -> [MediaPacket] {
        // Swift's JSON encoders write -0.0 as "-0", which every reader (Swift and Python) parses as +0,
        // so a negative zero could not be rebuilt from packets.json. Normalise it here.
        func f32(_ m: Mat4) -> [Float] { m.columnMajor.map { $0 == 0 ? 0 : Float($0) } }
        let c2w0 = f32(Mat4.lookAt(eye: Vec3(-0.6, 0.3, 1.5), target: Vec3(0.2, -0.4, -3)))
        let c2w1 = f32(Mat4.lookAt(eye: Vec3(2.25, 0.05, -1.1), target: Vec3(-0.1, -0.7, -3.3)))
        let key = HEVCPayload.join(nalUnits: [[0x40, 0x01, 0x0C, 0x01, 0xFF], [0x42, 0x01, 0x01, 0x01], [0x44, 0x01, 0xC0],
                                              [0x28, 0x01, 0xAF, 0x1D, 0x10]])
        func header(_ cam: UInt16, _ i: UInt32, _ t: Double, _ c2w: [Float], _ k: (Float, Float, Float, Float), _ w: UInt16, _ h: UInt16,
                    _ key: Bool, _ tr: TrackingState) -> MediaPacketHeader {
            MediaPacketHeader(cameraID: cam, frameIndex: i, timestamp: t, c2w: c2w, fx: k.0, fy: k.1, cx: k.2, cy: k.3,
                              width: w, height: h, keyframe: key, tracking: tr, hasParameterSets: key, payloadLength: 0)
        }
        return [
            MediaPacket(header: header(3, 120, 8123.000001, c2w0, (1520.25, 1519.75, 955.5, 541.125), 1920, 1080, true, .normal), payload: key),
            MediaPacket(header: header(3, 121, 8123.016668, c2w0, (1520.25, 1519.75, 955.5, 541.125), 1920, 1080, false, .normal),
                        payload: HEVCPayload.join(nalUnits: [[0x02, 0x01, 0xE0, 0x44], [0x02, 0x01, 0x10]])),
            MediaPacket(header: header(1, 0, 0.0, c2w1, (660.5, 660.5, 383.25, 215.75), 768, 432, false, .limited), payload: []),
        ]
    }

    static func control() -> [ControlMessage] {
        [
            .hello(.init(deviceID: "SWIFT-01", deviceModel: "iPhone16,1", osVersion: "18.2", videoFormat: .init(width: 1920, height: 1440, fps: 30))),
            .helloAck(.init(cameraID: 0)),
            .ping(.init(seq: 1, t1: 77.125)),
            .pong(.init(seq: 1, t1: 77.125, t2: 9001.25, t3: 9001.2505)),
            .status(.init(battery: 0.55, thermalState: "serious", tracking: .normal, fps: 29.97, recording: true)),
            .ack(.init(ref: "start_recording", ok: true)),
            .setCameraSettings(.init(lock: true, iso: 64, shutter: 0.004, wbTemperature: nil, wbTint: nil)),
            .startRecording(.init(sessionName: "session_swift", clockOffset: 321.0625)),
            .stopRecording,
        ]
    }

    static func cameraCases() -> [[String: Any]] {
        let cases: [(Intrinsics, Mat4)] = [
            (Intrinsics(fx: 1480, fy: 1481.5, cx: 958.25, cy: 541.5, width: 1920, height: 1080),
             Mat4.lookAt(eye: Vec3(0.5, -0.2, 2), target: Vec3(-1, -0.8, -3))),
            (Intrinsics(fx: 600, fy: 600, cx: 320.5, cy: 240.5, width: 640, height: 480),
             Mat4.lookAt(eye: Vec3(-3, 1, -1), target: Vec3(0, 0, -5), up: Vec3(0.1, 1, 0))),
        ]
        return cases.map { k, c2w in
            let cam = PinholeCamera(intrinsics: k, c2w: c2w)
            let pts: [[String: Any]] = [(0.0, 0.0, 0.5), (12.5, 400.25, 3.0), (k.cx, k.cy, 7.0), (Double(k.width) - 0.5, 1.0, 20.0)].map { u, v, z in
                ["u": u, "v": v, "depth": z, "world": cam.unproject(u: u, v: v, depth: z).array]
            }
            return ["intrinsics": intrinsicsJSON(k), "c2w": c2w.columnMajor, "near": 0.1, "far": 100.0,
                    "projection": cam.projectionMatrix(near: 0.1, far: 100).columnMajor, "points": pts]
        }
    }

    static func transitionInputs() -> [(String, PinholeCamera, PinholeCamera, Double?, TransitionConfig)] {
        let k = Intrinsics(fx: 1400, fy: 1400, cx: 950, cy: 545, width: 1920, height: 1080)
        let kWide = Intrinsics(fx: 900, fy: 900, cx: 960, cy: 540, width: 1920, height: 1080)
        let kSmall = Intrinsics(fx: 700, fy: 700, cx: 479.5, cy: 269.5, width: 960, height: 540)
        let subject = Vec3(0.5, -0.3, -3.5)
        return [
            ("orbit_left", PinholeCamera(intrinsics: k, c2w: .lookAt(eye: Vec3(-2.5, 0.1, -0.5), target: subject)),
             PinholeCamera(intrinsics: kWide, c2w: .lookAt(eye: Vec3(2, 0.4, 0), target: subject)), -1.3, TransitionConfig()),
            ("resolution_change", PinholeCamera(intrinsics: k, c2w: .lookAt(eye: Vec3(-2.5, 0.1, -0.5), target: subject)),
             PinholeCamera(intrinsics: kSmall, c2w: .lookAt(eye: Vec3(1, 0.0, 0.5), target: Vec3(0, -0.5, -4))), nil, TransitionConfig()),
            ("too_far", PinholeCamera(intrinsics: k, c2w: .identity),
             PinholeCamera(intrinsics: k, c2w: .lookAt(eye: Vec3(1, 0, 0), target: Vec3(0, 0, -40))), nil,
             TransitionConfig(duration: 2, fadeFraction: 0.2, medianSceneDepth: 4)),
            ("antiparallel_orbit", PinholeCamera(intrinsics: k, c2w: .lookAt(eye: Vec3(0, 0, 0), target: Vec3(0, 0, -4))),
             PinholeCamera(intrinsics: k, c2w: .lookAt(eye: Vec3(0, 0, -8), target: Vec3(0, 0, -4))), -1.3, TransitionConfig()),
        ]
    }

    static func transitionCase(_ inp: (String, PinholeCamera, PinholeCamera, Double?, TransitionConfig)) -> [String: Any] {
        let (name, a, b, floorY, cfg) = inp
        let path = TransitionPath(from: a, to: b, floorY: floorY, config: cfg)
        let samples: [[String: Any]] = GoldenReference.sValues.map { s in
            let c = path.camera(atProgress: s)
            return ["s": s, "c2w": c.c2w.columnMajor, "fx": c.intrinsics.fx, "fy": c.intrinsics.fy,
                    "cx": c.intrinsics.cx, "cy": c.intrinsics.cy]
        }
        let blend: [[String: Any]] = GoldenReference.uValues.map { u in
            let w = TransitionPath.blendWeights(timeFraction: u, fadeFraction: cfg.fadeFraction)
            return ["u": u, "video_a": w.videoA, "render": w.render, "video_b": w.videoB]
        }
        let progress: [[String: Any]] = [0, 0.25, 0.5, 1.0, 1.5].map { f in
            let t = f * cfg.duration
            return ["t": t, "s": path.progress(atTime: t)]
        }
        return ["name": name,
                "a": ["intrinsics": intrinsicsJSON(a.intrinsics), "c2w": a.c2w.columnMajor],
                "b": ["intrinsics": intrinsicsJSON(b.intrinsics), "c2w": b.c2w.columnMajor],
                "floor_y": floorY.map { $0 as Any } ?? NSNull(), "config": configJSON(cfg),
                "interest_point": path.interestPoint.array, "method": path.interestMethod.rawValue,
                "samples": samples, "blend": blend, "progress": progress]
    }

    static func clock() -> [String: Any] {
        // Deterministic delays (no shared RNG with Python): a few slow samples, one fast one.
        let trueOffset = -8765.4321
        let ups = [0.004, 0.011, 0.0025, 0.03, 0.006, 0.0021, 0.009, 0.05, 0.0045]
        let downs = [0.005, 0.002, 0.0031, 0.004, 0.02, 0.0022, 0.003, 0.004, 0.0105]
        var samples = [ClockSample]()
        for i in 0..<ups.count {
            let t1 = 10.0 + Double(i)
            let t2 = t1 + ups[i] - trueOffset
            let t3 = t2 + 0.0005
            samples.append(ClockSample(t1: t1, t2: t2, t3: t3, t4: t3 + trueOffset + downs[i]))
        }
        var est = ClockOffsetEstimator(window: 6)
        for s in samples { est.add(s) }
        return ["window": 6,
                "samples": samples.map { ["t1": $0.t1, "t2": $0.t2, "t3": $0.t3, "t4": $0.t4] },
                "offsets": samples.map(\.offset), "round_trips": samples.map(\.roundTrip),
                "estimate": est.offset!, "uncertainty": est.uncertainty!]
    }

    public static func write(to dir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("session"), withIntermediateDirectories: true)

        let pk = packets()
        try Data(Channel.media.preamble + pk.flatMap { $0.encode() }).write(to: dir.appendingPathComponent("packets.bin"))
        try JSONValue.write(["packets": pk.map { headerJSON($0.header, payload: $0.payload) }], to: dir.appendingPathComponent("packets.json"))

        let msgs = control()
        try Data(Channel.control.preamble + msgs.flatMap { try! ControlProtocol.frame($0) }).write(to: dir.appendingPathComponent("control.bin"))
        let msgObjs = try msgs.map { try JSONSerialization.jsonObject(with: Data(ControlProtocol.encodeJSON($0))) }
        try JSONValue.write(["messages": msgObjs], to: dir.appendingPathComponent("control.json"))

        let (meta, frames) = GoldenReference.session()
        try SessionIO.encodeMeta(meta).write(to: dir.appendingPathComponent("session/meta.json"))
        try SessionIO.encodeFrames(frames).write(to: dir.appendingPathComponent("session/frames.jsonl"))

        try JSONValue.write(["cases": cameraCases()], to: dir.appendingPathComponent("camera.json"))
        try JSONValue.write(["cases": transitionInputs().map(transitionCase)], to: dir.appendingPathComponent("transition.json"))
        try JSONValue.write(clock(), to: dir.appendingPathComponent("clock.json"))
    }
}

// MARK: - Verifier

public enum GoldenVerifier {
    public static func verify(_ dir: URL) -> [String] {
        var problems = [String]()
        func check(_ ok: Bool, _ msg: @autoclosure () -> String) {
            if !ok { problems.append(msg()) }
        }
        do {
            // Packets: decode, compare with packets.json, re-encode byte for byte.
            let raw = Array(try Data(contentsOf: dir.appendingPathComponent("packets.bin")))
            var pre = PreambleReader()
            guard let (ch, rest) = try pre.feed(raw), ch == .media else { return ["packets.bin: bad preamble"] }
            var parser = MediaStreamParser()
            let decoded = try parser.feed(rest)
            let expected = try JSONValue.read(dir.appendingPathComponent("packets.json"))["packets"] as? [[String: Any]] ?? []
            check(decoded.count == expected.count, "packets: \(decoded.count) decoded, \(expected.count) expected")
            var rebuilt = Channel.media.preamble
            for (k, (p, e)) in zip(decoded, expected).enumerated() {
                let got = headerJSON(p.header, payload: p.payload)
                for key in ["camera_id", "frame_index", "width", "height", "payload_length"] {
                    check(JSONValue.int(got[key]) == JSONValue.int(e[key]), "packet \(k): \(key) differs")
                }
                for key in ["timestamp", "fx", "fy", "cx", "cy"] {
                    check(JSONValue.double(got[key]) == JSONValue.double(e[key]), "packet \(k): \(key) differs")
                }
                check(JSONValue.doubles(got["c2w"]) == JSONValue.doubles(e["c2w"]), "packet \(k): c2w differs")
                for key in ["keyframe", "has_parameter_sets"] {
                    check(JSONValue.bool(got[key]) == JSONValue.bool(e[key]), "packet \(k): \(key) differs")
                }
                check(got["tracking"] as? String == e["tracking"] as? String, "packet \(k): tracking differs")
                check(got["payload_hex"] as? String == e["payload_hex"] as? String, "packet \(k): payload differs")
                // Encode from the JSON description.
                guard let c2w = JSONValue.doubles(e["c2w"]), let tr = TrackingState(rawValue: e["tracking"] as? String ?? ""),
                      let payload = [UInt8](hexString: e["payload_hex"] as? String ?? "") else {
                    problems.append("packet \(k): unreadable JSON description")
                    continue
                }
                let h = MediaPacketHeader(cameraID: UInt16(JSONValue.int(e["camera_id"]) ?? 0),
                                          frameIndex: UInt32(JSONValue.int(e["frame_index"]) ?? 0),
                                          timestamp: JSONValue.double(e["timestamp"]) ?? 0, c2w: c2w.map(Float.init),
                                          fx: Float(JSONValue.double(e["fx"]) ?? 0), fy: Float(JSONValue.double(e["fy"]) ?? 0),
                                          cx: Float(JSONValue.double(e["cx"]) ?? 0), cy: Float(JSONValue.double(e["cy"]) ?? 0),
                                          width: UInt16(JSONValue.int(e["width"]) ?? 0), height: UInt16(JSONValue.int(e["height"]) ?? 0),
                                          keyframe: JSONValue.bool(e["keyframe"]) ?? false, tracking: tr,
                                          hasParameterSets: JSONValue.bool(e["has_parameter_sets"]) ?? false, payloadLength: 0)
                rebuilt += MediaPacket(header: h, payload: payload).encode()
            }
            check(rebuilt == raw, "packets: encoding packets.json does not reproduce packets.bin")

            // Control: by value.
            let craw = Array(try Data(contentsOf: dir.appendingPathComponent("control.bin")))
            var cpre = PreambleReader()
            guard let (cch, crest) = try cpre.feed(craw), cch == .control else { return problems + ["control.bin: bad preamble"] }
            var cparser = ControlStreamParser()
            let msgs = try cparser.feed(crest)
            let expMsgs = try (JSONValue.read(dir.appendingPathComponent("control.json"))["messages"] as? [Any] ?? []).map {
                try ControlProtocol.decodeJSON(Array(JSONSerialization.data(withJSONObject: $0)))
            }
            check(msgs == expMsgs, "control: control.bin does not decode to control.json")
            check(!msgs.contains { if case .unknown = $0 { return true } else { return false } }, "control: unknown message types")

            // Session.
            let (refMeta, refFrames) = GoldenReference.session()
            let meta = try SessionIO.readMeta(dir.appendingPathComponent("session"))
            check(meta == refMeta, "session/meta.json differs")
            let frames = try SessionIO.readFrames(dir.appendingPathComponent("session"))
            check(frames.count == refFrames.count, "session/frames.jsonl: frame count differs")
            for (f, r) in zip(frames, refFrames) {
                check(f.i == r.i && f.w == r.w && f.h == r.h && f.tracking == r.tracking && f.iso == r.iso && f.shutter == r.shutter,
                      "frame \(r.i): fields differ")
                check(close([f.t, f.fx, f.fy, f.cx, f.cy] + f.c2w, [r.t, r.fx, r.fy, r.cx, r.cy] + r.c2w, tol: 1e-12),
                      "frame \(r.i): numbers differ")
            }

            // Camera.
            let cams = try JSONValue.read(dir.appendingPathComponent("camera.json"))["cases"] as? [[String: Any]] ?? []
            check(!cams.isEmpty, "camera.json: no cases")
            for (n, c) in cams.enumerated() {
                guard let k = intrinsics(from: c["intrinsics"]), let c2w = JSONValue.doubles(c["c2w"]),
                      let near = JSONValue.double(c["near"]), let far = JSONValue.double(c["far"]),
                      let proj = JSONValue.doubles(c["projection"]), let pts = c["points"] as? [[String: Any]] else {
                    problems.append("camera case \(n): unreadable")
                    continue
                }
                let cam = PinholeCamera(intrinsics: k, c2w: Mat4(columnMajor: c2w))
                check(close(cam.projectionMatrix(near: near, far: far).columnMajor, proj), "camera case \(n): projection matrix differs")
                for p in pts {
                    let u = JSONValue.double(p["u"])!, v = JSONValue.double(p["v"])!, z = JSONValue.double(p["depth"])!
                    let world = JSONValue.doubles(p["world"])!
                    check(close(cam.unproject(u: u, v: v, depth: z).array, world), "camera case \(n): unproject differs")
                    let q = cam.project(Vec3(world))
                    check(q != nil && close([q!.u, q!.v, q!.depth], [u, v, z], tol: 1e-8), "camera case \(n): project differs")
                }
            }

            // Transition.
            let cases = try JSONValue.read(dir.appendingPathComponent("transition.json"))["cases"] as? [[String: Any]] ?? []
            check(!cases.isEmpty, "transition.json: no cases")
            for c in cases {
                let name = c["name"] as? String ?? "?"
                guard let a = c["a"] as? [String: Any], let b = c["b"] as? [String: Any],
                      let ka = intrinsics(from: a["intrinsics"]), let kb = intrinsics(from: b["intrinsics"]),
                      let ca = JSONValue.doubles(a["c2w"]), let cb = JSONValue.doubles(b["c2w"]),
                      let cfg = config(from: c["config"]) else {
                    problems.append("transition \(name): unreadable")
                    continue
                }
                let camA = PinholeCamera(intrinsics: ka, c2w: Mat4(columnMajor: ca))
                let camB = PinholeCamera(intrinsics: kb, c2w: Mat4(columnMajor: cb))
                let path = TransitionPath(from: camA, to: camB, floorY: JSONValue.double(c["floor_y"]), config: cfg)
                check(path.interestMethod.rawValue == c["method"] as? String, "transition \(name): method differs")
                check(close(path.interestPoint.array, JSONValue.doubles(c["interest_point"]) ?? []), "transition \(name): interest point differs")
                for smp in c["samples"] as? [[String: Any]] ?? [] {
                    let s = JSONValue.double(smp["s"])!
                    let cam = path.camera(atProgress: s)
                    let expC2w = JSONValue.doubles(smp["c2w"]) ?? []
                    check(close(cam.c2w.columnMajor, expC2w), "transition \(name): c2w at s=\(s) differs")
                    let ki = cam.intrinsics
                    check(close([ki.fx, ki.fy, ki.cx, ki.cy], ["fx", "fy", "cx", "cy"].compactMap { JSONValue.double(smp[$0]) }),
                          "transition \(name): intrinsics at s=\(s) differ")
                    if s == 0 { check(cb.count == 16 && camA.c2w.columnMajor == expC2w, "transition \(name): s=0 not exact") }
                    if s == 1 { check(camB.c2w.columnMajor == expC2w, "transition \(name): s=1 not exact") }
                }
                for bl in c["blend"] as? [[String: Any]] ?? [] {
                    let w = TransitionPath.blendWeights(timeFraction: JSONValue.double(bl["u"])!, fadeFraction: cfg.fadeFraction)
                    check(close([w.videoA, w.render, w.videoB], ["video_a", "render", "video_b"].compactMap { JSONValue.double(bl[$0]) }),
                          "transition \(name): blend differs")
                }
                for pr in c["progress"] as? [[String: Any]] ?? [] {
                    check(close([path.progress(atTime: JSONValue.double(pr["t"])!)], [JSONValue.double(pr["s"])!]),
                          "transition \(name): progress differs")
                }
            }

            // Clock.
            let ck = try JSONValue.read(dir.appendingPathComponent("clock.json"))
            var est = ClockOffsetEstimator(window: JSONValue.int(ck["window"]) ?? 60)
            let offsets = JSONValue.doubles(ck["offsets"]) ?? [], rtts = JSONValue.doubles(ck["round_trips"]) ?? []
            for (k, s) in (ck["samples"] as? [[String: Any]] ?? []).enumerated() {
                let smp = ClockSample(t1: JSONValue.double(s["t1"])!, t2: JSONValue.double(s["t2"])!,
                                      t3: JSONValue.double(s["t3"])!, t4: JSONValue.double(s["t4"])!)
                est.add(smp)
                check(k < offsets.count && close([smp.offset, smp.roundTrip], [offsets[k], rtts[k]]), "clock sample \(k) differs")
            }
            check(est.offset != nil && close([est.offset!, est.uncertainty!],
                                             [JSONValue.double(ck["estimate"]) ?? .nan, JSONValue.double(ck["uncertainty"]) ?? .nan]),
                  "clock estimate differs")
        } catch {
            problems.append("error: \(error)")
        }
        return problems
    }
}
