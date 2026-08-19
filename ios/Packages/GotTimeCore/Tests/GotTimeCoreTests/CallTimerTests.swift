import XCTest
@testable import GotTimeCore

final class CallTimerTests: XCTestCase {
    let connectedAt = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Basic math

    func testExpiresAtIsConnectedPlusDuration() {
        let timer = CallTimer(connectedAt: connectedAt, requestedDurationSeconds: 600)
        XCTAssertEqual(timer.expiresAt, connectedAt.addingTimeInterval(600))
    }

    func testRemainingAtConnectionEqualsFullDuration() {
        let timer = CallTimer(connectedAt: connectedAt, requestedDurationSeconds: 600)
        XCTAssertEqual(timer.remainingSeconds(at: connectedAt), 600)
        XCTAssertEqual(timer.elapsedSeconds(at: connectedAt), 0)
    }

    func testRemainingAndElapsedAtHalfway() {
        let timer = CallTimer(connectedAt: connectedAt, requestedDurationSeconds: 600)
        let halfway = connectedAt.addingTimeInterval(300)
        XCTAssertEqual(timer.remainingSeconds(at: halfway), 300)
        XCTAssertEqual(timer.elapsedSeconds(at: halfway), 300)
    }

    func testRemainingNeverGoesNegative() {
        let timer = CallTimer(connectedAt: connectedAt, requestedDurationSeconds: 600)
        let wayPastExpiry = connectedAt.addingTimeInterval(10_000)
        XCTAssertEqual(timer.remainingSeconds(at: wayPastExpiry), 0)
    }

    func testElapsedNeverExceedsRequestedDuration() {
        let timer = CallTimer(connectedAt: connectedAt, requestedDurationSeconds: 600)
        let wayPastExpiry = connectedAt.addingTimeInterval(10_000)
        XCTAssertEqual(timer.elapsedSeconds(at: wayPastExpiry), 600)
    }

    func testTimeBeforeConnectionClampsToZeroElapsed() {
        // Shouldn't happen in practice (nothing queries a timer before connectedAt), but a
        // clock skew or bad input must not produce a negative elapsed count.
        let timer = CallTimer(connectedAt: connectedAt, requestedDurationSeconds: 600)
        let before = connectedAt.addingTimeInterval(-5)
        XCTAssertEqual(timer.elapsedSeconds(at: before), 0)
        XCTAssertEqual(timer.remainingSeconds(at: before), 600)
    }

    // MARK: - Rounding at second boundaries (no early-flicker, no late-hold)

    func testRemainingDoesNotStepDownUntilAFullSecondHasPassed() {
        let timer = CallTimer(connectedAt: connectedAt, requestedDurationSeconds: 600)
        let almostOneSecond = connectedAt.addingTimeInterval(0.999)
        XCTAssertEqual(timer.remainingSeconds(at: almostOneSecond), 600, "must still read 600 with a second not yet fully elapsed")

        let exactlyOneSecond = connectedAt.addingTimeInterval(1.0)
        XCTAssertEqual(timer.remainingSeconds(at: exactlyOneSecond), 599)
    }

    func testElapsedDoesNotStepUpUntilAFullSecondHasPassed() {
        let timer = CallTimer(connectedAt: connectedAt, requestedDurationSeconds: 600)
        let almostOneSecond = connectedAt.addingTimeInterval(0.999)
        XCTAssertEqual(timer.elapsedSeconds(at: almostOneSecond), 0)

        let exactlyOneSecond = connectedAt.addingTimeInterval(1.0)
        XCTAssertEqual(timer.elapsedSeconds(at: exactlyOneSecond), 1)
    }

    // MARK: - isExpired

    func testIsExpiredExactlyAtBoundary() {
        let timer = CallTimer(connectedAt: connectedAt, requestedDurationSeconds: 600)
        XCTAssertFalse(timer.isExpired(at: connectedAt.addingTimeInterval(599.999)))
        XCTAssertTrue(timer.isExpired(at: connectedAt.addingTimeInterval(600)))
        XCTAssertTrue(timer.isExpired(at: connectedAt.addingTimeInterval(600.001)))
    }

