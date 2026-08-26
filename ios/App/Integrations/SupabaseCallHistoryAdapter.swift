import Foundation
import GotTimeCore
import Supabase

enum SupabaseCallHistoryAdapterError: Error {
    case notSignedIn
}

/// Real Supabase-backed `CallHistoryService` — reads `call_sessions` directly, exactly as that
/// protocol's own doc comment always described. Replaces `AppEnvironment.live()`'s previous use
/// of `MockEnvironment.callHistoryService` (deliberately deferred while Phase 4/5's harder voice
/// work was in progress), found by the owner testing a real call end to end: History was still
/// showing the mock's seeded placeholder entries, not anything from the calls actually just
/// made. RLS (`call_sessions_select_participant`) already restricts results to sessions this
/// user actually took part in, so no additional `caller_id`/`recipient_id` filter is applied
/// here — same reasoning as `SupabaseConnectionAdapter`.
public final class SupabaseCallHistoryAdapter: CallHistoryService, Sendable {
    private let client: SupabaseClient

    public init(client: SupabaseClient) {
        self.client = client
    }

    public func fetchHistory() async throws -> [CallHistoryEntry] {
        guard let myId = client.auth.currentSession?.user.id else {
            throw SupabaseCallHistoryAdapterError.notSignedIn
        }

        let rows: [CallSessionHistoryRow] = try await client.from("call_sessions")
            .select()
            .order("initiated_at", ascending: false)
            .execute()
            .value
        guard !rows.isEmpty else { return [] }

        let otherIds = Array(Set(rows.map { $0.callerId == myId ? $0.recipientId : $0.callerId }))
        let profileRows: [ProfileRow] = try await client.from("profiles")
            .select()
            .in("id", values: otherIds.map { $0 as any PostgrestFilterValue })
            .execute()
            .value
        let profilesById = Dictionary(uniqueKeysWithValues: profileRows.map { ($0.id, $0) })

        return rows.compactMap { row in
            let otherId = row.callerId == myId ? row.recipientId : row.callerId
            guard let otherProfile = profilesById[otherId] else { return nil }
            return CallHistoryEntry(session: row.session, otherPerson: otherProfile.profile, isOutgoing: row.callerId == myId)
        }
    }
}

/// Mirrors `call_sessions`' full real (snake_case) column set, every lifecycle timestamp
/// included — distinct from `TwilioVoiceAdapter`'s own `CallSessionRow` (decodes `request-call`'s
/// camelCase Edge Function response) and `PushKitAdapter`'s `CallSessionTableRow` (only the
/// columns an incoming-push context lookup needs); History is the one place that needs every
/// column to render requested-vs-actual duration and status correctly.
private struct CallSessionHistoryRow: Decodable {
    let id: UUID
    let callUuid: UUID
    let callerId: UUID
    let recipientId: UUID
    let requestedDurationSeconds: Int
    let topic: String?
    let initiatedAt: Date
    let ringingAt: Date?
    let connectedAt: Date?
    let endedAt: Date?
    let actualDurationSeconds: Int?
    let providerCallSid: String?
    let status: CallStatus
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case callUuid = "call_uuid"
        case callerId = "caller_id"
        case recipientId = "recipient_id"
        case requestedDurationSeconds = "requested_duration_seconds"
        case topic
        case initiatedAt = "initiated_at"
        case ringingAt = "ringing_at"
        case connectedAt = "connected_at"
        case endedAt = "ended_at"
        case actualDurationSeconds = "actual_duration_seconds"
        case providerCallSid = "provider_call_sid"
        case status
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    var session: CallSession {
        CallSession(
            id: id,
            callUUID: callUuid,
            callerId: callerId,
            recipientId: recipientId,
            requestedDurationSeconds: requestedDurationSeconds,
            topic: topic,
            initiatedAt: initiatedAt,
            ringingAt: ringingAt,
            connectedAt: connectedAt,
            endedAt: endedAt,
            actualDurationSeconds: actualDurationSeconds,
            providerCallSid: providerCallSid,
            status: status,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}
