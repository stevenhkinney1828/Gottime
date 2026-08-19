import Foundation

/// Implemented by GotTimeMocks (development) and by a real Supabase-backed adapter that
/// simply reads `call_sessions` (RLS already limits results to calls the current user took
/// part in — see 0006_rls_policies.sql — so this service does no additional filtering).
public protocol CallHistoryService {
    func fetchHistory() async throws -> [CallHistoryEntry]
}
