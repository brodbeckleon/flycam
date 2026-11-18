// ARKit session, modes (clip recording, scan, live) and recording (plan.md Phases 0, 1, 3).
// Frames arrive on a serial queue; UI state is published on the main queue at about 5 Hz.

import Foundation
import ARKit
import UIKit
import SwiftUI
import FlyCamKit

enum CaptureMode: String, CaseIterable, Identifiable {
    case clip = "Clip"
    case scan = "Scan"
    case live = "Live"
    var id: String { rawValue }
}

final class CaptureModel: NSObject, ObservableObject, ARSessionDelegate {
    let session = ARSession()
    let camera = CameraControl()

    @Published var mode: CaptureMode = .clip
    @Published var isRunning = false
    @Published var isRecording = false
    @Published var tracking = "not available"
    @Published var thermal = "nominal"
    @Published var pose = "-"
    @Published var mapping = "-"
    @Published var relocalisation = "-"
    @Published var message = ""
    @Published var stillCount = 0
    @Published var floorY: Double?
    @Published var fps: Double = 0
    @Published var videoFormatText = "-"
    @Published var timebaseText = "-"
    @Published var cameraSettings = CameraSettings(locked: false)
    @Published var sessions: [URL] = []
    @Published var worldMapSource: URL?

    /// Streaming hook (Phase 5): called on the frame queue for every ARFrame.
    var frameHandler: ((ARFrame) -> Void)?
    /// Recording requested by the Mac: session name and clock offset for meta.json.
    var remoteRecording: (name: String, clockOffset: Double)?

    private let queue = DispatchQueue(label: "ch.flycam.capture.frames", qos: .userInteractive)
    private var recorder: SessionRecorder?
    private var keyframes = ScanKeyframeSelector()
    private var planes: [UUID: PlaneObservation] = [:]
    private var lowestCameraY: Double?
    private var lastFrame: ARFrame?
    private var lastUIUpdate: TimeInterval = 0
    private var frameTimes: [Double] = []
    private var loadedFloorY: Double?

