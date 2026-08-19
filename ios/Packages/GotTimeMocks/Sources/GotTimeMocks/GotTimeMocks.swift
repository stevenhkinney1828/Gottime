import GotTimeCore

/// Marker namespace for the GotTimeMocks package.
///
/// GotTimeMocks implements every service protocol from GotTimeCore with simulated behavior
/// (fake ringing, fake answer, an accelerated dev-only timer) so the full app UX is testable
/// without any live Supabase/Twilio/APNs credentials. Depends only on GotTimeCore.
public enum GotTimeMocks {
    public static let packageName = "GotTimeMocks"
}
