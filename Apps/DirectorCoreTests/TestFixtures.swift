import Foundation
@testable import DirectorCore

/// Generated fixtures shared by the tests of one run (written once into a temporary directory).
actor TestFixtures {
    static let shared = TestFixtures()

    struct TwoCamera {
        let dir: URL
        let splat: URL
        let sessionA: URL
        let sessionB: URL
    }

    private var twoCamera: TwoCamera?

    func twoCameraFixture() async throws -> TwoCamera {
        if let f = twoCamera { return f }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("flycam-fixture-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: dir)
        let (splat, a, b) = try await SyntheticSession.writeTwoCameraFixture(to: dir, frameCount: 60, fps: 30,
                                                                              context: try MetalContext.shared())
        let f = TwoCamera(dir: dir, splat: splat, sessionA: a, sessionB: b)
        twoCamera = f
        return f
    }
}
