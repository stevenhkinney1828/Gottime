import Foundation

/// Implemented by GotTimeMocks (development) and by SupabaseConnectionAdapter (real). Invite
/// codes are a discovery/invitation mechanism, not authentication (spec section 12) —
/// redeeming one is the only way a Connection gets created, matching the database's
/// redeem_connection_invite() being the only write path into `connections`.
public protocol ConnectionService {
    func fetchConnections() async throws -> [ConnectedPerson]
    func createInvite() async throws -> ConnectionInvite
    func redeemInvite(code: String) async throws -> ConnectedPerson
    func removeConnection(id: UUID) async throws
    /// Sets this user's own private label for `personId`, overriding what's shown everywhere
    /// that person appears (People list, calls, History) — never visible to anyone else,
    /// including `personId` themselves. Passing `nil` clears it, reverting the display back to
    /// that person's own self-reported name.
    func setNickname(_ nickname: String?, for personId: UUID) async throws
}
