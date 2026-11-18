// Mac side of live streaming (plan.md Phase 5, docs/protocol.md 3-4): one TCP port advertised with Bonjour as
// `_flycam._tcp`, preamble dispatch, camera registry (stable id per device), clock sync (10 pings at connect,
// then 1 per second, min-RTT offset), HEVC decode, frame store keyed by Mac time.

import Foundation
import Network
import CoreVideo
import CoreMedia
import FlyCamKit

/// A decoded live frame in the frame store.
public struct LiveFrame: @unchecked Sendable {
    public var header: MediaPacketHeader
    public var pixelBuffer: CVPixelBuffer
    /// Mac clock when the packet was received (for latency measurements).
    public var receivedAt: Double
    /// Clock offset estimate (t_mac - t_phone) used to place this frame: the estimate current at arrival.
    public var offsetApplied: Double = 0
}

public struct CameraInfo: Sendable {
    public var cameraID: UInt16
    public var hello: ControlMessage.Hello
    public var connected: Bool
    public var offset: Double?
    public var offsetUncertainty: Double?
    public var lastStatus: ControlMessage.Status?
    public var acks: [ControlMessage.Ack] = []
    public var framesReceived = 0
    public var framesDecoded = 0
    public var lastHeader: MediaPacketHeader?
}

public final class DirectorServer: @unchecked Sendable {
    public struct Config: Sendable {
        /// 0 = any free port.
        public var port: UInt16 = 0
        /// Advertise with Bonjour (needs the local network permission on the Mac).
        public var advertise = true
        public var serviceName: String?
        public var playoutDelay = 0.150
        public var storeSeconds = 0.5
        public var initialPings = 10
        public var initialPingInterval = 0.02
        public var pingInterval = 1.0
        /// Only accept connections from the loopback interface (tests).
        public var loopbackOnly = false
        public init() {}
    }

    public let config: Config
    public let clock: () -> Double
    public let queue = DispatchQueue(label: "ch.flycam.director.server", qos: .userInteractive)
    public private(set) var port: UInt16?

    // Callbacks (on `queue`).
    public var onCameraChanged: ((CameraInfo) -> Void)?
    /// Every decoded frame, after it was inserted into the store.
    public var onFrame: ((UInt16, LiveFrame, Double) -> Void)?
    public var onLog: ((String) -> Void)?

    private var listener: NWListener?
    private var cameras: [UInt16: CameraInfo] = [:]
    private var deviceIDs: [String: UInt16] = [:]
    private var controlConnections: [UInt16: NWConnection] = [:]
    private var estimators: [UInt16: ClockOffsetEstimator] = [:]
    private var decoders: [UInt16: HEVCDecoder] = [:]
    private var pendingPings: [UInt16: Set<Int>] = [:]
    private var pingSeq = 0
    private var pingTimer: DispatchSourceTimer?
    private var pendingMedia: [UInt16: [(MediaPacketHeader, CVPixelBuffer, Double)]] = [:]

    private let storeLock = NSLock()
    private var store: FrameStore<LiveFrame>

    public init(config: Config = Config(), clock: @escaping () -> Double = MonotonicClock.now) {
        self.config = config
        self.clock = clock
        store = FrameStore(capacitySeconds: config.storeSeconds, playoutDelay: config.playoutDelay)
    }

    // MARK: - Lifecycle

