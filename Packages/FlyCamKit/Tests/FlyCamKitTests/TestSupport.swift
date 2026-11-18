import Foundation
import XCTest
@testable import FlyCamKit

/// Deterministic random numbers for tests (SplitMix64).
struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uniform(_ lo: Double, _ hi: Double) -> Double {
        Double.random(in: lo..<hi, using: &self)
    }
}

/// c2w looking from `eye` towards `target` with world +Y up (ARKit convention: camera -Z looks at target).
func lookAt(eye: Vec3, target: Vec3, up: Vec3 = .unitY) -> Mat4 {
    Mat4.lookAt(eye: eye, target: target, up: up)
}

func randomRotation(_ rng: inout SeededRNG) -> Mat3 {
    let axis = Vec3(rng.uniform(-1, 1), rng.uniform(-1, 1), rng.uniform(-1, 1))
    return Quat(axis: axis.length > 1e-3 ? axis : .unitY, angle: rng.uniform(-Double.pi, Double.pi)).matrix
}

let hd = Intrinsics(fx: 1500.5, fy: 1499.25, cx: 961.3, cy: 538.7, width: 1920, height: 1080)

func XCTAssertVecEqual(_ a: Vec3, _ b: Vec3, accuracy: Double, _ msg: String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertLessThanOrEqual((a - b).length, accuracy, "\(a) != \(b) \(msg)", file: file, line: line)
}

func XCTAssertMatEqual(_ a: Mat4, _ b: Mat4, accuracy: Double, file: StaticString = #filePath, line: UInt = #line) {
    let d = zip(a.columnMajor, b.columnMajor).map { abs($0 - $1) }.max() ?? 0
    XCTAssertLessThanOrEqual(d, accuracy, "\(a.columnMajor) != \(b.columnMajor)", file: file, line: line)
}

/// Repository root, found relative to this source file.
let repoRoot: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // FlyCamKitTests
    .deletingLastPathComponent() // Tests
    .deletingLastPathComponent() // FlyCamKit
    .deletingLastPathComponent() // Packages
    .deletingLastPathComponent() // repo

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("flycamkit-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
