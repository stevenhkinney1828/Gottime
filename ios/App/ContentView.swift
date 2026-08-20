import SwiftUI
import GotTimeCore

/// App root: resolves auth state, hosts onboarding vs. the main experience, and presents
/// incoming/active calls as full-screen covers driven entirely by CallCoordinator's
/// observable state — no view below this one reaches into VoiceService directly.
struct ContentView: View {
    @Environment(\.appEnvironment) private var environment
    @State private var coordinator: CallCoordinator?
    @State private var authState: AuthState = .signedOut

    var body: some View {
        Group {
            if let coordinator {
                signedInGate(coordinator: coordinator)
            } else {
                ProgressView()
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
    private func signedInGate(coordinator: CallCoordinator) -> some View {
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
        .fullScreenCover(item: incomingCallBinding(coordinator)) { presentation in
            IncomingCallView(session: presentation.session, callerProfile: presentation.callerProfile)
        }
        .fullScreenCover(item: activeCallBinding(coordinator)) { presentation in
            ActiveCallView(session: presentation.session, otherPerson: presentation.otherPerson)
        }
    }

    /// Real two-way bindings, not `.constant()` — see the doc comment on
    /// ActiveCallPresentation/IncomingCallPresentation in CallCoordinator.swift for why that
    /// distinction matters here specifically.
    private func activeCallBinding(_ coordinator: CallCoordinator) -> Binding<ActiveCallPresentation?> {
        Binding(
            get: { coordinator.activeCallPresentation },
            set: { newValue in
                if newValue == nil { coordinator.dismissActiveCall() }
            }
        )
    }

    private func incomingCallBinding(_ coordinator: CallCoordinator) -> Binding<IncomingCallPresentation?> {
        Binding(
            get: { coordinator.incomingCallPresentation },
            set: { newValue in
                if newValue == nil { Task { await coordinator.declineIncomingCall() } }
            }
        )
    }
}

#Preview {
    ContentView()
}
