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
        .fullScreenCover(isPresented: .constant(coordinator.incomingCall != nil)) {
            if let incoming = coordinator.incomingCall {
                IncomingCallView(session: incoming.session, callerProfile: incoming.callerProfile)
            }
        }
        .fullScreenCover(isPresented: .constant(coordinator.activeCall != nil)) {
            if let activeCall = coordinator.activeCall, let otherPerson = coordinator.activeCallOtherPerson {
                ActiveCallView(session: activeCall, otherPerson: otherPerson)
            }
        }
    }
}

#Preview {
    ContentView()
}