    var sessionsDirectory: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Sessions")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    override init() {
        super.init()
        session.delegate = self
        session.delegateQueue = queue
        refreshSessions()
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.thermal = Self.thermalText(ProcessInfo.processInfo.thermalState)
        }
        thermal = Self.thermalText(ProcessInfo.processInfo.thermalState)
    }

    static func thermalText(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    func refreshSessions() {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: sessionsDirectory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        sessions = items.filter { $0.lastPathComponent.hasPrefix("session_") }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    // MARK: - Session configuration

    func makeConfiguration(for mode: CaptureMode, worldMap: ARWorldMap? = nil) -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        let formats = ARWorldTrackingConfiguration.supportedVideoFormats
        let candidates = formats.map { VideoFormatCandidate(width: Int($0.imageResolution.width), height: Int($0.imageResolution.height),
                                                            fps: $0.framesPerSecond) }
        if let i = VideoFormatChooser.choose(candidates) { config.videoFormat = formats[i] }
        config.isAutoFocusEnabled = false
        config.worldAlignment = .gravity
        if mode == .scan {
            config.planeDetection = [.horizontal]
        }
        if mode == .live, let map = worldMap {
            config.initialWorldMap = map
        }
        return config
    }

    /// Lists the supported video formats (plan.md Phase 0: note them in docs/log.md per phone model).
    func supportedFormatsDescription() -> String {
        ARWorldTrackingConfiguration.supportedVideoFormats.map {
            "\(Int($0.imageResolution.width))x\(Int($0.imageResolution.height)) @ \($0.framesPerSecond) fps"
        }.joined(separator: "\n")
    }

    func start(mode: CaptureMode, worldMap: ARWorldMap? = nil) {
        self.mode = mode
        planes = [:]
        keyframes = ScanKeyframeSelector()
        let config = makeConfiguration(for: mode, worldMap: worldMap)
        videoFormatText = "\(Int(config.videoFormat.imageResolution.width))x\(Int(config.videoFormat.imageResolution.height)) @ \(config.videoFormat.framesPerSecond)"
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        camera.attach()
        isRunning = true
        UIApplication.shared.isIdleTimerDisabled = true
        message = mode == .live && worldMap != nil ? "Relocalising: look around the scanned scene, then clamp into the tripod." : ""
    }

    // MARK: - Camera lock

    func lockCamera() {
        do {
            try camera.lockCurrent()
            cameraSettings = camera.currentSettings(locked: true)
        } catch { message = "Lock failed: \(error.localizedDescription)" }
    }

    func applyCamera(iso: Double?, shutter: Double?, wbTemperature: Double?, wbTint: Double?, lock: Bool = true) {
        do {
            try camera.apply(lock: lock, iso: iso, shutter: shutter, wbTemperature: wbTemperature, wbTint: wbTint)
            cameraSettings = camera.currentSettings(locked: lock)
        } catch { message = "Camera settings failed: \(error.localizedDescription)" }
    }

    // MARK: - Recording

    func startRecording() {
        guard recorder == nil, let frame = session.currentFrame else { return }
        let res = frame.camera.imageResolution
        let fmt = VideoFormat(width: Int(res.width), height: Int(res.height),
                              fps: Double(session.configuration?.videoFormat.framesPerSecond ?? 60))
        do {
            let kind: SessionKind = mode == .scan ? .scan : .clip
            let r = try SessionRecorder(parent: sessionsDirectory, kind: kind, deviceModel: Self.deviceModel,
                                        osVersion: UIDevice.current.systemVersion, videoFormat: fmt,
                                        clockOffset: remoteRecording?.clockOffset,
                                        folderName: remoteRecording?.name)
            r.cameraSettings = camera.currentSettings(locked: cameraSettings.locked)
            r.floorY = loadedFloorY
            queue.async { self.recorder = r }
            isRecording = true
            stillCount = 0
            message = "Recording \(r.folder.lastPathComponent)"
        } catch {
            message = "Cannot start recording: \(error.localizedDescription)"
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        if mode == .scan {
            finishScan()
            return
        }
        queue.async {
            let r = self.recorder
            self.recorder = nil
            do {
                let url = try r?.finish()
                DispatchQueue.main.async {
                    self.isRecording = false
                    self.message = "Saved \(url?.lastPathComponent ?? "")"
                    self.remoteRecording = nil
                    self.refreshSessions()
                }
            } catch {
                DispatchQueue.main.async { self.isRecording = false; self.message = "Save failed: \(error.localizedDescription)" }
            }
        }
    }

    /// Scan end: wait until the world map is mapped, save it and its feature points, store the floor height.
    func finishScan() {
        message = "Waiting for world mapping status 'mapped'. Keep moving slowly."
        waitForMapped(deadline: Date().addingTimeInterval(60))
    }

    private func waitForMapped(deadline: Date) {
        guard let frame = session.currentFrame else { return }
        if frame.worldMappingStatus != .mapped && Date() < deadline {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.waitForMapped(deadline: deadline) }
            return
        }
        if frame.worldMappingStatus != .mapped {
            message = "World map not 'mapped' after 60 s, saving anyway (relocalisation may fail)."
        }
        session.getCurrentWorldMap { map, error in
            self.queue.async {
                let r = self.recorder
                self.recorder = nil
                var mapData: Data?
                var points: [ColoredPoint]?
                if let map {
                    mapData = try? NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true)
                    points = self.colouredFeaturePoints(map.rawFeaturePoints.points, frame: self.lastFrame)
                }
                r?.floorY = FloorEstimator.floorY(planes: Array(self.planes.values), lowestCameraY: self.lowestCameraY)
                do {
                    let url = try r?.finish(worldMap: mapData, points: points)
                    DispatchQueue.main.async {
                        self.isRecording = false
                        self.floorY = r?.floorY
                        self.message = "Scan saved: \(url?.lastPathComponent ?? ""), \(points?.count ?? 0) points"
                            + (error.map { ", world map error: \($0.localizedDescription)" } ?? "")
                        self.refreshSessions()
                    }
                } catch {
                    DispatchQueue.main.async { self.isRecording = false; self.message = "Save failed: \(error.localizedDescription)" }
                }
            }
        }
    }

    /// Feature points coloured with the luminance of the last frame where they project into the image (grey otherwise).
    private func colouredFeaturePoints(_ pts: [simd_float3], frame: ARFrame?) -> [ColoredPoint] {
        guard let frame else { return pts.map { ColoredPoint(position: $0, color: SIMD3(128, 128, 128)) } }
        let pb = frame.capturedImage
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0)?.assumingMemoryBound(to: UInt8.self) else {
            return pts.map { ColoredPoint(position: $0, color: SIMD3(128, 128, 128)) }
        }
        let cam = PinholeCamera(intrinsics: ARConvert.intrinsics(frame.camera.intrinsics, width: w, height: h),
                                c2w: ARConvert.c2w(frame.camera.transform))
        return pts.map { p in
            if let q = cam.project(Vec3(Double(p.x), Double(p.y), Double(p.z))),
               q.u >= 0, q.v >= 0, Int(q.u) < w, Int(q.v) < h {
                let y = base[Int(q.v) * stride + Int(q.u)]
                return ColoredPoint(position: p, color: SIMD3(y, y, y))
            }
            return ColoredPoint(position: p, color: SIMD3(128, 128, 128))
        }
    }

    // MARK: - Live mode

    /// Loads worldmap.bin (and floor_y) of a scan session and restarts in live mode with it.
    func startLive(scan folder: URL) {
        do {
            let data = try Data(contentsOf: folder.appendingPathComponent("worldmap.bin"))
            guard let map = try NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) else {
                message = "worldmap.bin is not an ARWorldMap"
                return
            }
            loadedFloorY = (try? SessionIO.readMeta(folder))?.floorY
            floorY = loadedFloorY
            worldMapSource = folder
            start(mode: .live, worldMap: map)
        } catch {
            message = "Cannot load world map: \(error.localizedDescription)"
        }
    }

    // MARK: - ARSessionDelegate (frame queue)

    static var deviceModel: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
    }

    static func trackingState(_ s: ARCamera.TrackingState) -> TrackingState {
        switch s {
        case .normal: return .normal
        case .limited: return .limited
        case .notAvailable: return .notAvailable
        }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        lastFrame = frame
        let cam = frame.camera
        let res = cam.imageResolution
        let k = ARConvert.intrinsics(cam.intrinsics, width: Int(res.width), height: Int(res.height))
        let c2w = ARConvert.c2w(cam.transform)
        let tracking = Self.trackingState(cam.trackingState)
        lowestCameraY = min(lowestCameraY ?? c2w.translation.y, c2w.translation.y)
        let iso = cameraSettings.iso
        let shutter = cam.exposureDuration

        if let r = recorder {
            do {
                if r.kind == .clip {
                    try r.appendVideoFrame(frame.capturedImage, time: frame.timestamp, c2w: c2w, intrinsics: k,
                                           tracking: tracking, iso: iso, shutter: shutter)
                } else if keyframes.shouldSave(time: frame.timestamp, c2w: c2w, tracking: tracking) {
                    try r.appendStill(frame.capturedImage, time: frame.timestamp, c2w: c2w, intrinsics: k,
                                      tracking: tracking, iso: iso, shutter: shutter)
                }
            } catch {
                DispatchQueue.main.async { self.message = "Recording error: \(error)" }
            }
        }
        frameHandler?(frame)

        frameTimes.append(frame.timestamp)
        if frameTimes.count > 60 { frameTimes.removeFirst(frameTimes.count - 60) }
        let now = CACurrentMediaTime()
        guard now - lastUIUpdate > 0.2 else { return }
        lastUIUpdate = now
        let measuredFPS = frameTimes.count > 1 ? Double(frameTimes.count - 1) / (frameTimes.last! - frameTimes.first!) : 0
        let p = c2w.translation
        let fwd = Vec3(-c2w[0, 2], -c2w[1, 2], -c2w[2, 2])
        let poseText = String(format: "pos %.3f %.3f %.3f  fwd %.2f %.2f %.2f", p.x, p.y, p.z, fwd.x, fwd.y, fwd.z)
        let trackingText: String
        switch cam.trackingState {
        case .normal: trackingText = "normal"
        case .notAvailable: trackingText = "not available"
        case .limited(let reason):
            switch reason {
            case .initializing: trackingText = "limited (initialising)"
            case .relocalizing: trackingText = "limited (relocalising)"
            case .excessiveMotion: trackingText = "limited (excessive motion)"
            case .insufficientFeatures: trackingText = "limited (insufficient features)"
            @unknown default: trackingText = "limited"
            }
        }
        let mappingText: String
        switch frame.worldMappingStatus {
        case .notAvailable: mappingText = "not available"
        case .limited: mappingText = "limited"
        case .extending: mappingText = "extending"
        case .mapped: mappingText = "mapped"
        @unknown default: mappingText = "unknown"
        }
        // Timebase check (plan.md Phase 1 Verify): ARFrame.timestamp vs. CACurrentMediaTime().
        let timebase = String(format: "now - frame.timestamp = %.1f ms", (now - frame.timestamp) * 1000)
        let floorNow = mode == .scan ? FloorEstimator.floorY(planes: Array(planes.values), lowestCameraY: lowestCameraY) : nil
        let saved = keyframes.savedCount
        let isLiveWithMap = mode == .live && worldMapSource != nil
        DispatchQueue.main.async {
            self.pose = poseText
            self.tracking = trackingText
            self.mapping = mappingText
            self.fps = measuredFPS
            self.timebaseText = timebase
            if self.mode == .scan { self.stillCount = saved; self.floorY = floorNow ?? self.floorY }
            if isLiveWithMap {
                self.relocalisation = trackingText == "normal" ? "relocalised" : trackingText
            }
        }
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) { updatePlanes(anchors) }
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) { updatePlanes(anchors) }
    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        for a in anchors { planes[a.identifier] = nil }
    }

    private func updatePlanes(_ anchors: [ARAnchor]) {
        for case let p as ARPlaneAnchor in anchors where p.alignment == .horizontal {
            let area = Double(p.planeExtent.width * p.planeExtent.height)
            let isFloor: Bool
            if ARPlaneAnchor.isClassificationSupported, case .floor = p.classification { isFloor = true } else { isFloor = false }
            planes[p.identifier] = PlaneObservation(identifier: p.identifier, y: Double(p.transform.columns.3.y),
                                                    area: area, isFloor: isFloor)
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async { self.message = "AR session failed: \(error.localizedDescription)" }
    }
}
