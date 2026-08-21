import Foundation
import SwiftUI
import GotTimeCore
import GotTimeMocks
import Supabase

/// The five services the whole app is built against, injected via SwiftUI's environment.
/// `.live()` uses real adapters under App/Integrations/ where they exist and falls back to
/// GotTimeMocks for the rest — not every service needs to graduate at once for this to be
/// useful: Phase 2 graduated `authService`, Phase 3 `connectionService`; `voiceService`/
/// `callHistoryService`/`pushService` stay mocked until Phases 4/5. `.mock()` remains the
/// default (see GotTimeApp.swift) so GotTimeUITests, Xcode Previews, and casual runs stay
/// exactly as they were; `.live()` is opt-in via the GOTTIME_USE_LIVE_BACKEND launch-environment
/// variable in Debug, and always-on in Release.
struct AppEnvironment {
    let authService: any AuthService
    let connectionService: any ConnectionService
    let voiceService: any VoiceService
    let callHistoryService: any CallHistoryService
    let pushService: any PushService
}

extension AppEnvironment {
    static func mock() -> AppEnvironment {
        let env = MockEnvironment()
        #if DEBUG
        // Spec section 17: "development-only accelerated timer so a long call can be tested
        // in seconds." Default (10x) is chosen to still be watchable by a human testing the
        // app manually — a 5-minute call becomes 30s, long enough to actually see the
        // ringing -> connected -> warning -> end sequence rather than a blur. GotTimeUITests
        // requests a much more aggressive scale via GOTTIME_DEV_TIME_SCALE in
        // launchEnvironment, since an automated test has no need to watch anything.
        let scaleOverride = ProcessInfo.processInfo.environment["GOTTIME_DEV_TIME_SCALE"]
            .flatMap(Double.init)
        env.voiceService.devTimeScale = scaleOverride ?? 10
        #endif
        return AppEnvironment(
            authService: env.authService,
            connectionService: env.connectionService,
            voiceService: env.voiceService,
            callHistoryService: env.callHistoryService,
            pushService: env.pushService
        )
    }

    static func live() -> AppEnvironment {
        let mockEnv = MockEnvironment()
        let client = SupabaseClientFactory.makeClient()
        return AppEnvironment(
            authService: SupabaseAuthAdapter(client: client),
            connectionService: SupabaseConnectionAdapter(client: client),
            voiceService: mockEnv.voiceService,
            callHistoryService: mockEnv.callHistoryService,
            pushService: mockEnv.pushService
        )
    }
}

private struct AppEnvironmentKey: EnvironmentKey {
    static let defaultValue = AppEnvironment.mock()
}

extension EnvironmentValues {
    var appEnvironment: AppEnvironment {
        get { self[AppEnvironmentKey.self] }
        set { self[AppEnvironmentKey.self] = newValue }
    }
}
