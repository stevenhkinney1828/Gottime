import Foundation
import Supabase

enum SupabaseClientFactory {
    /// Builds the URL from SupabaseConfig.projectRef at runtime rather than storing a full
    /// https:// URL anywhere — kept as its own step (not just inlined at the call site) so a
    /// malformed project ref fails clearly here rather than producing a URL that silently
    /// points somewhere unintended.
    static func makeClient() -> SupabaseClient {
        guard let url = URL(string: "https://\(SupabaseConfig.projectRef).supabase.co") else {
            fatalError("Malformed SupabaseConfig.projectRef: \(SupabaseConfig.projectRef)")
        }
        return SupabaseClient(supabaseURL: url, supabaseKey: SupabaseConfig.anonKey)
    }
}
