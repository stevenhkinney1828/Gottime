import XCTest
@testable import GotTimeMocks
import GotTimeCore

final class MockCallHistoryServiceTests: XCTestCase {
    func testFetchHistoryReturnsSeedDataCoveringAllSixOutcomes() async throws {
        let service = MockCallHistoryService()
        let history = try await service.fetchHistory()

        let statuses = Set(history.map(\.session.status))
        let expected: Set<CallStatus> = [.completed, .endedEarly, .declined, .missed, .canceled, .failed]
        XCTAssertEqual(statuses, expected, "seed data should cover every user-facing history outcome from spec section 8")
    }

    func testFetchHistoryIsSortedNewestFirst() async throws {
        let service = MockCallHistoryService()
        let history = try await service.fetchHistory()
        let dates = history.map(\.session.initiatedAt)
        XCTAssertEqual(dates, dates.sorted(by: >))
    }

    func testRecordAppendsAndIsReturnedByFetch() async throws {
        let service = MockCallHistoryService(entries: [])
        let session = CallSession(
            id: UUID(), callUUID: UUID(), callerId: UUID(), recipientId: UUID(),
            requestedDurationSeconds: 300, initiatedAt: .now, status: .completed,
            createdAt: .now, updatedAt: .now
        )
        let entry = CallHistoryEntry(session: session, otherPerson: MockData.chris, isOutgoing: true)
        service.record(entry)

        let history = try await service.fetchHistory()
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.id, entry.id)
    }
}
