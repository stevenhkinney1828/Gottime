import Foundation
import UIKit

/// Owns `AppEnvironment` for the app's entire lifetime and requests VoIP push registration as
/// early as physically possible — in `application(_:didFinishLaunchingWithOptions:)`, not
/// `ContentView`'s own `.task` (gated on sign-in, which only runs once SwiftUI actually renders
/// a view). This matters specifically for CallKit (see `CallKitAdapter`'s own top-level
/// comment): Apple's documented guidance is that `PKPushRegistry` should be set up at true
/// app-launch time so a genuinely *terminated* app can still be woken and correctly report an
/// incoming call to the lock screen — a `.task` tied to a view's lifecycle can't do that, since
/// nothing has rendered yet on a cold launch triggered by the push itself.
///
/// Safe to do unconditionally, before sign-in: `PushKitAdapter.registerForVoIPPushes()`'s own
/// doc comment already establishes that setting up the registry itself needs no auth — only the
/// later Twilio-side device-token registration does, and that's already deferred correctly
/// inside its own delegate callback, not something this triggers directly.
///
/// `TwilioVoiceAdapter.events` (an `AsyncStream`) defaults to unbounded buffering, so an
/// incoming call handled here — reported to CallKit, possibly even answered — before
/// `ContentView`/`CallCoordinator` exist yet isn't lost: the events queue and are delivered in
/// order the moment `CallCoordinator.init` starts consuming the stream, whenever SwiftUI does
/// get around to constructing it on this same cold launch. No other synchronization between
/// this class and `ContentView` is needed for that to work correctly.
final class GotTimeAppDelegate: NSObject, UIApplicationDelegate {
    let environment: AppEnvironment = Self.resolvedEnvironment()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        Task { try? await environment.pushService.registerForVoIPPushes() }
        return true
    }

    /// Release builds (what TestFlight ships — the only way the owner's own iPhone ever gets
    /// this app) always use the real backend; Debug builds (`ios-ci.yml`'s Simulator job,
    /// `GotTimeUITests`) default to mocked, with `GOTTIME_USE_LIVE_BACKEND=1` as a scheme-level
    /// opt-in. Unchanged in behavior from `GotTimeApp`'s own original version of this method,
    /// just relocated here now that this class is what actually owns `AppEnvironment`'s
    /// construction and lifetime, not `GotTimeApp` itself.
    private static func resolvedEnvironment() -> AppEnvironment {
        #if DEBUG
        let useLiveBackend = ProcessInfo.processInfo.environment["GOTTIME_USE_LIVE_BACKEND"] == "1"
        return useLiveBackend ? .live() : .mock()
        #else
        return .live()
        #endif
    }
}
