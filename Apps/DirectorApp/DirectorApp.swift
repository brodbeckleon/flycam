// FlyCam Director (macOS): program output with preview/take, splat viewer, live cameras.
// A thin shell over DirectorCore; headless use goes through director-cli.

import SwiftUI
import UniformTypeIdentifiers
import DirectorCore
import FlyCamKit

@main
struct DirectorApp: App {
    @StateObject private var model = DirectorModel()

    var body: some Scene {
        WindowGroup("FlyCam Director") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 960, minHeight: 600)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: DirectorModel
    @State private var tab = 0
    @State private var importingSplat = false
    @State private var importingSession = false
    @State private var iso = 100.0
    @State private var shutterDen = 120.0
    @State private var kelvin = 5000.0
    @State private var tint = 0.0

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Splat: \(model.splatName)").font(.caption)
                Button("Load splat…") { importingSplat = true }
                Button("Add recorded session…") { importingSession = true }
                Divider()
                Text("Cameras").bold()
                ForEach(model.sourceNames.keys.sorted(), id: \.self) { id in
                    HStack {
                        Text(model.sourceNames[id] ?? "").font(.caption)
                        Spacer()
                        if id == model.program { Text("PGM").foregroundStyle(.red).bold() }
                        if id == model.preview { Text("PVW").foregroundStyle(.green).bold() }
                        Button("Preview") { model.selectPreview(id) }.disabled(model.inFlight || id == model.program)
                    }
                }
                Button(model.inFlight ? "In flight…" : "Take (space)") { model.take() }
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(model.preview == nil || model.inFlight)
                Divider()
                Text("Live").bold()
                Text("port \(model.serverPort.map(String.init) ?? "-")").font(.caption)
                ForEach(model.liveCameras, id: \.cameraID) { c in
                    VStack(alignment: .leading) {
                        Text("#\(c.cameraID) \(c.hello.deviceModel) \(c.connected ? "" : "(disconnected)")")
                        Text(String(format: "offset %.4f s ± %.1f ms, %d frames", c.offset ?? .nan, (c.offsetUncertainty ?? .nan) * 1000, c.framesDecoded))
                        if let s = c.lastStatus {
                            Text(String(format: "battery %.0f%%  %@  %.1f fps  %@", s.battery * 100, s.thermalState, s.fps, s.recording ? "REC" : ""))
                        }
                    }.font(.caption)
                }
                Button(model.recording ? "Stop recording on all phones" : "Record on all phones") { model.toggleRecording() }
                HStack {
                    TextField("ISO", value: $iso, format: .number).frame(width: 50)
                    TextField("1/s", value: $shutterDen, format: .number).frame(width: 50)
                    TextField("K", value: $kelvin, format: .number).frame(width: 55)
                    TextField("tint", value: $tint, format: .number).frame(width: 40)
                }.font(.caption)
                Button("Push camera settings to all phones") {
                    model.pushSettings(iso: iso, shutter: 1 / max(shutterDen, 1), wbTemperature: kelvin, wbTint: tint)
                }
                Spacer()
                Text(model.message).font(.caption).foregroundStyle(.secondary)
            }
            .padding()
            .frame(minWidth: 280, maxWidth: 360)

            TabView(selection: $tab) {
                ProgramView(model: model).tabItem { Text("Program") }.tag(0)
                SplatViewer(model: model).tabItem { Text("Splat viewer") }.tag(1)
            }
        }
        .fileImporter(isPresented: $importingSplat, allowedContentTypes: [.data]) { r in
            if case .success(let url) = r { model.loadSplat(url) }
        }
        .fileImporter(isPresented: $importingSession, allowedContentTypes: [.folder]) { r in
            if case .success(let url) = r { model.addSession(url) }
        }
    }
}
