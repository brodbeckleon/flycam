// Phone side of the network protocol (docs/protocol.md 3): Bonjour discovery of the Mac, control connection
// (hello, pong, status, ack), media connection (one packet per frame). Network.framework, TCP.
// Shared so that the Mac loopback test drives exactly the code the phone runs.

import Foundation
import Network
import FlyCamKit

public let flycamServiceType = "_flycam._tcp"

/// Finds Macs advertising `_flycam._tcp` (NWBrowser).
public final class ServiceBrowser {
    private var browser: NWBrowser?
    public var onResults: (([NWEndpoint]) -> Void)?

    public init() {}

    public func start(queue: DispatchQueue = .main) {
        let params = NWParameters.tcp
        params.includePeerToPeer = false
        let b = NWBrowser(for: .bonjour(type: flycamServiceType, domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            self?.onResults?(results.map(\.endpoint))
        }
        b.start(queue: queue)
        browser = b
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }
}

public protocol PhoneStreamClientDelegate: AnyObject {
    func streamClient(_ client: PhoneStreamClient, didChange state: PhoneStreamClient.State)
    /// Commands from the Mac (set_camera_settings, start_recording, stop_recording). Ping is answered internally.
    /// The delegate answers with `sendAck`.
    func streamClient(_ client: PhoneStreamClient, didReceive message: ControlMessage)
}

public final class PhoneStreamClient {
    public enum State: Equatable, Sendable {
        case idle
        case connecting
        case waitingForHelloAck
        case streaming(cameraID: UInt16)
        case failed(String)
    }

    public let hello: ControlMessage.Hello
    public weak var delegate: PhoneStreamClientDelegate?
    public private(set) var state: State = .idle {
        didSet { if state != oldValue { delegate?.streamClient(self, didChange: state) } }
    }
    public private(set) var cameraID: UInt16?
    /// Phone clock (uptime, the timebase of ARFrame.timestamp). Injectable for tests.
    public let clock: () -> Double
    /// Frames are dropped (and a keyframe requested) while more than this many bytes wait to be sent.
    public var maxBacklogBytes = 8 * 1024 * 1024
    public private(set) var sentPackets = 0
    public private(set) var droppedPackets = 0
    public private(set) var pingsAnswered = 0
    /// Called when a frame was dropped for backlog, so the encoder can force the next keyframe.
    public var onNeedKeyframe: (() -> Void)?

    public let queue: DispatchQueue
    private var endpoint: NWEndpoint?
    private var control: NWConnection?
    private var media: NWConnection?
    private var controlParser = ControlStreamParser()
    private var backlog = 0
    private var mediaReady = false
    private var waitingForKeyframe = false

    public init(hello: ControlMessage.Hello, clock: @escaping () -> Double = MonotonicClock.now,
                queue: DispatchQueue = DispatchQueue(label: "ch.flycam.phone.stream")) {
        self.hello = hello
        self.clock = clock
        self.queue = queue
    }

    public func connect(to endpoint: NWEndpoint) {
        queue.async { self.openControl(endpoint) }
    }

    public func connect(host: String, port: UInt16) {
        connect(to: .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!))
    }

    public func stop() {
        queue.async {
            self.control?.cancel()
            self.media?.cancel()
            self.control = nil
            self.media = nil
            self.mediaReady = false
            self.cameraID = nil
            self.state = .idle
        }
    }

    private static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 5
        return NWParameters(tls: nil, tcp: tcp)
    }

    private func openControl(_ ep: NWEndpoint) {
        endpoint = ep
        state = .connecting
        let c = NWConnection(to: ep, using: Self.parameters())
        control = c
        c.stateUpdateHandler = { [weak self] s in
            guard let self else { return }
            switch s {
            case .ready:
                self.state = .waitingForHelloAck
                var bytes = Channel.control.preamble
                bytes += (try? ControlProtocol.frame(.hello(self.hello))) ?? []
                c.send(content: Data(bytes), completion: .contentProcessed { _ in })
                self.receiveControl(c)
            case .failed(let e):
                self.state = .failed("control: \(e)")
            case .cancelled:
                if case .streaming = self.state { self.state = .idle }
            default:
                break
            }
        }
        c.start(queue: queue)
    }

    private func receiveControl(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
            guard let self else { return }
            if let d = data, !d.isEmpty {
                // Timestamp of arrival (t2) taken before parsing.
                let t2 = self.clock()
                do {
                    for m in try self.controlParser.feed([UInt8](d)) { self.handle(m, receivedAt: t2) }
                } catch {
                    self.state = .failed("control parse: \(error)")
                    c.cancel()
                    return
                }
            }
            if let error { self.state = .failed("control receive: \(error)"); return }
            if done { self.state = .failed("control closed by the Mac"); return }
            self.receiveControl(c)
        }
    }

    private func handle(_ m: ControlMessage, receivedAt t2: Double) {
        switch m {
        case .helloAck(let ack):
            cameraID = UInt16(clamping: ack.cameraID)
            openMedia()
        case .ping(let p):
            let t3 = clock()
            sendControl(.pong(.init(seq: p.seq, t1: p.t1, t2: t2, t3: t3)))
            pingsAnswered += 1
        case .unknown:
            break
        default:
            delegate?.streamClient(self, didReceive: m)
        }
    }

    private func openMedia() {
        guard let ep = endpoint, let id = cameraID else { return }
        let c = NWConnection(to: ep, using: Self.parameters())
        media = c
        c.stateUpdateHandler = { [weak self] s in
            guard let self else { return }
            switch s {
            case .ready:
                c.send(content: Data(Channel.media.preamble), completion: .contentProcessed { _ in })
                self.mediaReady = true
                self.waitingForKeyframe = true
                self.onNeedKeyframe?()
                self.state = .streaming(cameraID: id)
            case .failed(let e):
                self.mediaReady = false
                self.state = .failed("media: \(e)")
            default:
                break
            }
        }
        c.start(queue: queue)
    }

    public func sendControl(_ m: ControlMessage) {
        guard let c = control, let bytes = try? ControlProtocol.frame(m) else { return }
        c.send(content: Data(bytes), completion: .contentProcessed { _ in })
    }

    public func sendStatus(_ s: ControlMessage.Status) {
        queue.async { self.sendControl(.status(s)) }
    }

    public func sendAck(ref: String, ok: Bool, message: String? = nil) {
        queue.async { self.sendControl(.ack(.init(ref: ref, ok: ok, message: message))) }
    }

    /// Sends one frame. The camera id in the header is replaced by the id assigned by the Mac.
    /// Returns false when the frame was not sent (not connected, waiting for a keyframe, or backlog).
    @discardableResult
    public func send(header: MediaPacketHeader, payload: [UInt8]) -> Bool {
        var result = false
        queue.sync {
            guard mediaReady, let c = media, let id = cameraID else { return }
            if waitingForKeyframe && !header.keyframe { droppedPackets += 1; return }
            if backlog > maxBacklogBytes {
                droppedPackets += 1
                waitingForKeyframe = true
                onNeedKeyframe?()
                return
            }
            waitingForKeyframe = false
            var h = header
            h.cameraID = id
            let bytes = MediaPacket(header: h, payload: payload).encode()
            backlog += bytes.count
            c.send(content: Data(bytes), completion: .contentProcessed { [weak self] _ in
                self?.queue.async { self?.backlog -= bytes.count }
            })
            sentPackets += 1
            result = true
        }
        return result
    }

    public var isStreaming: Bool {
        if case .streaming = state { return true }
        return false
    }
}