    /// Starts listening; returns the port once the listener is ready.
    @discardableResult
    public func start(timeout: Double = 5) throws -> UInt16 {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        if config.loopbackOnly { params.requiredInterfaceType = .loopback }
        let l = try NWListener(using: params, on: config.port == 0 ? .any : NWEndpoint.Port(rawValue: config.port)!)
        if config.advertise {
            l.service = NWListener.Service(name: config.serviceName, type: flycamServiceType)
        }
        let ready = DispatchSemaphore(value: 0)
        var failure: Error?
        l.stateUpdateHandler = { [weak self] s in
            switch s {
            case .ready:
                self?.port = l.port?.rawValue
                ready.signal()
            case .failed(let e):
                failure = e
                ready.signal()
            default:
                break
            }
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.start(queue: queue)
        listener = l
        guard ready.wait(timeout: .now() + timeout) == .success else { throw CodecError.invalidPayload("listener not ready") }
        if let failure { throw failure }

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + config.pingInterval, repeating: config.pingInterval)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            for id in self.controlConnections.keys { self.sendPing(to: id) }
        }
        t.resume()
        pingTimer = t
        return port ?? 0
    }

    public func stop() {
        queue.sync {
            pingTimer?.cancel()
            pingTimer = nil
            listener?.cancel()
            listener = nil
            for c in controlConnections.values { c.cancel() }
            controlConnections = [:]
        }
    }

    // MARK: - Public state

    public func cameraInfos() -> [CameraInfo] {
        queue.sync { cameras.values.sorted { $0.cameraID < $1.cameraID } }
    }

    public func cameraInfo(_ id: UInt16) -> CameraInfo? {
        queue.sync { cameras[id] }
    }

    /// Thread-safe access to the frame store.
    public func withStore<R>(_ body: (inout FrameStore<LiveFrame>) -> R) -> R {
        storeLock.lock()
        defer { storeLock.unlock() }
        return body(&store)
    }

    /// Nearest frame of each camera to `now - playoutDelay` (docs/protocol.md 4). Logs the residual.
    public func pairForDisplay(now: Double? = nil, cameras ids: [UInt16]? = nil) -> PairedFrames<LiveFrame> {
        withStore { s in s.pair(at: s.renderTime(now: now ?? clock()), cameras: ids) }
    }

    public func send(_ m: ControlMessage, to id: UInt16) {
        queue.async {
            guard let c = self.controlConnections[id], let bytes = try? ControlProtocol.frame(m) else { return }
            c.send(content: Data(bytes), completion: .contentProcessed { _ in })
        }
    }

    /// Pushes one phone's locked camera settings to all phones (plan.md Phase 5).
    public func pushCameraSettings(_ s: ControlMessage.SetCameraSettings) {
        for id in cameraInfos().filter(\.connected).map(\.cameraID) { send(.setCameraSettings(s), to: id) }
    }

    /// Mac-triggered synchronised recording: every phone gets the session name and its own clock offset.
    public func startRecordingAll(sessionName: String) {
        for info in cameraInfos() where info.connected {
            send(.startRecording(.init(sessionName: "\(sessionName)_cam\(info.cameraID)", clockOffset: info.offset ?? 0)), to: info.cameraID)
        }
    }

    public func stopRecordingAll() {
        for info in cameraInfos() where info.connected { send(.stopRecording, to: info.cameraID) }
    }

    // MARK: - Connections

    private func log(_ s: String) { onLog?(s) }

    private func accept(_ c: NWConnection) {
        var preamble = PreambleReader()
        c.stateUpdateHandler = { [weak self] s in
            if case .failed(let e) = s { self?.log("connection failed: \(e)") }
        }
        c.start(queue: queue)
        func readPreamble() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
                guard let self else { return }
                guard let d = data, !d.isEmpty else {
                    if done || error != nil { c.cancel() } else { readPreamble() }
                    return
                }
                do {
                    if let (channel, rest) = try preamble.feed([UInt8](d)) {
                        switch channel {
                        case .control: self.runControl(c, initial: rest)
                        case .media: self.runMedia(c, initial: rest)
                        }
                    } else {
                        readPreamble()
                    }
                } catch {
                    self.log("rejected connection: \(error)")
                    c.cancel()
                }
            }
        }
        readPreamble()
    }

    private func runControl(_ c: NWConnection, initial: [UInt8]) {
        var parser = ControlStreamParser()
        var cameraID: UInt16?
        func process(_ bytes: [UInt8], at t4: Double) -> Bool {
            do {
                for m in try parser.feed(bytes) {
                    switch m {
                    case .hello(let h):
                        let id = deviceIDs[h.deviceID] ?? UInt16(deviceIDs.count)
                        deviceIDs[h.deviceID] = id
                        cameraID = id
                        controlConnections[id] = c
                        var info = cameras[id] ?? CameraInfo(cameraID: id, hello: h, connected: true)
                        info.hello = h
                        info.connected = true
                        cameras[id] = info
                        estimators[id] = ClockOffsetEstimator(window: 60)
                        decoders[id] = HEVCDecoder()
                        send(.helloAck(.init(cameraID: Int(id))), to: id)
                        for k in 0..<config.initialPings {
                            queue.asyncAfter(deadline: .now() + config.initialPingInterval * Double(k + 1)) { [weak self] in
                                self?.sendPing(to: id)
                            }
                        }
                        onCameraChanged?(info)
                        log("camera \(id) connected: \(h.deviceModel) \(h.deviceID)")
                    case .pong(let p):
                        guard let id = cameraID, pendingPings[id]?.remove(p.seq) != nil else { continue }
                        estimators[id]?.add(ClockSample(t1: p.t1, t2: p.t2, t3: p.t3, t4: t4))
                        cameras[id]?.offset = estimators[id]?.offset
                        cameras[id]?.offsetUncertainty = estimators[id]?.uncertainty
                        flushPending(id)
                    case .status(let s):
                        guard let id = cameraID else { continue }
                        cameras[id]?.lastStatus = s
                        if let info = cameras[id] { onCameraChanged?(info) }
                    case .ack(let a):
                        guard let id = cameraID else { continue }
                        cameras[id]?.acks.append(a)
                        if let info = cameras[id] { onCameraChanged?(info) }
                    case .unknown(let t):
                        log("unknown control message type \(t)")
                    default:
                        log("unexpected control message \(m.type) from a phone")
                    }
                }
                return true
            } catch {
                log("control channel error: \(error)")
                return false
            }
        }
        func receive() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
                guard let self else { return }
                let t4 = self.clock()
                if let d = data, !d.isEmpty, !process([UInt8](d), at: t4) { c.cancel(); return }
                if done || error != nil {
                    if let id = cameraID {
                        self.cameras[id]?.connected = false
                        self.controlConnections[id] = nil
                        if let info = self.cameras[id] { self.onCameraChanged?(info) }
                    }
                    c.cancel()
                    return
                }
                receive()
            }
        }
        if !initial.isEmpty && !process(initial, at: clock()) { c.cancel(); return }
        receive()
    }

    private func sendPing(to id: UInt16) {
        guard let c = controlConnections[id] else { return }
        pingSeq += 1
        let seq = pingSeq
        pendingPings[id, default: []].insert(seq)
        if pendingPings[id]!.count > 120 { pendingPings[id]!.remove(pendingPings[id]!.min()!) }
        guard let bytes = try? ControlProtocol.frame(.ping(.init(seq: seq, t1: clock()))) else { return }
        c.send(content: Data(bytes), completion: .contentProcessed { _ in })
    }

    private func runMedia(_ c: NWConnection, initial: [UInt8]) {
        var parser = MediaStreamParser()
        func process(_ bytes: [UInt8]) -> Bool {
            let received = clock()
            do {
                for p in try parser.feed(bytes) {
                    let id = p.header.cameraID
                    guard cameras[id] != nil, let dec = decoders[id] else {
                        log("media packet for unknown camera \(id) (no hello yet), closing")
                        return false
                    }
                    cameras[id]?.framesReceived += 1
                    cameras[id]?.lastHeader = p.header
                    do {
                        if let pb = try dec.decode(payload: p.payload, pts: CMTime(seconds: p.header.timestamp, preferredTimescale: 1_000_000)) {
                            cameras[id]?.framesDecoded += 1
                            deliver(id, p.header, pb, received)
                        }
                    } catch {
                        log("camera \(id) frame \(p.header.frameIndex): decode failed: \(error)")
                    }
                }
                return true
            } catch {
                log("media channel error: \(error), closing")
                return false
            }
        }
        func receive() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) { [weak self] data, _, done, error in
                guard self != nil else { return }
                if let d = data, !d.isEmpty, !process([UInt8](d)) { c.cancel(); return }
                if done || error != nil { c.cancel(); return }
                receive()
            }
        }
        if !initial.isEmpty && !process(initial) { c.cancel(); return }
        receive()
    }

    /// Inserts a decoded frame at Mac time `t_phone + offset`. Frames that arrive before the first clock
    /// sample are held (up to 2 s) until the offset is known.
    private func deliver(_ id: UInt16, _ h: MediaPacketHeader, _ pb: CVPixelBuffer, _ received: Double) {
        guard let offset = estimators[id]?.offset else {
            pendingMedia[id, default: []].append((h, pb, received))
            if pendingMedia[id]!.count > 120 { pendingMedia[id]!.removeFirst() }
            return
        }
        let macTime = h.timestamp + offset
        let f = LiveFrame(header: h, pixelBuffer: pb, receivedAt: received, offsetApplied: offset)
        withStore { $0.insert(camera: id, macTime: macTime, frameIndex: h.frameIndex, payload: f) }
        onFrame?(id, f, macTime)
    }

    private func flushPending(_ id: UInt16) {
        guard let pending = pendingMedia.removeValue(forKey: id) else { return }
        for (h, pb, r) in pending { deliver(id, h, pb, r) }
    }
}
