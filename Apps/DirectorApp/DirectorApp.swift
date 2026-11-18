import SwiftUI
import DirectorCore

@main
struct DirectorApp: App {
    var body: some Scene {
        WindowGroup("FlyCam Director") {
            Text("FlyCam Director \(DirectorCore.version)")
                .frame(minWidth: 640, minHeight: 360)
        }
    }
}
