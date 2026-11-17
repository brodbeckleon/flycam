import XCTest
@testable import FlyCamKit

final class MathTests: XCTestCase {
    func testColumnMajorRoundTrip() {
        let values = (0..<16).map { Double($0) + 0.25 }
        let m = Mat4(columnMajor: values)
        XCTAssertEqual(m.columnMajor, values)
        // Column 3 holds elements 12...14 (translation), element (row 0, col 3) is values[12].
        XCTAssertEqual(m[0, 3], values[12])
        XCTAssertEqual(m[3, 0], values[3])
        XCTAssertEqual(m.translation, Vec3(values[12], values[13], values[14]))
    }

    func testRowsAreTransposeOfColumnMajor() {
        let values = (0..<16).map { Double($0) }
        let m = Mat4(columnMajor: values)
        XCTAssertEqual(m.rows[0], [0, 4, 8, 12])
        XCTAssertEqual(m.rows[3], [3, 7, 11, 15])
        XCTAssertEqual(Mat4(rows: m.rows), m)
        XCTAssertEqual(m.transpose.columnMajor, m.rows.flatMap { $0 })
    }

    func testRigidInverse() {
        var rng = SeededRNG(seed: 1)
        for _ in 0..<50 {
            let m = Mat4(rotation: randomRotation(&rng), translation: Vec3(rng.uniform(-5, 5), rng.uniform(-5, 5), rng.uniform(-5, 5)))
            XCTAssertMatEqual(m * m.rigidInverse, .identity, accuracy: 1e-12)
            XCTAssertMatEqual(m.inverse!, m.rigidInverse, accuracy: 1e-12)
            XCTAssertLessThan(m.rigidityError, 1e-12)
        }
    }

    func testGeneralInverseAndSingular() {
        let m = Mat4(columnMajor: [2, 0, 0, 0, 1, 3, 0, 0, 0, 0, 4, 0, 1, 2, 3, 1])
        XCTAssertMatEqual(m * m.inverse!, .identity, accuracy: 1e-12)
        XCTAssertNil(Mat4(columnMajor: [Double](repeating: 1, count: 16)).inverse)
    }

    func testQuaternionMatrixRoundTrip() {
        var rng = SeededRNG(seed: 2)
        for _ in 0..<200 {
            let r = randomRotation(&rng)
            let q = Quat(r)
            XCTAssertGreaterThanOrEqual(q.w, 0)
            XCTAssertEqual(q.length, 1, accuracy: 1e-12)
            let r2 = q.matrix
            for i in 0..<3 { for j in 0..<3 { XCTAssertEqual(r[i, j], r2[i, j], accuracy: 1e-12) } }
        }
        // 180 degree rotations exercise the non-trace branches.
        for axis in [Vec3.unitX, .unitY, .unitZ, Vec3(1, 1, 0).normalized] {
            let r = Quat(axis: axis, angle: Double.pi).matrix
            let r2 = Quat(r).matrix
            for i in 0..<3 { for j in 0..<3 { XCTAssertEqual(r[i, j], r2[i, j], accuracy: 1e-12) } }
        }
    }

    func testSlerp() {
        let a = Quat(axis: .unitY, angle: 0.2)
        let b = Quat(axis: .unitY, angle: 1.4)
        XCTAssertEqual(Quat.slerp(a, b, 0), a)
        XCTAssertEqual(Quat.slerp(a, b, 1), b)
        let mid = Quat.slerp(a, b, 0.5)
        XCTAssertEqual(mid.angle(to: Quat(axis: .unitY, angle: 0.8)), 0, accuracy: 1e-9)
        // Shortest path: b and -b give the same rotation.
        let mid2 = Quat.slerp(a, b.negated, 0.5)
        XCTAssertEqual(mid2.angle(to: mid), 0, accuracy: 1e-9)
        // Constant angular speed.
        let q1 = Quat.slerp(a, b, 0.25), q3 = Quat.slerp(a, b, 0.75)
        XCTAssertEqual(a.angle(to: q1), 0.3, accuracy: 1e-9)
        XCTAssertEqual(q3.angle(to: b), 0.3, accuracy: 1e-9)
    }

    func testSlerpDirection() {
        let a = Vec3(1, 0, 0), b = Vec3(0, 0, 1)
        XCTAssertEqual(slerpDirection(a, b, 0), a)
        XCTAssertEqual(slerpDirection(a, b, 1), b)
        XCTAssertVecEqual(slerpDirection(a, b, 0.5), Vec3(1, 0, 1).normalized, accuracy: 1e-12)
        // Antiparallel: stays unit length, rotates about the fallback axis (perpendicular to Y here).
        let m = slerpDirection(a, -a, 0.5)
        XCTAssertEqual(m.length, 1, accuracy: 1e-12)
        XCTAssertEqual(m.y, 0, accuracy: 1e-12)
        XCTAssertEqual(m.dot(a), 0, accuracy: 1e-9)
    }
}
