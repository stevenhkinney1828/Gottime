import Foundation
import Supabase

enum SupabaseClientFactory {
    enum ConfigDiagnosis {
        case ok
        case missing(details: String)
    }

    /// Non-crashing check used by GotTimeApp to decide whether it's safe to build a real
    /// `AppEnvironment.live()` at all. TEMPORARY — added specifically to root-cause a real
    /// launch crash that survived one already-attempted fix (see DECISIONS.md): rather than
    /// guess at a third fix blind, this surfaces exactly what `Bundle.main.infoDictionary`
    /// actually contains directly on screen, copyable text, no crash-log round-trip needed.
    /// Remove once the real cause is confirmed and fixed, matching how the Phase 1 ZStack
    /// debugging diagnostics were removed once that root cause was confirmed.
    static func diagnoseConfig() -> ConfigDiagnosis {
        let projectRef = Bundle.main.object(forInfoDictionaryKey: "GTSupabaseProjectRef") as? String
        let anonKey = Bundle.main.object(forInfoDictionaryKey: "GTSupabaseAnonKey") as? String

        guard let projectRef, !projectRef.isEmpty, let anonKey, !anonKey.isEmpty else {
            let allKeys = (Bundle.main.infoDictionary?.keys.sorted() ?? []).joined(separator: "\n")
            let details = """
            GTSupabaseProjectRef: \(projectRef.map { "\"\($0)\"" } ?? "MISSING")
            GTSupabaseAnonKey: \(anonKey.map { "\"\($0)\"" } ?? "MISSING")
            Bundle identifier: \(Bundle.main.bundleIdentifier ?? "nil")
            Info.plist key count: \(Bundle.main.infoDictionary?.count ?? 0)

            All Info.plist keys:
            \(allKeys)
            """
            return .missing(details: details)
        }
        return .ok
    }

    /// Reads the two client-safe values injected into Info.plist from Config/AppConfig.xcconfig
    /// (see that file for why only these two, never the service_role/secret key). Traps on a
    /// missing/malformed value rather than returning an optional — every real (non-mock)
    /// environment needs a working client to do anything at all, so there's no reasonable
    /// degraded mode to fall back to, and failing at launch is far easier to diagnose than a
    /// nil client silently making every real adapter call fail later. In practice, GotTimeApp
    /// now checks `diagnoseConfig()` first and never reaches this fatalError in the case it
    /// guards against — kept as a last-resort safety net, not the primary diagnostic path.
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
