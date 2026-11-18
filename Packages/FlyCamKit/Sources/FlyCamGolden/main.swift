// Writes the Swift golden files (docs/protocol.md section 6).
// Usage: swift run flycam-golden [output-dir]   (default: ../../Tools/testdata/golden/from_swift)

import Foundation
import FlyCamGoldenSupport

let defaultDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() // Packages/FlyCamKit
    .deletingLastPathComponent().deletingLastPathComponent()                              // repo
    .appendingPathComponent("Tools/testdata/golden/from_swift")
let args = CommandLine.arguments.dropFirst()
let out = args.first.map { URL(fileURLWithPath: $0) } ?? defaultDir
do {
    try GoldenWriter.write(to: out)
    print("wrote \(out.path)")
    let problems = GoldenVerifier.verify(out)
    if !problems.isEmpty {
        problems.forEach { print("problem: \($0)") }
        exit(1)
    }
} catch {
    print("error: \(error)")
    exit(1)
}
