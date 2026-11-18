// DirectorApp state: sources (recorded and live), splat, preview/program, live server.

import Foundation
import SwiftUI
import DirectorCore
import FlyCamKit

final class DirectorModel: ObservableObject {
    @Published var sourceNames: [UInt16: String] = [:]
    @Published var program: UInt16 = 0
    @Published var preview: UInt16?
    @Published var inFlight = false
    @Published var splatName = "none"
    @Published var message = ""
    @Published var liveCameras: [CameraInfo] = []
    @Published var serverPort: UInt16?
    @Published var recording = false

    let context: MetalContext?
    var scene: SplatScene?
    private(set) var sources: [UInt16: FrameSource] = [:]
    let controller = TransitionController(program: 0)
    let server = DirectorServer()
    /// Playback clock for recorded sessions (seconds on the Mac clock when they share one).
    private var playbackStart: (wall: Double, media: Double)?
    var floorY: Double?

    init() {
        context = try? MetalContext.shared()
        if context == nil { message = "Metal is not available" }
        server.onCameraChanged = { [weak self] _ in
            DispatchQueue.main.async { self?.refreshLive() }
        }
        do {
            serverPort = try server.start()
            message = "listening on port \(serverPort ?? 0), Bonjour \(flycamServiceType)"
        } catch {
            message = "server failed: \(error)"
        }
    }

    func refreshLive() {
        liveCameras = server.cameraInfos()
        for info in liveCameras where info.connected {
            // Live cameras use ids 100+ in the program so they never collide with recorded sources.
            let id = 100 + info.cameraID
            if sources[id] == nil {
                sources[id] = LiveSource(server: server, cameraID: info.cameraID, floorY: floorY)
                sourceNames[id] = "live: \(info.hello.deviceModel) #\(info.cameraID)"
            }
        }
    }

    func loadSplat(_ url: URL) {
        guard let ctx = context else { return }
        Task {
            do {
                let s = try await SplatScene.load(url: url, context: ctx)
                await MainActor.run {
                    self.scene = s
                    self.splatName = "\(url.lastPathComponent) (\(s.splatCount) Gaussians)"
                }
            } catch {
                await MainActor.run { self.message = "cannot load splat: \(error)" }
            }
        }
    }

    func addSession(_ url: URL) {
        Task {
            do {
                let id = UInt16((sources.keys.filter { $0 < 100 }.max() ?? 0) + (sources.isEmpty ? 0 : 1))
                let src = try await RecordedSource(folder: url, cameraID: id)
                await MainActor.run {
                    self.sources[id] = src
                    self.sourceNames[id] = "\(id): \(src.name)"
                    if self.floorY == nil { self.floorY = src.floorY }
                    if self.sources.count == 1 { self.program = id }
                }
            } catch {
                await MainActor.run { self.message = "cannot open session: \(error)" }
            }
        }
    }

    func selectPreview(_ id: UInt16) {
        controller.selectPreview(id)
        preview = controller.preview
    }

    func take() {
        if controller.take(at: now()) { inFlight = true }
    }

    /// Program time: Mac clock minus playout delay for live, looping playback time for recordings.
    func now() -> Double {
        let wall = MonotonicClock.now()
        if sources[controller.program] is LiveSource { return wall - server.config.playoutDelay }
        guard let range = sources[controller.program]?.availableTimes else { return wall }
        if playbackStart == nil { playbackStart = (wall, range.lowerBound) }
        let length = max(range.upperBound - range.lowerBound, 1e-3)
        let elapsed = (wall - playbackStart!.wall).truncatingRemainder(dividingBy: length)
        return playbackStart!.media + elapsed
    }

    /// Called by the program view after each frame.
    func syncState() {
        if controller.active == nil && inFlight {
            inFlight = false
            program = controller.program
            preview = controller.preview
        }
    }

    /// Pushes locked exposure and white balance to all phones (plan.md Phase 5). The protocol has no message that
    /// reports a phone's current values, so the operator enters the values read on the reference phone.
    func pushSettings(iso: Double, shutter: Double, wbTemperature: Double, wbTint: Double) {
        server.pushCameraSettings(.init(lock: true, iso: iso, shutter: shutter, wbTemperature: wbTemperature, wbTint: wbTint))
        message = String(format: "pushed ISO %.0f, 1/%.0f s, %.0f K, tint %.1f to all phones", iso, 1 / shutter, wbTemperature, wbTint)
    }

    func toggleRecording() {
        if recording {
            server.stopRecordingAll()
        } else {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd-HHmmss"
            server.startRecordingAll(sessionName: "session_\(f.string(from: Date()))")
        }
        recording.toggle()
    }
}
