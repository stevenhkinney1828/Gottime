import Foundation
import Supabase

/// Shared nickname lookup against `contact_nicknames` — used by every adapter that needs to
/// resolve "my private label for someone" outside the People-list flow
/// (`SupabaseConnectionAdapter.fetchConnections` handles that one directly, since it already
/// has the full connections list in hand). `PushKitAdapter` (resolving an incoming caller's
/// nickname) and `SupabaseCallHistoryAdapter` (resolving each entry's other-participant) both
/// need this without otherwise depending on `ConnectionService`. Best-effort by design: a
/// nickname is a display nicety, not critical-path data, so any failure here (no signed-in
/// session, a transient network error) silently falls back to no override — the same
/// discretion this project already applies to other non-critical reads.
enum ContactNicknames {
    private struct Row: Decodable {
        let targetUserId: UUID
        let nickname: String

        enum CodingKeys: String, CodingKey {
            case targetUserId = "target_user_id"
            case nickname
        }
    }

    static func fetchNickname(client: SupabaseClient, targetUserId: UUID) async -> String? {
        await fetchNicknames(client: client, targetUserIds: [targetUserId])[targetUserId]
    }

    static func fetchNicknames(client: SupabaseClient, targetUserIds: [UUID]) async -> [UUID: String] {
        guard let myId = client.auth.currentSession?.user.id, !targetUserIds.isEmpty else { return [:] }
        let rows: [Row]? = try? await client.from("contact_nicknames")
            .select("target_user_id, nickname")
            .eq("owner_user_id", value: myId)
            .in("target_user_id", values: targetUserIds.map { $0 as any PostgrestFilterValue })
            .execute()
            .value
        guard let rows else { return [:] }
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.targetUserId, $0.nickname) })
    }
}
