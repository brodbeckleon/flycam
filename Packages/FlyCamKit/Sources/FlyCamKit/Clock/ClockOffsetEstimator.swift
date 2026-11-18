// NTP-style clock offset estimation (docs/protocol.md 3.4).

import Foundation

public struct ClockSample: Equatable, Sendable, Codable {
    /// Mac time when the ping was sent.
    public var t1: Double
    /// Phone time when the ping was received.
    public var t2: Double
    /// Phone time when the pong was sent.
    public var t3: Double
    /// Mac time when the pong was received.
    public var t4: Double

    public init(t1: Double, t2: Double, t3: Double, t4: Double) {
        self.t1 = t1
        self.t2 = t2
        self.t3 = t3
        self.t4 = t4
    }

    /// `t_mac - t_phone`.
    public var offset: Double { ((t1 - t2) + (t4 - t3)) / 2 }

    /// Round trip time excluding the phone's processing time.
    public var roundTrip: Double { (t4 - t1) - (t3 - t2) }
}

/// Keeps the most recent samples and uses the one with the smallest round trip.
public struct ClockOffsetEstimator: Sendable {
    public let window: Int
    public private(set) var samples: [ClockSample] = []

    public init(window: Int = 60) {
        precondition(window > 0, "window must be positive")
        self.window = window
    }

    /// Adds a sample. Samples with negative round trip (clock went backwards or bad data) are rejected.
    @discardableResult
    public mutating func add(_ s: ClockSample) -> Bool {
        guard s.roundTrip >= 0, s.t4 >= s.t1, s.t3 >= s.t2 else { return false }
        samples.append(s)
        if samples.count > window { samples.removeFirst(samples.count - window) }
        return true
    }

    public var best: ClockSample? {
        // Ties: the most recent sample wins.
        var best: ClockSample?
        for s in samples where best == nil || s.roundTrip <= best!.roundTrip {
            best = s
        }
        return best
    }

    /// `t_mac - t_phone`, nil until the first sample.
    public var offset: Double? { best?.offset }

    /// Upper bound of the error of `offset`: half the round trip of the best sample.
    public var uncertainty: Double? { best.map { $0.roundTrip / 2 } }

    public func macTime(phoneTime t: Double) -> Double? {
        offset.map { t + $0 }
    }
}
