import Foundation

/// Client-safe Supabase config as plain compiled-in constants — replaces an earlier attempt to
/// deliver these via custom INFOPLIST_KEY_* build settings, which two real device launches
/// proved never actually reaches the compiled Info.plist at all (confirmed directly: an
/// on-screen dump of Bundle.main.infoDictionary showed every standard Apple-defined key present
/// — CFBundleDisplayName, UISupportedInterfaceOrientations, etc. — but neither
/// GTSupabaseProjectRef nor GTSupabaseAnonKey anywhere in the list; GENERATE_INFOPLIST_FILE's
/// synthesis in this project only recognizes real, Apple-defined keys, not arbitrary custom
/// ones). A plain Swift constant has no such indirection to trust — see DECISIONS.md.
///
/// `anonKey` is Supabase's "publishable" key — their own dashboard labels it safe to share
/// publicly, and the real security boundary is Row Level Security on the database (see
/// DECISIONS.md/KNOWN_LIMITATIONS.md), not keeping this value secret. `projectRef` isn't
/// sensitive either. The service_role/secret key never appears here, or anywhere under ios/ —
/// it stays in the root .env (gitignored) and GitHub Actions secrets for Edge Function
/// deployment only.
enum SupabaseConfig {
    static let projectRef = "wraowtlpekpmpekkcquq"
    static let anonKey = "sb_publishable_DbHsYI9HsdbqQ4rUM0Lb_w_bdi25XpF"
}
