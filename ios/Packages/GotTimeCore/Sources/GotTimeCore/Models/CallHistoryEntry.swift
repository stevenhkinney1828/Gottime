import Foundation

/// What the History screen actually renders: a call session plus the other person's profile
/// resolved directly, and a precomputed `isOutgoing` flag — matches spec section 8's list
/// (connected person, date/time, requested duration, actual duration, status).
public struct CallHistoryEntry: Identifiable, Equatable, Sendable {
    public let session: CallSession
    public let otherPerson: Profile
    public let isOutgoing: Bool
    /// See `ConnectedPerson.nickname`'s own doc comment — same private-override concept,
    /// resolved here so History shows whatever the viewer privately calls this person too.
    public let nickname: String?

    public var id: UUID { session.id }

    public var displayName: String { nickname ?? otherPerson.firstName ?? "Unknown" }

    public init(session: CallSession, otherPerson: Profile, isOutgoing: Bool, nickname: String? = nil) {
        self.session = session
        self.otherPerson = otherPerson
        self.isOutgoing = isOutgoing
        self.nickname = nickname
    }
}
