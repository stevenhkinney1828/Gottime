import Foundation

/// What the History screen actually renders: a call session plus the other person's profile
/// resolved directly, and a precomputed `isOutgoing` flag — matches spec section 8's list
/// (connected person, date/time, requested duration, actual duration, status).
public struct CallHistoryEntry: Identifiable, Equatable, Sendable {
    public let session: CallSession
    public let otherPerson: Profile
    public let isOutgoing: Bool

    public var id: UUID { session.id }

    public init(session: CallSession, otherPerson: Profile, isOutgoing: Bool) {
        self.session = session
        self.otherPerson = otherPerson
        self.isOutgoing = isOutgoing
    }
}