    // MARK: - Warning levels (spec section 6: 60s subtle, final 10s stronger)

    func testWarningLevelTransitions() {
        let timer = CallTimer(connectedAt: connectedAt, requestedDurationSeconds: 600)

        XCTAssertEqual(timer.warningLevel(at: connectedAt.addingTimeInterval(0)), .normal)
        XCTAssertEqual(timer.warningLevel(at: connectedAt.addingTimeInterval(539)), .normal, "61s remaining")
        XCTAssertEqual(timer.warningLevel(at: connectedAt.addingTimeInterval(540)), .oneMinuteRemaining, "exactly 60s remaining")
        XCTAssertEqual(timer.warningLevel(at: connectedAt.addingTimeInterval(589)), .oneMinuteRemaining, "11s remaining")
        XCTAssertEqual(timer.warningLevel(at: connectedAt.addingTimeInterval(590)), .finalTenSeconds, "exactly 10s remaining")
        XCTAssertEqual(timer.warningLevel(at: connectedAt.addingTimeInterval(600)), .finalTenSeconds, "0s remaining")
    }

    func testWarningLevelOnAShortCustomCall() {
        // A 1-minute call: the "60s remaining" and "final 10s" thresholds both apply almost
        // immediately — must not crash or misbehave just because the whole call is short.
        let timer = CallTimer(connectedAt: connectedAt, requestedDurationSeconds: 60)
        XCTAssertEqual(timer.warningLevel(at: connectedAt), .oneMinuteRemaining)
        XCTAssertEqual(timer.warningLevel(at: connectedAt.addingTimeInterval(50)), .finalTenSeconds)
    }

    // MARK: - The core anti-fragility property: background/lock-screen gaps

    func testRemainingTimeIsCorrectAfterASimulatedLongBackgroundGap() {
        // The defining test for spec section 7. No intermediate reads happen between
        // connection and this single read taken 550 seconds later — simulating an app that
        // was backgrounded/locked for that whole span with zero Timer ticks firing. Because
        // remainingSeconds is a pure function of two fixed timestamps and `now`, this must
        // still be exactly correct; there is no accumulated counter to have drifted.
        let timer = CallTimer(connectedAt: connectedAt, requestedDurationSeconds: 600)
        let afterLongGap = connectedAt.addingTimeInterval(550)
        XCTAssertEqual(timer.remainingSeconds(at: afterLongGap), 50)
        XCTAssertEqual(timer.elapsedSeconds(at: afterLongGap), 550)
        XCTAssertEqual(timer.warningLevel(at: afterLongGap), .oneMinuteRemaining, "50s remaining is inside the 60s window, not yet the final 10s")
    }

    func testRemainingTimeIsCorrectWhenBackgroundGapCrossesExpiry() {
        // The app was backgrounded before expiry and resumes well after it — the call must
        // read as fully expired immediately, not "catch up" gradually or show a stale value.
        let timer = CallTimer(connectedAt: connectedAt, requestedDurationSeconds: 600)
        let wayAfterExpiry = connectedAt.addingTimeInterval(900)
        XCTAssertTrue(timer.isExpired(at: wayAfterExpiry))
        XCTAssertEqual(timer.remainingSeconds(at: wayAfterExpiry), 0)
        XCTAssertEqual(timer.elapsedSeconds(at: wayAfterExpiry), 600)
    }

    func testTwoTimersConstructedIdenticallyAlwaysAgree() {
        // Two independent CallTimer values built from the same connectedAt/duration (e.g.
        // one held by a view model, one freshly reconstructed after a process relaunch mid-
        // call) must always agree at any shared "now" — there is no per-instance state that
        // could cause them to diverge.
        let a = CallTimer(connectedAt: connectedAt, requestedDurationSeconds: 300)
        let b = CallTimer(connectedAt: connectedAt, requestedDurationSeconds: 300)
        for offset in stride(from: 0.0, through: 400.0, by: 37.0) {
            let now = connectedAt.addingTimeInterval(offset)
            XCTAssertEqual(a.remainingSeconds(at: now), b.remainingSeconds(at: now))
        }
    }
}
