// FlyCam capture app (iOS): camera preview, pose / tracking / thermal state, camera lock, clip recording,
// scan mode, live mode with world map relocalisation, export of session folders.

import SwiftUI
import ARKit
import SceneKit
import UIKit

@main
struct CaptureApp: App {
    @StateObject private var model = CaptureModel()
    @StateObject private var streamer = StreamingController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(streamer)
                .onAppear {
                    model.start(mode: .clip)
                    streamer.attach(model)
                }
        }
    }
}

struct ARPreview: UIViewRepresentable {
    let session: ARSession
    func makeUIView(context: Context) -> ARSCNView {
        let v = ARSCNView()
        v.session = session
        v.automaticallyUpdatesLighting = false
        v.debugOptions = [.showFeaturePoints, .showWorldOrigin]
        return v
    }
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

struct ContentView: View {
    @EnvironmentObject var model: CaptureModel
    @EnvironmentObject var streamer: StreamingController
    @State private var showSessions = false
    @State private var showCamera = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            ARPreview(session: model.session).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 4) {
                Text("\(model.mode.rawValue)  \(model.videoFormatText)  \(String(format: "%.1f", model.fps)) fps").bold()
                Text("tracking: \(model.tracking)   mapping: \(model.mapping)")
                Text(model.pose).font(.system(.caption, design: .monospaced))
                Text("thermal: \(model.thermal)   \(model.timebaseText)")
                if model.mode == .scan {
                    Text("stills: \(model.stillCount)   floor y: \(model.floorY.map { String(format: "%.3f", $0) } ?? "-")")
                }
                if model.mode == .live {
                    Text("relocalisation: \(model.relocalisation)   map: \(model.worldMapSource?.lastPathComponent ?? "none")")
                }
                Text("camera: \(cameraText)")
                Text("stream: \(streamer.state)")
                if !model.message.isEmpty { Text(model.message).foregroundStyle(.yellow) }
            }
            .font(.caption)
            .padding(8)
            .background(.black.opacity(0.55))
            .foregroundStyle(.white)
            .padding()

            VStack {
                Spacer()
                HStack(spacing: 12) {
                    Picker("Mode", selection: Binding(get: { model.mode }, set: { m in
                        if m == .live, let scan = model.worldMapSource { model.startLive(scan: scan) } else { model.start(mode: m) }
                    })) {
                        ForEach(CaptureMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                    .disabled(model.isRecording)
                    Button(model.cameraSettings.locked ? "Locked" : "Lock camera") { model.lockCamera() }
                    Button("Camera…") { showCamera = true }
                    Button(model.isRecording ? "Stop" : (model.mode == .scan ? "Start scan" : "Record")) {
                        model.isRecording ? model.stopRecording() : model.startRecording()
                    }
                    .tint(model.isRecording ? .red : .accentColor)
                    Button(streamer.isStreaming ? "Disconnect" : "Connect to Mac") {
                        streamer.isStreaming ? streamer.stop() : streamer.start()
                    }
                    Button("Sessions") { model.refreshSessions(); showSessions = true }
                }
                .buttonStyle(.borderedProminent)
                .padding()
                .background(.black.opacity(0.4))
            }
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showSessions) { SessionsView().environmentObject(model) }
        .sheet(isPresented: $showCamera) { CameraSettingsView().environmentObject(model) }
        .statusBarHidden()
    }

    var cameraText: String {
        let s = model.cameraSettings
        guard s.locked else { return "auto" }
        return String(format: "locked ISO %.0f  1/%.0f s  %.0f K  tint %.1f", s.iso ?? 0, 1 / max(s.shutter ?? 1, 1e-6),
                      s.wbTemperature ?? 0, s.wbTint ?? 0)
    }
}

struct CameraSettingsView: View {
    @EnvironmentObject var model: CaptureModel
    @Environment(\.dismiss) private var dismiss
    @State private var iso: Double = 100
    @State private var shutterDenominator: Double = 120
    @State private var temperature: Double = 5000
    @State private var tint: Double = 0

    var body: some View {
        NavigationStack {
            Form {
                if let r = model.camera.ranges {
                    Section("Exposure") {
                        Slider(value: $iso, in: Double(r.iso.lowerBound)...Double(r.iso.upperBound)) { Text("ISO") }
                        Text("ISO \(Int(iso))")
                        Slider(value: $shutterDenominator, in: (1 / r.shutter.upperBound)...min(1 / r.shutter.lowerBound, 2000)) { Text("Shutter") }
                        Text("Shutter 1/\(Int(shutterDenominator)) s")
                    }
                    Section("White balance") {
                        Slider(value: $temperature, in: 2500...8000) { Text("Temperature") }
                        Text("\(Int(temperature)) K")
                        Slider(value: $tint, in: -100...100) { Text("Tint") }
                        Text("Tint \(Int(tint))")
                    }
                    Section {
                        Button("Apply and lock") {
                            model.applyCamera(iso: iso, shutter: 1 / shutterDenominator, wbTemperature: temperature, wbTint: tint)
                            dismiss()
                        }
                        Button("Back to auto") { model.applyCamera(iso: nil, shutter: nil, wbTemperature: nil, wbTint: nil, lock: false); dismiss() }
                    }
                } else {
                    Text("No configurable capture device (start the AR session first).")
                }
                Section("Supported video formats") {
                    Text(model.supportedFormatsDescription()).font(.caption.monospaced())
                }
            }
            .navigationTitle("Camera")
            .onAppear {
                let s = model.camera.currentSettings(locked: model.cameraSettings.locked)
                iso = s.iso ?? 100
                shutterDenominator = 1 / max(s.shutter ?? (1.0 / 120), 1e-4)
                temperature = s.wbTemperature ?? 5000
                tint = s.wbTint ?? 0
            }
        }
    }
}

struct SessionsView: View {
    @EnvironmentObject var model: CaptureModel
    @Environment(\.dismiss) private var dismiss
    @State private var share: URL?

    var body: some View {
        NavigationStack {
            List(model.sessions, id: \.self) { url in
                HStack {
                    VStack(alignment: .leading) {
                        Text(url.lastPathComponent).font(.caption.monospaced())
                        Text(Self.summary(url)).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if FileManager.default.fileExists(atPath: url.appendingPathComponent("worldmap.bin").path) {
                        Button("Use for live") { model.startLive(scan: url); dismiss() }
                    }
                    Button("Export") { share = url }
                }
            }
            .navigationTitle("Sessions")
            .sheet(item: $share) { url in ShareSheet(items: [url]) }
        }
    }

    static func summary(_ url: URL) -> String {
        let fm = FileManager.default
        let lines = (try? String(contentsOf: url.appendingPathComponent("frames.jsonl"), encoding: .utf8))?
            .split(separator: "\n").count ?? 0
        let size = (fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])?.allObjects as? [URL] ?? [])
            .compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }.reduce(0, +)
        return "\(lines) frames, \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))"
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

/// Share sheet for a session folder (AirDrop, Files, ...). Session folders are also visible in the Files app
/// and in Finder (UIFileSharingEnabled).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
