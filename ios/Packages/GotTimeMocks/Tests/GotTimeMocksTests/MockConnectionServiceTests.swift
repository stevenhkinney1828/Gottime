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

    func testSetNicknameOverridesDisplayName() async throws {
        let service = MockConnectionService()
        let before = try await service.fetchConnections()
        guard let first = before.first else { return XCTFail("expected seed data") }
        XCTAssertNil(first.nickname)

        try await service.setNickname("Bug", for: first.id)
        let after = try await service.fetchConnections()
        guard let renamed = after.first(where: { $0.id == first.id }) else {
            return XCTFail("expected the same person still present")
        }
        XCTAssertEqual(renamed.nickname, "Bug")
        XCTAssertEqual(renamed.displayName, "Bug")
    }

    func testSetNicknameToNilClearsIt() async throws {
        let service = MockConnectionService()
        let before = try await service.fetchConnections()
        guard let first = before.first else { return XCTFail("expected seed data") }

        try await service.setNickname("Bug", for: first.id)
        try await service.setNickname(nil, for: first.id)
        let after = try await service.fetchConnections()
        guard let cleared = after.first(where: { $0.id == first.id }) else {
            return XCTFail("expected the same person still present")
        }
        XCTAssertNil(cleared.nickname)
        XCTAssertEqual(cleared.displayName, first.profile.firstName ?? "Unknown")
    }
}
