import Foundation

/// Implemented by GotTimeMocks (development, a no-op) and by a real PushKit adapter (Phase
/// 5) that registers a VoIP push token with the register-device Edge Function. Deliberately
/// narrow: this is VoIP-call push registration only, never a general notification channel
/// (spec section 15: "never use VoIP pushes for unrelated background notifications").
public protocol PushService {
    func registerForVoIPPushes() async throws
    func currentDeviceToken() async -> String?
}
