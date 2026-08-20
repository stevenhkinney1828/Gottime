import SwiftUI
import GotTimeCore

/// App root: resolves auth state, hosts onboarding vs. the main experience, and layers
/// incoming/active calls on top as a plain ZStack overlay driven entirely by CallCoordinator's
/// observable state — no view below this one reaches into VoiceService directly.
///
/// Deliberately not `.fullScreenCover`/`.sheet` for the call overlay (see DECISIONS.md
/// Follow-up #7): four different modal-presentation approaches all failed identically in
/// GotTimeUITests, which pointed at UIKit modal-presentation coordination itself — not any
/// particular API shape or timing detail within it — being unreliable here. A ZStack overlay is
/// ordinary view composition, not a modal transition to coordinate, so it sidesteps that whole
/// class of problem. Nothing here wants swipe-to-dismiss anyway (every call screen already ran
/// `.interactiveDismissDisabled()`), so real-modal semantics were never actually needed.
struct ContentView: View {
    @Environment(\.appEnvironment) private var environment
    @State private var coordinator: CallCoordinator?
    @State private var authState: AuthState = .signedOut

    var body: some View {
        ZStack {
            Group {
                if let coordinator {
                    signedInContent(coordinator: coordinator)
                } else {
                    ProgressView()
                }
            }

            if let coordinator {
                callOverlay(coordinator: coordinator)
            }

            if let coordinator {
                // Temporary diagnostic (see DECISIONS.md) — deliberately the topmost ZStack
                // layer so it stays accessibility-queryable no matter what `callOverlay` is
                // currently showing, unlike the earlier version of this element which sat
                // *underneath* a `.fullScreenCover` and was therefore always hidden the instant
                // anything was presented, making its absence uninformative. Remove once the
                // active-call-presentation bug is confirmed fixed.
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text(debugStateLabel(coordinator))
                            .font(.caption2)
                            .accessibilityIdentifier("gtDebugState")
                    }
                }
                .allowsHitTesting(false)
            }
        }
        .task {
            if coordinator == nil {
                coordinator = CallCoordinator(voiceService: environment.voiceService)
            }
            for await state in environment.authService.authStateStream {
                authState = state
            }
        }
    }

    private func debugStateLabel(_ coordinator: CallCoordinator) -> String {
        let active = coordinator.activeCall.map { "\($0.status)" } ?? "nil"
        let incoming = coordinator.incomingCall != nil ? "SET" : "nil"
        let presentation: String
        switch coordinator.presentation {
        case .incoming: presentation = "incoming"
        case .active: presentation = "active"
        case nil: presentation = "nil"
        }
        return "gtDebug active=\(active) incoming=\(incoming) presentation=\(presentation)"
    }

    @ViewBuilder
    private func signedInContent(coordinator: CallCoordinator) -> some View {
        Group {
            switch authState {
            case .signedOut:
                SignedOutView()
            case .signedIn(let profile) where !profile.hasCompletedOnboarding:
                OnboardingView(profile: profile)
            case .signedIn:
                MainView()
            }
        }
        .environment(coordinator)
    }

    @ViewBuilder
    private func callOverlay(coordinator: CallCoordinator) -> some View {
        switch coordinator.presentation {
        case .incoming(let presentation):
            IncomingCallView(session: presentation.session, callerProfile: presentation.callerProfile)
                .environment(coordinator)
        case .active(let presentation):
            ActiveCallView(session: presentation.session, otherPerson: presentation.otherPerson)
                .environment(coordinator)
        case nil:
            EmptyView()
        }
    }
}

#Preview {
    ContentView()
}
