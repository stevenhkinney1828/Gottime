import Foundation
import GotTimeCore

/// Development-only ConnectionService. Real invite generation/redemption against Supabase
/// lands in Phase 3.
public final class MockConnectionService: ConnectionService, @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [ConnectedPerson]

    public init(connections: [ConnectedPerson] = MockData.defaultConnections) {
        self.connections = connections
    }

    public func fetchConnections() async throws -> [ConnectedPerson] {
        lock.lock()
        defer { lock.unlock() }
        return connections
    }

    public func createInvite() async throws -> ConnectionInvite {
        ConnectionInvite(
            id: UUID(),
            inviteCode: Self.randomCode(),
            status: .pending,
            expiresAt: Date().addingTimeInterval(60 * 60 * 24 * 7),
            createdAt: .now
        )
    }

    /// Any non-blank code "successfully" redeems in mock mode, creating a new connected
    /// person — good enough to exercise the People-list-gains-a-person UI path without a
    /// real second account.
    public func redeemInvite(code: String) async throws -> ConnectedPerson {
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MockServiceError.invalidInviteCode
        }
        let newPerson = ConnectedPerson(
            connectionId: UUID(),
            profile: Profile(id: UUID(), firstName: "New Friend", createdAt: .now, updatedAt: .now)
        )
        lock.lock()
        connections.append(newPerson)
        lock.unlock()
        return newPerson
    }

    public func removeConnection(id: UUID) async throws {
        lock.lock()
        connections.removeAll { $0.connectionId == id }
        lock.unlock()
    }

    private static func randomCode() -> String {
        let characters = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        return String((0..<6).compactMap { _ in characters.randomElement() })
    }
}
