import Foundation
import SwiftUI

@main
struct GotTimeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.appEnvironment, Self.resolvedEnvironment())
        }
    }

    /// Release builds (what TestFlight ships — the only way the owner's own iPhone ever gets
    /// this app, with no local Mac/Xcode to run a scheme override from) always use the real
    /// backend; anything else would mean a real install silently ran against fake data forever.
    /// Debug builds (what ios-ci.yml's Simulator job and GotTimeUITests run) default to mocked
    /// so nothing about the now-passing canonical-flow test or Xcode Previews changes, with
    /// GOTTIME_USE_LIVE_BACKEND=1 as a scheme-level opt-in for whoever eventually has Xcode
    /// available to manually test the real Supabase-backed flow before Phase 4 makes signed
    /// Release builds real.
    private static func resolvedEnvironment() -> AppEnvironment {
        #if DEBUG
        let useLiveBackend = ProcessInfo.processInfo.environment["GOTTIME_USE_LIVE_BACKEND"] == "1"
        return useLiveBackend ? .live() : .mock()
        #else
        return .live()
        #endif
    }
}
