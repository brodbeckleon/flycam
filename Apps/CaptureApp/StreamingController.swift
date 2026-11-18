// Phone side of live streaming (plan.md Phase 5): finds the Mac with Bonjour, connects (control + media),
// encodes ARFrame.capturedImage with HEVC (VideoToolbox) and sends one packet per frame with the ARKit pose and
// intrinsics. Handles set_camera_settings, start_recording and stop_recording from the Mac and sends status
// once per second. The protocol code is Apps/Shared/Streaming (tested on the Mac by the loopback test).

import Foundation
import SwiftUI
import ARKit
import Network
import CoreMedia
import FlyCamKit

final class StreamingController: ObservableObject, PhoneStreamClientDelegate {
    @Published var state = "off"
    @Published var isStreaming = false

    private weak var model: CaptureModel?
    private let browser = ServiceBrowser()
    private var client: PhoneStreamClient?
    private var encoder: HEVCEncoder?
    private var statusTimer: Timer?
    private var frameIndex: UInt32 = 0
    private let encodeQueue = DispatchQueue(label: "ch.flycam.encode")

    static var deviceID: String {
        let key = "flycam.deviceID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    func attach(_ model: CaptureModel) {
        self.model = model
        UIDevice.current.isBatteryMonitoringEnabled = true
        model.frameHandler = { [weak self] frame in self?.handle(frame) }
    }

    func start() {
        guard client == nil, let model else { return }
        let res = model.session.configuration?.videoFormat.imageResolution ?? CGSize(width: 1920, height: 1080)
        let fps = Double(model.session.configuration?.videoFormat.framesPerSecond ?? 60)
        let hello = ControlMessage.Hello(deviceID: Self.deviceID, deviceModel: CaptureModel.deviceModel,
                                         osVersion: UIDevice.current.systemVersion,
                                         videoFormat: VideoFormat(width: Int(res.width), height: Int(res.height), fps: fps))
        let c = PhoneStreamClient(hello: hello)
        c.delegate = self
        client = c
        state = "searching for the Mac (Bonjour \(flycamServiceType))"
        browser.onResults = { [weak self] endpoints in
            // Connect once, to the first Mac found.
            guard let self, let ep = endpoints.first, c.state == .idle else { return }
            self.browser.stop()
            self.state = "connecting to \(ep)"
            c.connect(to: ep)
        }
        browser.start()
        isStreaming = true
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.sendStatus() }
    }

    func stop() {
        browser.stop()
        client?.stop()
        client = nil
        encoder = nil
        statusTimer?.invalidate()
        statusTimer = nil
        isStreaming = false
        state = "off"
    }

    /// Frame queue of the capture model.
    private func handle(_ frame: ARFrame) {
        guard let client, client.isStreaming else { return }
        let pb = frame.capturedImage
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        if encoder == nil || encoder?.width != w || encoder?.height != h {
            let fps = Double(model?.session.configuration?.videoFormat.framesPerSecond ?? 60)
            encoder = try? HEVCEncoder(width: w, height: h, fps: fps, bitRate: Int(15_000_000 * Double(w * h) / (1920 * 1080)),
                                       keyframeInterval: 1.0)
            client.onNeedKeyframe = { [weak self] in self?.encoder?.requestKeyframe() }
        }
        guard let encoder else { return }
        let cam = frame.camera
        let k = ARConvert.intrinsics(cam.intrinsics, width: Int(cam.imageResolution.width), height: Int(cam.imageResolution.height))
        let c2w = ARConvert.c2w(cam.transform)
        let tracking = CaptureModel.trackingState(cam.trackingState)
        let index = frameIndex
        frameIndex &+= 1
        let t = frame.timestamp
        encoder.encode(pb, pts: CMTime(seconds: t, preferredTimescale: 1_000_000)) { [weak client] result in
            guard let client, case .success(let au) = result else { return }
            let header = MediaPacketHeader(cameraID: 0, frameIndex: index, timestamp: t,
                                           c2w: c2w.columnMajor.map(Float.init),
                                           fx: Float(k.fx), fy: Float(k.fy), cx: Float(k.cx), cy: Float(k.cy),
                                           width: UInt16(k.width), height: UInt16(k.height), keyframe: au.keyframe,
                                           tracking: tracking, hasParameterSets: au.hasParameterSets, payloadLength: 0)
            client.send(header: header, payload: au.payload)
        }
    }

    private func sendStatus() {
        guard let client, client.isStreaming, let model else { return }
        let thermal = CaptureModel.thermalText(ProcessInfo.processInfo.thermalState)
        let tracking: TrackingState = model.tracking == "normal" ? .normal : (model.tracking.hasPrefix("limited") ? .limited : .notAvailable)
        client.sendStatus(.init(battery: Double(max(0, UIDevice.current.batteryLevel)), thermalState: thermal,
                                tracking: tracking, fps: model.fps, recording: model.isRecording))
    }

    // MARK: - PhoneStreamClientDelegate (client queue)

    func streamClient(_ client: PhoneStreamClient, didChange state: PhoneStreamClient.State) {
        DispatchQueue.main.async {
            switch state {
            case .idle: self.state = "off"
            case .connecting: self.state = "connecting"
            case .waitingForHelloAck: self.state = "waiting for the Mac"
            case .streaming(let id): self.state = "streaming as camera \(id)"
            case .failed(let s): self.state = "failed: \(s)"
            }
        }
    }

    func streamClient(_ client: PhoneStreamClient, didReceive message: ControlMessage) {
        DispatchQueue.main.async {
            guard let model = self.model else { return }
            switch message {
            case .setCameraSettings(let s):
                model.applyCamera(iso: s.iso, shutter: s.shutter, wbTemperature: s.wbTemperature, wbTint: s.wbTint, lock: s.lock)
                client.sendAck(ref: message.type, ok: true)
            case .startRecording(let r):
                guard !model.isRecording else { client.sendAck(ref: message.type, ok: false, message: "already recording"); return }
                if model.mode == .scan { model.start(mode: .clip) }
                model.remoteRecording = (r.sessionName, r.clockOffset)
                model.startRecording()
                client.sendAck(ref: message.type, ok: model.isRecording, message: model.isRecording ? nil : model.message)
            case .stopRecording:
                model.stopRecording()
                client.sendAck(ref: message.type, ok: true)
            default:
                break
            }
        }
    }
}
