import Foundation
import GotTimeCore

/// Development-only PushService. Real PushKit registration lands in Phase 5 — there is
/// nothing to simulate here since mock mode never needs a device token at all.
public final class MockPushService: PushService, @unchecked Sendable {
    public init() {}

    public func registerForVoIPPushes() async throws {}

    public func currentDeviceToken() async -> String? {
        nil
    }
}
