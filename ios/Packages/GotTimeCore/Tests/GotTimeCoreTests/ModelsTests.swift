import XCTest
@testable import GotTimeCore

final class ProfileTests: XCTestCase {
    func makeProfile(firstName: String?) -> Profile {
        Profile(id: UUID(), firstName: firstName, createdAt: .now, updatedAt: .now)
    }

    func testHasCompletedOnboardingIsFalseForNilName() {
        XCTAssertFalse(makeProfile(firstName: nil).hasCompletedOnboarding)
    }

    func testHasCompletedOnboardingIsFalseForBlankName() {
        XCTAssertFalse(makeProfile(firstName: "   ").hasCompletedOnboarding)
    }

    func testHasCompletedOnboardingIsTrueForRealName() {
        XCTAssertTrue(makeProfile(firstName: "Chris").hasCompletedOnboarding)
    }
}

final class CallStatusTests: XCTestCase {
    func testTerminalStatuses() {
        // timedOut is deliberately excluded: it always proceeds to completed, so it's not
        // terminal even though it's a post-connection, ending-adjacent state.
        let terminal: Set<CallStatus> = [.declined, .missed, .failed, .canceled, .endedEarly, .completed]
        for status in CallStatus.allCases {
            XCTAssertEqual(status.isTerminal, terminal.contains(status), "\(status)")
        }
    }

    func testWasEverConnectedOnlyForPostConnectionOutcomes() {
        let everConnected: Set<CallStatus> = [.endedEarly, .timedOut, .completed]
        for status in CallStatus.allCases {
            XCTAssertEqual(status.wasEverConnected, everConnected.contains(status), "\(status)")
        }
    }

    func testRawValuesMatchDatabaseStrings() {
        XCTAssertEqual(CallStatus.endedEarly.rawValue, "ended_early")
        XCTAssertEqual(CallStatus.timedOut.rawValue, "timed_out")
        XCTAssertEqual(CallStatus.created.rawValue, "created")
    }
}

final class CallSessionTests: XCTestCase {
    func makeSession(callerId: UUID, recipientId: UUID) -> CallSession {
        CallSession(
            id: UUID(),
            callUUID: UUID(),
            callerId: callerId,
            recipientId: recipientId,
            requestedDurationSeconds: 600,
            initiatedAt: .now,
            status: .created,
            createdAt: .now,
            updatedAt: .now
        )
    }

    func testIsParticipantAndOtherParticipant() {
        let caller = UUID()
        let recipient = UUID()
        let stranger = UUID()
        let session = makeSession(callerId: caller, recipientId: recipient)

        XCTAssertTrue(session.isParticipant(caller))
        XCTAssertTrue(session.isParticipant(recipient))
        XCTAssertFalse(session.isParticipant(stranger))

        XCTAssertEqual(session.otherParticipant(from: caller), recipient)
        XCTAssertEqual(session.otherParticipant(from: recipient), caller)
        XCTAssertNil(session.otherParticipant(from: stranger))
    }
}

final class ConnectionTests: XCTestCase {
    func testOtherUserId() {
        let a = UUID()
        let b = UUID()
        let stranger = UUID()
        let connection = Connection(id: UUID(), userAId: a, userBId: b, status: .active, createdAt: .now)

        XCTAssertEqual(connection.otherUserId(from: a), b)
        XCTAssertEqual(connection.otherUserId(from: b), a)
        XCTAssertNil(connection.otherUserId(from: stranger))
    }
}

final class ConnectedPersonDisplayNameTests: XCTestCase {
    private func makePerson(firstName: String?, nickname: String?) -> ConnectedPerson {
        ConnectedPerson(
            connectionId: UUID(),
            profile: Profile(id: UUID(), firstName: firstName, createdAt: .now, updatedAt: .now),
            nickname: nickname
        )
    }

    func testDisplayNamePrefersNicknameOverSelfReportedName() {
        XCTAssertEqual(makePerson(firstName: "Thunder", nickname: "Bro").displayName, "Bro")
    }

    func testDisplayNameFallsBackToSelfReportedNameWhenNoNickname() {
        XCTAssertEqual(makePerson(firstName: "Thunder", nickname: nil).displayName, "Thunder")
    }

    func testDisplayNameFallsBackToUnknownWhenNeitherIsSet() {
        XCTAssertEqual(makePerson(firstName: nil, nickname: nil).displayName, "Unknown")
    }
}

final class CallHistoryEntryDisplayNameTests: XCTestCase {
    private func makeEntry(firstName: String?, nickname: String?) -> CallHistoryEntry {
        let profile = Profile(id: UUID(), firstName: firstName, createdAt: .now, updatedAt: .now)
        let session = CallSession(
            id: UUID(),
            callUUID: UUID(),
            callerId: UUID(),
            recipientId: UUID(),
            requestedDurationSeconds: 300,
            initiatedAt: .now,
            status: .completed,
            createdAt: .now,
            updatedAt: .now
        )
        return CallHistoryEntry(session: session, otherPerson: profile, isOutgoing: true, nickname: nickname)
    }

    func testDisplayNamePrefersNicknameOverSelfReportedName() {
        XCTAssertEqual(makeEntry(firstName: "Thunder", nickname: "Bro").displayName, "Bro")
    }

    func testDisplayNameFallsBackToSelfReportedNameWhenNoNickname() {
        XCTAssertEqual(makeEntry(firstName: "Thunder", nickname: nil).displayName, "Thunder")
    }
}
