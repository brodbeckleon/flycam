import Foundation
import XCTest
@testable import FlyCamGoldenSupport
@testable import FlyCamKit

/// docs/protocol.md section 6: Swift and Python encode and decode the same packets and session files.
final class GoldenTests: XCTestCase {
    let golden = repoRoot.appendingPathComponent("Tools/testdata/golden")

    func testPythonGoldenFilesVerifyInSwift() {
        let dir = golden.appendingPathComponent("from_python")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("packets.bin").path))
        XCTAssertEqual(GoldenVerifier.verify(dir), [])
    }

    func testSwiftGoldenFilesVerifyInSwift() {
        XCTAssertEqual(GoldenVerifier.verify(golden.appendingPathComponent("from_swift")), [])
    }

    /// The committed Swift golden files are exactly what the current code writes.
    func testSwiftGoldenFilesAreUpToDate() throws {
        let tmp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try GoldenWriter.write(to: tmp)
        let committed = golden.appendingPathComponent("from_swift")
        for file in ["packets.bin", "packets.json", "control.bin", "control.json", "session/meta.json",
                     "session/frames.jsonl", "camera.json", "transition.json", "clock.json"] {
            let a = try Data(contentsOf: tmp.appendingPathComponent(file))
            let b = try Data(contentsOf: committed.appendingPathComponent(file))
            XCTAssertEqual(a, b, "\(file) is stale: run `swift run flycam-golden`")
        }
    }

    /// The verifier must catch a corrupted file, otherwise the tests above prove nothing.
    func testVerifierDetectsCorruption() throws {
        let tmp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try GoldenWriter.write(to: tmp)
        var bin = try Data(contentsOf: tmp.appendingPathComponent("packets.bin"))
        bin[4 + 12] ^= 0x01   // flip a bit in the first packet's timestamp
        try bin.write(to: tmp.appendingPathComponent("packets.bin"))
        let t = try String(contentsOf: tmp.appendingPathComponent("transition.json"), encoding: .utf8)
        try t.replacingOccurrences(of: "\"axes_midpoint\"", with: "\"median_depth\"")
            .write(to: tmp.appendingPathComponent("transition.json"), atomically: true, encoding: .utf8)
        let problems = GoldenVerifier.verify(tmp)
        XCTAssertTrue(problems.contains { $0.contains("timestamp") }, "\(problems)")
        XCTAssertTrue(problems.contains { $0.contains("method") }, "\(problems)")
    }
}
