import Foundation

/// How long to wait before the next poll of a VM.
///
/// The diff sidebar polls over SSH every few seconds. When a VM is unreachable
/// each attempt costs a full connect timeout, so polling at the normal rate
/// leaves an ssh process permanently in flight against a machine that is down.
/// Failures widen the gap; the first success snaps it back.
struct PollBackoff {
    /// The gap between polls while the VM is answering.
    static let base: Duration = .seconds(3)
    /// The widest gap. Past this, waiting longer only delays noticing recovery.
    static let maximum: Duration = .seconds(30)

    private(set) var consecutiveFailures = 0

    /// Doubles per consecutive failure, from `base` up to `maximum`.
    var delay: Duration {
        guard consecutiveFailures > 0 else { return Self.base }
        // Bound the exponent before shifting: a VM left unreachable for hours
        // counts up far past the cap, and the shift itself would overflow.
        let doublings = min(consecutiveFailures - 1, 16)
        let scaled = Self.base * (1 << doublings)
        return min(scaled, Self.maximum)
    }

    mutating func recordSuccess() {
        consecutiveFailures = 0
    }

    mutating func recordFailure() {
        consecutiveFailures += 1
    }
}
