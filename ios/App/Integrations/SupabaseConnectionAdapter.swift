import Foundation
import GotTimeCore
import Supabase

enum SupabaseConnectionAdapterError: Error {
    case notSignedIn
    case unexpectedConnectionShape
    case inviteCreationFailed
}

/// Real Supabase-backed `ConnectionService`. Every write this app is allowed to make against
/// `connections`/`connection_invites` goes through exactly the paths RLS (0006_rls_policies.sql)
/// already grants the authenticated role — creating an invite (`connection_invites_insert_own`),
/// redeeming one (the `redeem_connection_invite` SECURITY DEFINER function, the *only* way a
/// `connections` row ever gets created), and marking a connection removed
/// (`connections_update_participant`). There is no direct client path to create a `connections`
/// row, matching the database's own design.
public final class SupabaseConnectionAdapter: ConnectionService, Sendable {
    private let client: SupabaseClient

    public init(client: SupabaseClient) {
        self.client = client
    }

    public func fetchConnections() async throws -> [ConnectedPerson] {
        guard let myId = client.auth.currentSession?.user.id else {
            throw SupabaseConnectionAdapterError.notSignedIn
        }

        let rows: [ConnectionRow] = try await client.from("connections")
            .select("id, user_a_id, user_b_id")
            .eq("status", value: "active")
            .execute()
            .value

        let otherIds = rows.compactMap { $0.otherUserId(from: myId) }
        guard !otherIds.isEmpty else { return [] }

        let profileRows: [ProfileRow] = try await client.from("profiles")
            .select()
            .in("id", values: otherIds.map { $0 as any PostgrestFilterValue })
            .execute()
            .value
        let profilesById = Dictionary(uniqueKeysWithValues: profileRows.map { ($0.id, $0) })
        let nicknamesById = await ContactNicknames.fetchNicknames(client: client, targetUserIds: otherIds)

        return rows.compactMap { row in
            guard let otherId = row.otherUserId(from: myId), let profileRow = profilesById[otherId] else {
                return nil
            }
            return ConnectedPerson(connectionId: row.id, profile: profileRow.profile, nickname: nicknamesById[otherId])
        }
    }

    /// Retries on an actual invite_code collision (Postgres unique_violation, "23505") only —
    /// astronomically unlikely at this app's scale (32^6 possible codes), but a real, if rare,
    /// possibility worth handling at this system boundary rather than surfacing a raw DB error
    /// for something the user did nothing wrong to cause. Any other failure propagates
    /// immediately rather than being retried, since retrying wouldn't fix it.
    public func createInvite() async throws -> ConnectionInvite {
        guard let myId = client.auth.currentSession?.user.id else {
            throw SupabaseConnectionAdapterError.notSignedIn
        }
        let expiresAt = Date().addingTimeInterval(60 * 60 * 24 * 7)

        for attempt in 0..<3 {
            do {
                let row: ConnectionInviteRow = try await client.from("connection_invites")
                    .insert(NewConnectionInvite(creatorId: myId, inviteCode: InviteCodeGenerator.generate(), expiresAt: expiresAt))
                    .select()
                    .single()
                    .execute()
                    .value
                return row.invite
            } catch let error as PostgrestError where error.code == "23505" {
                // Exhausted every retry and it's still colliding — surface the real error
                // explicitly rather than letting it propagate past the loop implicitly.
                if attempt == 2 { throw error }
            }
        }
        throw SupabaseConnectionAdapterError.inviteCreationFailed
    }

    public func redeemInvite(code: String) async throws -> ConnectedPerson {
        guard let myId = client.auth.currentSession?.user.id else {
            throw SupabaseConnectionAdapterError.notSignedIn
        }

        let connectionRow: ConnectionRow = try await client
            .rpc("redeem_connection_invite", params: RedeemInviteParams(inviteCode: code))
            .single()
            .execute()
            .value

        guard let otherId = connectionRow.otherUserId(from: myId) else {
            throw SupabaseConnectionAdapterError.unexpectedConnectionShape
        }
        let profileRow: ProfileRow = try await client.from("profiles")
            .select()
            .eq("id", value: otherId)
            .single()
            .execute()
            .value
        return ConnectedPerson(connectionId: connectionRow.id, profile: profileRow.profile)
    }

    public func removeConnection(id: UUID) async throws {
        try await client.from("connections")
            .update(["status": "removed"])
            .eq("id", value: id)
            .execute()
    }

    /// `nil`/blank deletes the row rather than writing an empty string -- absence of a row is
    /// `contact_nicknames`' own "no override" state (see that migration's comment), matching
    /// `ConnectedPerson.nickname`'s optional, not-empty-string convention.
    public func setNickname(_ nickname: String?, for personId: UUID) async throws {
        guard let myId = client.auth.currentSession?.user.id else {
            throw SupabaseConnectionAdapterError.notSignedIn
        }
        let trimmed = nickname?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            try await client.from("contact_nicknames")
                .upsert(
                    NewContactNickname(ownerUserId: myId, targetUserId: personId, nickname: trimmed),
                    onConflict: "owner_user_id,target_user_id"
                )
                .execute()
        } else {
            try await client.from("contact_nicknames")
                .delete()
                .eq("owner_user_id", value: myId)
                .eq("target_user_id", value: personId)
                .execute()
        }
    }
}

private struct NewContactNickname: Encodable {
    let ownerUserId: UUID
    let targetUserId: UUID
    let nickname: String

    enum CodingKeys: String, CodingKey {
        case ownerUserId = "owner_user_id"
        case targetUserId = "target_user_id"
        case nickname
    }
}

/// Only the columns this adapter actually needs — enough to resolve "the other participant,"
/// not a full mirror of the table (contrast `ProfileRow`, which mirrors `profiles` completely
/// since every column there is actually consumed somewhere).
private struct ConnectionRow: Decodable {
    let id: UUID
    let userAId: UUID
    let userBId: UUID

    enum CodingKeys: String, CodingKey {
        case id
        case userAId = "user_a_id"
        case userBId = "user_b_id"
    }

    func otherUserId(from userId: UUID) -> UUID? {
        if userAId == userId { return userBId }
        if userBId == userId { return userAId }
        return nil
    }
}

private struct NewConnectionInvite: Encodable {
    let creatorId: UUID
    let inviteCode: String
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case creatorId = "creator_id"
        case inviteCode = "invite_code"
        case expiresAt = "expires_at"
    }
}

private struct ConnectionInviteRow: Decodable {
    let id: UUID
    let inviteCode: String
    let status: String
    let expiresAt: Date?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case inviteCode = "invite_code"
        case status
        case expiresAt = "expires_at"
        case createdAt = "created_at"
    }

    var invite: ConnectionInvite {
        ConnectionInvite(
            id: id,
            inviteCode: inviteCode,
            status: InviteStatus(rawValue: status) ?? .pending,
            expiresAt: expiresAt,
            createdAt: createdAt
        )
    }
}

private struct RedeemInviteParams: Encodable {
    let inviteCode: String

    enum CodingKeys: String, CodingKey {
        case inviteCode = "p_invite_code"
    }
}
