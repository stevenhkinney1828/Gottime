import Foundation

public enum ConnectionStatus: String, Codable, Sendable {
    case active
    case removed
}

/// Mirrors the `connections` table. `userAId`/`userBId` order is not meaningful (see the
/// migration) — client code almost always wants ConnectedPerson below instead, which
/// resolves "the other person" directly rather than making every call site figure out which
/// side is "me."
public struct Connection: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public let userAId: UUID
    public let userBId: UUID
    public var status: ConnectionStatus
    public let createdAt: Date

    public init(id: UUID, userAId: UUID, userBId: UUID, status: ConnectionStatus, createdAt: Date) {
        self.id = id
        self.userAId = userAId
        self.userBId = userBId
        self.status = status
        self.createdAt = createdAt
    }

    public func otherUserId(from userId: UUID) -> UUID? {
        if userAId == userId { return userBId }
        if userBId == userId { return userAId }
        return nil
    }
}

/// A connection resolved from the current user's point of view — what the People list and
/// duration picker actually consume.
public struct ConnectedPerson: Identifiable, Equatable, Sendable {
    public let connectionId: UUID
    public let profile: Profile

    public var id: UUID { profile.id }

    public init(connectionId: UUID, profile: Profile) {
        self.connectionId = connectionId
        self.profile = profile
    }
}

public enum InviteStatus: String, Codable, Sendable {
    case pending
    case redeemed
    case expired
    case revoked
}

/// Mirrors the `connection_invites` table.
public struct ConnectionInvite: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public let inviteCode: String
    public var status: InviteStatus
    public let expiresAt: Date?
    public let createdAt: Date

    public init(id: UUID, inviteCode: String, status: InviteStatus, expiresAt: Date?, createdAt: Date) {
        self.id = id
        self.inviteCode = inviteCode
        self.status = status
        self.expiresAt = expiresAt
        self.createdAt = createdAt
    }
}
