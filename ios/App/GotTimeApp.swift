import Foundation
import SwiftUI

@main
struct GotTimeApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// Splits out from GotTimeApp so the Release path can check config safety before ever
/// constructing a real AppEnvironment, instead of crashing with no on-screen detail — see
/// SupabaseClientFactory.diagnoseConfig()/ConfigDiagnosticView, both TEMPORARY, added to
/// root-cause a real launch crash that survived one already-attempted fix (see DECISIONS.md).
private struct RootView: View {
    var body: some View {
        #if DEBUG
        let useLiveBackend = ProcessInfo.processInfo.environment["GOTTIME_USE_LIVE_BACKEND"] == "1"
        ContentView().environment(\.appEnvironment, useLiveBackend ? .live() : .mock())
        #else
        switch SupabaseClientFactory.diagnoseConfig() {
        case .ok:
            ContentView().environment(\.appEnvironment, .live())
        case .missing(let details):
            ConfigDiagnosticView(details: details)
        }
        #endif
    }
}
