import Foundation

/// Reconnect delays: exponential with full jitter, 1 s → 2 → 4 … capped at 5 minutes.
/// Pure, so the schedule can be tested without a clock.
public enum Backoff {
    public static let base: TimeInterval = 1
    public static let cap: TimeInterval = 300
    /// A connection that stayed up this long resets the attempt counter.
    public static let healthyAfter: TimeInterval = 60

    /// The top of the jitter window for the nth retry (`attempt` 0 is the first).
    public static func ceiling(attempt: Int) -> TimeInterval {
        let exponent = min(max(attempt, 0), 20)
        return min(cap, base * Double(1 << exponent))
    }

    /// `random` is in 0...1; the delay is uniform in 0...ceiling.
    public static func delay(attempt: Int, random: Double) -> TimeInterval {
        ceiling(attempt: attempt) * min(max(random, 0), 1)
    }

    public static func delay(attempt: Int) -> TimeInterval {
        delay(attempt: attempt, random: Double.random(in: 0...1))
    }
}
