import Foundation
import GotTimeCore
import GotTimeMocks

/// The five services the whole app is built against, injected via SwiftUI's environment.
/// `.mock` (backed by GotTimeMocks) is the only implementation that exists yet — real
/// Supabase/Twilio/CallKit adapters land in Phases 2-5, implementing these same protocols
/// under App/Integrations/, at which point a build-setting-driven `.live` factory joins
/// `.mock` here without any call site elsewhere in the app needing to change.
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
