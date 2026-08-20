import SwiftUI
import GotTimeCore

/// App root: resolves auth state, hosts onboarding vs. the main experience, and layers
/// incoming/active calls on top as a plain ZStack overlay driven entirely by CallCoordinator's
/// observable state — no view below this one reaches into VoiceService directly.
///
/// Deliberately not `.fullScreenCover`/`.sheet` for the call overlay (see DECISIONS.md) — a
/// ZStack layer is ordinary view composition, not a modal transition to coordinate, and nothing
/// here wants swipe-to-dismiss anyway. Both explicit dismissal paths (`dismissActiveCall()`,
/// `declineIncomingCall()`) are called directly from the call screens' own buttons.
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
