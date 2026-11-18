import XCTest
@testable import FlyCamKit

final class ClockTests: XCTestCase {
    func testOffsetFormulaSymmetricDelay() {
        // Phone clock = Mac clock - 1000 (offset +1000), one-way delay 5 ms each way, 1 ms processing.
        let s = ClockSample(t1: 2000.000, t2: 1000.005, t3: 1000.006, t4: 2000.011)
        XCTAssertEqual(s.offset, 1000, accuracy: 1e-9)
        XCTAssertEqual(s.roundTrip, 0.010, accuracy: 1e-9)
    }

    /// plan.md section 5: clock offset estimation on synthetic data.
    func testEstimationOnSyntheticData() {
        var rng = SeededRNG(seed: 11)
        let trueOffset = 1234.5678   // t_mac = t_phone + trueOffset
        var est = ClockOffsetEstimator(window: 60)
        var tMac = 50.0
        for _ in 0..<60 {
            // Asymmetric, heavy-tailed Wi-Fi delays: 2 ms base + exponential jitter, occasional 50 ms spikes.
            func delay() -> Double {
                var d = 0.002 - 0.004 * log(1 - rng.uniform(0, 1))
                if rng.uniform(0, 1) < 0.1 { d += 0.05 }
                return d
            }
            let up = delay(), down = delay(), proc = rng.uniform(0.0001, 0.002)
            let t1 = tMac
            let t2 = t1 + up - trueOffset
            let t3 = t2 + proc
            let t4 = t3 + trueOffset + down
            XCTAssertTrue(est.add(ClockSample(t1: t1, t2: t2, t3: t3, t4: t4)))
            tMac += 1
        }
        let offset = try! XCTUnwrap(est.offset)
        // The error is bounded by half the best round trip; with 60 samples that is about 2-3 ms.
        XCTAssertLessThanOrEqual(abs(offset - trueOffset), est.uncertainty! + 1e-12)
        XCTAssertLessThan(abs(offset - trueOffset), 0.003)
        XCTAssertEqual(est.macTime(phoneTime: 10)!, 10 + offset, accuracy: 1e-12)
    }

    func testMinRoundTripSampleWinsAndWindowSlides() {
        var est = ClockOffsetEstimator(window: 3)
        est.add(ClockSample(t1: 0, t2: 10, t3: 10, t4: 0.010))      // rtt 10 ms, offset -9.995
        est.add(ClockSample(t1: 1, t2: 11, t3: 11, t4: 1.002))      // rtt 2 ms, offset -9.999
        est.add(ClockSample(t1: 2, t2: 12, t3: 12, t4: 2.020))      // rtt 20 ms
        XCTAssertEqual(est.offset!, -9.999, accuracy: 1e-9)
        est.add(ClockSample(t1: 3, t2: 13, t3: 13, t4: 3.030))
        est.add(ClockSample(t1: 4, t2: 14, t3: 14, t4: 4.040))      // the 2 ms sample leaves the window
        XCTAssertEqual(est.samples.count, 3)
        XCTAssertEqual(est.best!.roundTrip, 0.020, accuracy: 1e-9)
    }

    func testRejectsInvalidSamples() {
        var est = ClockOffsetEstimator()
        XCTAssertFalse(est.add(ClockSample(t1: 5, t2: 1, t3: 1, t4: 4)))   // pong before ping
        XCTAssertFalse(est.add(ClockSample(t1: 0, t2: 1, t3: 3, t4: 1)))   // processing longer than round trip
        XCTAssertNil(est.offset)
    }
}

final class FrameStoreTests: XCTestCase {
    func testNearestAndTies() {
        var ring = FrameRing<Int>(capacitySeconds: 10)
        for i in 0..<5 { ring.insert(StoredFrame(macTime: Double(i) * 0.1, frameIndex: UInt32(i), payload: i)) }
        XCTAssertEqual(ring.nearest(to: 0.21)?.payload, 2)
        XCTAssertEqual(ring.nearest(to: 0.26)?.payload, 3)
        XCTAssertEqual(ring.nearest(to: 0.25)?.payload, 2, "tie goes to the earlier frame")
        XCTAssertEqual(ring.nearest(to: -5)?.payload, 0)
        XCTAssertEqual(ring.nearest(to: 5)?.payload, 4)
        XCTAssertNil(FrameRing<Int>().nearest(to: 0))
    }

    func testEvictionKeepsCapacity() {
        var ring = FrameRing<Int>(capacitySeconds: 0.5)
        for i in 0..<100 { ring.insert(StoredFrame(macTime: Double(i) / 30, frameIndex: UInt32(i), payload: i)) }
        XCTAssertLessThanOrEqual(ring.newestTime! - ring.oldestTime!, 0.5)
        XCTAssertEqual(ring.count, 16) // frames within 0.5 s at 30 fps: 99/30 - 0.5 <= t
        XCTAssertEqual(ring.frames.last?.payload, 99)
    }

    func testOutOfOrderInsert() {
        var ring = FrameRing<Int>(capacitySeconds: 1)
        for t in [0.1, 0.3, 0.2, 0.05, 0.4] { ring.insert(StoredFrame(macTime: t, frameIndex: 0, payload: Int(t * 100))) }
        XCTAssertEqual(ring.frames.map(\.payload), [5, 10, 20, 30, 40])
    }

    /// Two unsynchronised 30 fps phones: nearest-frame pairing leaves at most half a frame interval
    /// between each selected frame and the render time, so at most one interval between cameras.
    func testPairingResidual() {
        var store = FrameStore<String>(capacitySeconds: 0.5, playoutDelay: 0.15)
        let dt = 1.0 / 30
        let phaseB = 0.0123
        var maxOffset = 0.0, maxResidual = 0.0
        for i in 0..<300 {
            let t = Double(i) * dt
            store.insert(camera: 0, macTime: t, frameIndex: UInt32(i), payload: "A\(i)")
            store.insert(camera: 1, macTime: t + phaseB, frameIndex: UInt32(i), payload: "B\(i)")
            let now = t + 0.002
            guard now > 0.3 else { continue }
            let pair = store.pair(at: store.renderTime(now: now))
            XCTAssertEqual(pair.frames.count, 2)
            for o in pair.offsets().values { maxOffset = max(maxOffset, abs(o)) }
            maxResidual = max(maxResidual, pair.residual)
        }
        XCTAssertLessThanOrEqual(maxOffset, dt / 2 + 1e-9)
        // Residual between the two cameras equals the phase difference or its complement.
        XCTAssertLessThanOrEqual(maxResidual, max(phaseB, dt - phaseB) + 1e-9)
        XCTAssertEqual(store.cameraIDs, [0, 1])
        XCTAssertEqual(store.pair(at: 1.0, cameras: [1]).frames.count, 1)
    }
}
