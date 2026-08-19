import Foundation

/// Implemented by GotTimeMocks (development) and by a real Supabase-backed adapter
/// (Phase 3). Invite codes are a discovery/invitation mechanism, not authentication (spec
/// section 12) — redeeming one is the only way a Connection gets created, matching the
/// database's redeem_connection_invite() being the only write path into `connections`.
public protocol ConnectionService {
    func fetchConnections() async throws -> [ConnectedPerson]
    func createInvite() async throws -> ConnectionInvite
    func redeemInvite(code: String) async throws -> ConnectedPerson
    func removeConnection(id: UUID) async throws
}
