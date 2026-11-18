// Phone side of live streaming (plan.md Phase 5). Filled in by Track M scope item 6.

import Foundation
import SwiftUI

final class StreamingController: ObservableObject {
    @Published var state = "off"
    @Published var isStreaming = false

    func attach(_ model: CaptureModel) {}
    func start() { state = "not available yet" }
    func stop() { isStreaming = false; state = "off" }
}
