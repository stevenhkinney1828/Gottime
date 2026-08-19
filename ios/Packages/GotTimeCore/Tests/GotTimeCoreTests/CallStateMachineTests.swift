import XCTest
@testable import GotTimeCore

final class CallStateMachineTests: XCTestCase {
    // MARK: - Full transition table (11x11 = 121 combinations)

    /// Independently transcribed from CallStateMachine's own table on purpose — this test
    /// exists to catch a transcription slip between intent and implementation, so it must not
    /// simply read `CallStateMachine.allowedTransitions` and compare it to itself.
    private let expectedTransitions: [CallStatus: Set<CallStatus>] = [
        .created: [.outgoing, .failed],
        .outgoing: [.ringing, .canceled, .failed],
        .ringing: [.connected, .declined, .canceled, .missed, .failed],
        .connected: [.endedEarly, .timedOut, .failed],
        .timedOut: [.completed],
        .declined: [],
        .missed: [],
        .failed: [],
        .canceled: [],
        .endedEarly: [],
        .completed: [],
    ]

    func testEveryStatusPairMatchesTheExpectedTable() {
        for from in CallStatus.allCases {
            for to in CallStatus.allCases {
                let expected = (from == to) || (expectedTransitions[from]?.contains(to) ?? false)
                let actual = CallStateMachine.canTransition(from: from, to: to)
                XCTAssertEqual(actual, expected, "\(from) -> \(to) expected \(expected) but got \(actual)")
            }
        }
    }

    func testSameStateIsAlwaysAllowedIdempotently() {
        for status in CallStatus.allCases {
            XCTAssertTrue(CallStateMachine.canTransition(from: status, to: status), "\(status)")
        }
    }

    func testTerminalStatusesHaveNoOutgoingTransitions() {
        for status in CallStatus.allCases where status.isTerminal {
            for to in CallStatus.allCases where to != status {
                XCTAssertFalse(
                    CallStateMachine.canTransition(from: status, to: to),
                    "\(status) is terminal but allows -> \(to)"
                )
            }
        }
    }

    func testTimedOutIsNotTerminalButOnlyLeadsToCompleted() {
        XCTAssertFalse(CallStatus.timedOut.isTerminal)
        for to in CallStatus.allCases where to != .timedOut && to != .completed {
            XCTAssertFalse(CallStateMachine.canTransition(from: .timedOut, to: to), "timedOut -> \(to)")
        }
        XCTAssertTrue(CallStateMachine.canTransition(from: .timedOut, to: .completed))
    }

    func testTransitionThrowsOnInvalidMove() {
        XCTAssertThrowsError(try CallStateMachine.transition(from: .created, to: .connected)) { error in
            XCTAssertEqual(error as? CallTransitionError, .invalidTransition(from: .created, to: .connected))
        }
    }

    func testTransitionSucceedsOnValidMove() throws {
        let result = try CallStateMachine.transition(from: .ringing, to: .connected)
        XCTAssertEqual(result, .connected)
    }

    func testCannotExtendAnActiveCall() {
        // No status represents "extended," and connected's only non-failure exits are
        // endedEarly and timedOut — there is structurally no path back to a fresh countdown.
        // Regression-proofs spec section 2: "the current call cannot be extended."
        XCTAssertEqual(CallStateMachine.allowedTransitions[.connected], [.endedEarly, .timedOut, .failed])
    }

    // MARK: - apply(): timestamp/duration stamping

    private func makeSession(status: CallStatus = .created) -> CallSession {
        CallSession(
            id: UUID(),
            callUUID: UUID(),
            callerId: UUID(),
            recipientId: UUID(),
            requestedDurationSeconds: 600,
            initiatedAt: .now,
            status: status,
            createdAt: .now,
            updatedAt: .now
        )
    }

