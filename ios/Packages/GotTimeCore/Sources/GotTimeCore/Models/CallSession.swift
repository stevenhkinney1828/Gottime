import Foundation

/// Mirrors the `call_sessions` table — the authoritative record of one timed call.
public struct CallSession: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public let callUUID: UUID
    public let callerId: UUID
    public let recipientId: UUID
    public let requestedDurationSeconds: Int
    public let initiatedAt: Date
    public var ringingAt: Date?
    public var connectedAt: Date?
    public var endedAt: Date?
    public var actualDurationSeconds: Int?
    public var providerCallSid: String?
    public var status: CallStatus
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID,
        callUUID: UUID,
        callerId: UUID,
        recipientId: UUID,
        requestedDurationSeconds: Int,
        initiatedAt: Date,
        ringingAt: Date? = nil,
        connectedAt: Date? = nil,
        endedAt: Date? = nil,
        actualDurationSeconds: Int? = nil,
        providerCallSid: String? = nil,
        status: CallStatus,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.callUUID = callUUID
        self.callerId = callerId
        self.recipientId = recipientId
        self.requestedDurationSeconds = requestedDurationSeconds
        self.initiatedAt = initiatedAt
        self.ringingAt = ringingAt
        self.connectedAt = connectedAt
        self.endedAt = endedAt
        self.actualDurationSeconds = actualDurationSeconds
        self.providerCallSid = providerCallSid
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func isParticipant(_ userId: UUID) -> Bool {
        callerId == userId || recipientId == userId
    }

    public func otherParticipant(from userId: UUID) -> UUID? {
        if callerId == userId { return recipientId }
        if recipientId == userId { return callerId }
        return nil
    }
}
