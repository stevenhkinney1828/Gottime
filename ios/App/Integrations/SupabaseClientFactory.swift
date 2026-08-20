import Foundation
import Supabase

enum SupabaseClientFactory {
    /// Reads the two client-safe values injected into Info.plist from Config/AppConfig.xcconfig
    /// (see that file for why only these two, never the service_role/secret key). Traps on a
    /// missing/malformed value rather than returning an optional — every real (non-mock)
    /// environment needs a working client to do anything at all, so there's no reasonable
    /// degraded mode to fall back to, and failing at launch is far easier to diagnose than a
    /// nil client silently making every real adapter call fail later.
    static func makeClient() -> SupabaseClient {
        guard
            let projectRef = Bundle.main.object(forInfoDictionaryKey: "GTSupabaseProjectRef") as? String,
            !projectRef.isEmpty,
            let anonKey = Bundle.main.object(forInfoDictionaryKey: "GTSupabaseAnonKey") as? String,
            !anonKey.isEmpty,
            let url = URL(string: "https://\(projectRef).supabase.co")
        else {
            fatalError("Missing/invalid GTSupabaseProjectRef or GTSupabaseAnonKey in Info.plist — check ios/Config/AppConfig.xcconfig")
        }
        return SupabaseClient(supabaseURL: url, supabaseKey: anonKey)
    }
}
