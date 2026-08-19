import Foundation
import GotTimeCore

/// Shared placeholder data for mock services. Using relatable names (Chris matches the
/// spec's own running example — "Call Chris for 10 minutes") is purely a testing-experience
/// nicety; nothing about the architecture depends on these specific people (spec section 5:
/// "never hard-code the two original users" refers to the data model, not default mock
/// fixture values, which are fully overridable via every mock service's initializer).
public enum MockData {
    public static let me = Profile(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        firstName: "Steven",
        createdAt: .now,
        updatedAt: .now
    )

    public static let chris = Profile(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        firstName: "Chris",
        createdAt: .now,
        updatedAt: .now
    )

    public static let jordan = Profile(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
        firstName: "Jordan",
        createdAt: .now,
        updatedAt: .now
    )

    public static let defaultConnections: [ConnectedPerson] = [
        ConnectedPerson(connectionId: UUID(uuidString: "00000000-0000-0000-0000-0000000000c1")!, profile: chris),
        ConnectedPerson(connectionId: UUID(uuidString: "00000000-0000-0000-0000-0000000000c2")!, profile: jordan),
    ]

    /// Seed history covering all six user-facing outcomes from spec section 8, so the
    /// History screen has something meaningful to show without waiting for a real call.
    public static func defaultHistory(selfId: UUID = me.id) -> [CallHistoryEntry] {
        let now = Date()
        func entry(
            with person: Profile, outgoing: Bool, status: CallStatus, requestedMinutes: Int,
            connectedSecondsAgo: TimeInterval?, actualDurationSeconds: Int?
        ) -> CallHistoryEntry {
            let initiatedAt = now.addingTimeInterval(-Double(requestedMinutes * 60) - 3600)
            let connectedAt = connectedSecondsAgo.map { now.addingTimeInterval(-$0 - 30) }
            let endedAt = connectedSecondsAgo.map { now.addingTimeInterval(-$0) } ?? initiatedAt.addingTimeInterval(20)
            let session = CallSession(
                id: UUID(),
                callUUID: UUID(),
                callerId: outgoing ? selfId : person.id,
                recipientId: outgoing ? person.id : selfId,
                requestedDurationSeconds: requestedMinutes * 60,
                initiatedAt: initiatedAt,
                connectedAt: connectedAt,
                endedAt: endedAt,
                actualDurationSeconds: actualDurationSeconds,
                status: status,
                createdAt: initiatedAt,
                updatedAt: endedAt
            )
            return CallHistoryEntry(session: session, otherPerson: person, isOutgoing: outgoing)
        }

        return [
            entry(with: chris, outgoing: true, status: .completed, requestedMinutes: 10, connectedSecondsAgo: 3600, actualDurationSeconds: 600),
            entry(with: chris, outgoing: false, status: .endedEarly, requestedMinutes: 20, connectedSecondsAgo: 7200, actualDurationSeconds: 312),
            entry(with: jordan, outgoing: true, status: .declined, requestedMinutes: 5, connectedSecondsAgo: nil, actualDurationSeconds: nil),
            entry(with: jordan, outgoing: false, status: .missed, requestedMinutes: 15, connectedSecondsAgo: nil, actualDurationSeconds: nil),
            entry(with: chris, outgoing: true, status: .canceled, requestedMinutes: 5, connectedSecondsAgo: nil, actualDurationSeconds: nil),
            entry(with: jordan, outgoing: true, status: .failed, requestedMinutes: 10, connectedSecondsAgo: nil, actualDurationSeconds: nil),
        ]
    }
}

public enum MockServiceError: Error, Equatable, Sendable {
    case notSignedIn
    case invalidInviteCode
    case unknownCall
    case notAParticipant
}