    func testHappyPathStampsTimestampsCorrectly() throws {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var session = makeSession(status: .created)

        session = try CallStateMachine.apply(.outgoing, to: session, at: t0)
        XCTAssertEqual(session.status, .outgoing)

        let ringingAt = t0.addingTimeInterval(1)
        session = try CallStateMachine.apply(.ringing, to: session, at: ringingAt)
        XCTAssertEqual(session.ringingAt, ringingAt)

        let connectedAt = t0.addingTimeInterval(15)
        session = try CallStateMachine.apply(.connected, to: session, at: connectedAt)
        XCTAssertEqual(session.connectedAt, connectedAt)
        XCTAssertNil(session.endedAt)
        XCTAssertNil(session.actualDurationSeconds)

        let timedOutAt = connectedAt.addingTimeInterval(600)
        session = try CallStateMachine.apply(.timedOut, to: session, at: timedOutAt)
        XCTAssertEqual(session.endedAt, timedOutAt)
        XCTAssertEqual(session.actualDurationSeconds, 600)

        let completedAt = timedOutAt.addingTimeInterval(0.5)
        session = try CallStateMachine.apply(.completed, to: session, at: completedAt)
        XCTAssertEqual(session.status, .completed)
        // Must NOT move to the later completed timestamp — the call actually ended at
        // timedOut; completed is just teardown confirmation arriving afterward.
        XCTAssertEqual(session.endedAt, timedOutAt)
        XCTAssertEqual(session.actualDurationSeconds, 600)
    }

    func testEndedEarlyComputesPartialDuration() throws {
        let connectedAt = Date(timeIntervalSince1970: 2_000_000)
        var session = makeSession(status: .connected)
        session.connectedAt = connectedAt

        let endedAt = connectedAt.addingTimeInterval(137)
        session = try CallStateMachine.apply(.endedEarly, to: session, at: endedAt)

        XCTAssertEqual(session.status, .endedEarly)
        XCTAssertEqual(session.endedAt, endedAt)
        XCTAssertEqual(session.actualDurationSeconds, 137)
    }

    func testDeclinedNeverGetsAConnectedDuration() throws {
        var session = makeSession(status: .ringing)
        session = try CallStateMachine.apply(.declined, to: session, at: .now)

        XCTAssertNil(session.connectedAt)
        XCTAssertNil(session.actualDurationSeconds)
        XCTAssertNotNil(session.endedAt)
    }

    func testApplyThrowsOnInvalidTransitionAndSessionIsUntouched() {
        let session = makeSession(status: .created)
        XCTAssertThrowsError(try CallStateMachine.apply(.completed, to: session, at: .now))
        // `session` is a value type — the failed call above operated on a copy, so the
        // original binding is provably unaffected. Asserting on it directly is the test.
        XCTAssertEqual(session.status, .created)
    }

    func testIdempotentReapplicationDoesNotOverwriteTimestamp() throws {
        let firstRingingAt = Date(timeIntervalSince1970: 3_000_000)
        var session = makeSession(status: .outgoing)
        session = try CallStateMachine.apply(.ringing, to: session, at: firstRingingAt)

        let duplicateCallbackAt = firstRingingAt.addingTimeInterval(2)
        session = try CallStateMachine.apply(.ringing, to: session, at: duplicateCallbackAt)

        XCTAssertEqual(
            session.ringingAt, firstRingingAt,
            "a duplicate status callback must not move the original timestamp"
        )
    }

    // MARK: - Named real-world paths from spec sections 19-20

    func testCallerCancelsWhileRinging() throws {
        var session = makeSession(status: .outgoing)
        session = try CallStateMachine.apply(.ringing, to: session, at: .now)
        session = try CallStateMachine.apply(.canceled, to: session, at: .now)

        XCTAssertEqual(session.status, .canceled)
        XCTAssertTrue(session.status.isTerminal)
        XCTAssertFalse(session.status.wasEverConnected)
    }

    func testNoAnswerBecomesMissed() throws {
        var session = makeSession(status: .outgoing)
        session = try CallStateMachine.apply(.ringing, to: session, at: .now)
        session = try CallStateMachine.apply(.missed, to: session, at: .now)
        XCTAssertEqual(session.status, .missed)
    }

    func testMidCallNetworkFailureIsDistinctFromEndedEarly() throws {
        var session = makeSession(status: .connected)
        session.connectedAt = .now
        session = try CallStateMachine.apply(.failed, to: session, at: .now.addingTimeInterval(10))
        XCTAssertEqual(session.status, .failed)
        XCTAssertNotNil(session.actualDurationSeconds, "a mid-call failure still records how long it was actually connected")
    }
}
