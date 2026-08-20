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
        // Read directly here, textually within this function's body computation, rather than
        // only inside the Bindings' get closures below. @Observable's dependency tracking is
        // keyed to property reads that happen during a tracked body computation; a read that
        // only ever happens indirectly, inside a closure invoked later by a framework
        // modifier's own internal machinery, is not guaranteed to register the same way. This
        // capture is what actually guarantees signedInGate re-runs when either changes.
        let activePresentation = coordinator.activeCallPresentation
        let incomingPresentation = coordinator.incomingCallPresentation

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
        .fullScreenCover(item: Binding(
            get: { incomingPresentation },
            set: { newValue in
                if newValue == nil { Task { await coordinator.declineIncomingCall() } }
            }
        )) { presentation in
            IncomingCallView(session: presentation.session, callerProfile: presentation.callerProfile)
        }
        .fullScreenCover(item: Binding(
            get: { activePresentation },
            set: { newValue in
                if newValue == nil { coordinator.dismissActiveCall() }
            }
        )) { presentation in
            ActiveCallView(session: presentation.session, otherPerson: presentation.otherPerson)
        }
    }
}

#Preview {
    ContentView()
}
