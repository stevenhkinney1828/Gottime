import XCTest
@testable import GotTimeMocks
import GotTimeCore

final class MockConnectionServiceTests: XCTestCase {
    func testFetchConnectionsReturnsSeedData() async throws {
        let service = MockConnectionService()
        let connections = try await service.fetchConnections()
        XCTAssertEqual(connections.count, MockData.defaultConnections.count)
    }

    func testCreateInviteProducesASixCharacterCode() async throws {
        let service = MockConnectionService()
        let invite = try await service.createInvite()
        XCTAssertEqual(invite.inviteCode.count, 6)
        XCTAssertEqual(invite.status, .pending)
    }

    func testRedeemInviteAddsAConnection() async throws {
        let service = MockConnectionService(connections: [])
        var connections = try await service.fetchConnections()
        XCTAssertEqual(connections.count, 0)

        _ = try await service.redeemInvite(code: "ABC123")
        connections = try await service.fetchConnections()
        XCTAssertEqual(connections.count, 1)
    }

    func testRedeemInviteRejectsBlankCode() async {
        let service = MockConnectionService()
        do {
            _ = try await service.redeemInvite(code: "   ")
            XCTFail("expected invalidInviteCode to be thrown")
        } catch {
            XCTAssertEqual(error as? MockServiceError, .invalidInviteCode)
        }
    }

    func testRemoveConnection() async throws {
        let service = MockConnectionService()
        let before = try await service.fetchConnections()
        guard let first = before.first else { return XCTFail("expected seed data") }

        try await service.removeConnection(id: first.connectionId)
        let after = try await service.fetchConnections()
        XCTAssertEqual(after.count, before.count - 1)
        XCTAssertFalse(after.contains { $0.connectionId == first.connectionId })
    }
}
