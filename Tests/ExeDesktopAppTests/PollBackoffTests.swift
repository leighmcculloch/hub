import XCTest
@testable import ExeDesktopApp

/// Widening the poll gap while a VM is unreachable.
final class PollBackoffTests: XCTestCase {

    /// A healthy VM must keep the normal cadence — backoff is invisible until
    /// something fails.
    func testStartsAtTheBaseInterval() {
        XCTAssertEqual(PollBackoff().delay, PollBackoff.base)
    }

    func testFirstFailureStillWaitsTheBaseInterval() {
        var backoff = PollBackoff()
        backoff.recordFailure()
        XCTAssertEqual(backoff.delay, PollBackoff.base)
    }

    func testEachFailureDoublesTheWait() {
        var backoff = PollBackoff()
        var seen: [Duration] = []
        for _ in 0..<4 {
            backoff.recordFailure()
            seen.append(backoff.delay)
        }
        XCTAssertEqual(seen, [
            PollBackoff.base,
            PollBackoff.base * 2,
            PollBackoff.base * 4,
            PollBackoff.base * 8,
        ])
    }

    /// Waiting longer than the cap only delays noticing the VM came back.
    func testNeverExceedsTheMaximum() {
        var backoff = PollBackoff()
        for _ in 0..<200 { backoff.recordFailure() }
        XCTAssertEqual(backoff.delay, PollBackoff.maximum)
    }

    /// A VM left unreachable overnight keeps counting failures; the exponent
    /// has to stay bounded or the shift behind `delay` overflows.
    func testSurvivesAVeryLongOutage() {
        var backoff = PollBackoff()
        for _ in 0..<100_000 { backoff.recordFailure() }
        XCTAssertEqual(backoff.delay, PollBackoff.maximum)
    }

    /// Recovery is what matters most: one good poll returns to the fast cadence
    /// rather than leaving the sidebar sluggish for the rest of the session.
    func testOneSuccessResetsToTheBaseInterval() {
        var backoff = PollBackoff()
        for _ in 0..<10 { backoff.recordFailure() }
        XCTAssertGreaterThan(backoff.delay, PollBackoff.base)

        backoff.recordSuccess()
        XCTAssertEqual(backoff.delay, PollBackoff.base)
        XCTAssertEqual(backoff.consecutiveFailures, 0)
    }

    func testSuccessesOnAHealthyVMChangeNothing() {
        var backoff = PollBackoff()
        for _ in 0..<5 { backoff.recordSuccess() }
        XCTAssertEqual(backoff.delay, PollBackoff.base)
    }

    /// A flapping VM shouldn't accumulate: failure, recovery, failure starts
    /// over rather than resuming where the last outage left off.
    func testAlternatingOutcomesDoNotAccumulate() {
        var backoff = PollBackoff()
        for _ in 0..<5 {
            backoff.recordFailure()
            backoff.recordSuccess()
        }
        backoff.recordFailure()
        XCTAssertEqual(backoff.delay, PollBackoff.base)
    }

    /// The cap has to be reachable by doubling from the base, otherwise the
    /// delay would jump to the cap from well under it.
    func testTheDelayApproachesTheCapByDoubling() {
        var backoff = PollBackoff()
        var previous = PollBackoff.base
        var reachedCap = false
        for _ in 0..<20 {
            backoff.recordFailure()
            XCTAssertGreaterThanOrEqual(backoff.delay, previous)
            XCTAssertLessThanOrEqual(backoff.delay, previous * 2)
            previous = backoff.delay
            if backoff.delay == PollBackoff.maximum { reachedCap = true }
        }
        XCTAssertTrue(reachedCap, "should settle at the cap during a sustained outage")
    }

    func testTheBaseIsShorterThanTheMaximum() {
        XCTAssertLessThan(PollBackoff.base, PollBackoff.maximum)
    }
}
