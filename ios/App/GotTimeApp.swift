import SwiftUI

@main
struct GotTimeApp: App {
    /// Delegate adaptor, not a plain `.environment()` call resolved here — `AppEnvironment` now
    /// needs to exist and start registering for VoIP push *before* this Scene's content ever
    /// renders, so a terminated app can be woken correctly by an incoming call. See
    /// `GotTimeAppDelegate`'s own comment for the full reasoning.
    @UIApplicationDelegateAdaptor(GotTimeAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.appEnvironment, appDelegate.environment)
        }
    }
}
