import Foundation
import GotTimeCore

/// Bundles all five mock services together, wired the way the App layer actually needs them
/// — in particular, connecting MockVoiceService's onCallEnded callback to
/// MockCallHistoryService.record(), so a call made during a test session shows up in History
/// immediately afterward, the same way it would against a real backend (where History is
/// just a query over the same call_sessions rows VoiceService already wrote).
public struct MockEnvironment: Sendable {
    public let authService: MockAuthService
    public let connectionService: MockConnectionService
    public let voiceService: MockVoiceService
    public let callHistoryService: MockCallHistoryService
    public let pushService: MockPushService

    public init(
        authService: MockAuthService = MockAuthService(),
        connectionService: MockConnectionService = MockConnectionService(),
        voiceService: MockVoiceService = MockVoiceService(),
        callHistoryService: MockCallHistoryService = MockCallHistoryService(),
        pushService: MockPushService = MockPushService()
    ) {
        self.authService = authService
        self.connectionService = connectionService
        self.voiceService = voiceService
        self.callHistoryService = callHistoryService
        self.pushService = pushService

        voiceService.onCallEnded = { [callHistoryService] entry in
            callHistoryService.record(entry)
        }
    }
}
