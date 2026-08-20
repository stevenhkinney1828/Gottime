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
        .overlay(alignment: .bottomTrailing) {
            if let coordinator {
                // Temporary diagnostic (see DECISIONS.md) — surfaces live CallCoordinator
                // state through the same accessibility-query channel GotTimeUITests already
                // uses successfully for everything else, since app-process print() output does
                // not reliably show up in the xcodebuild test log the way `swift test` output
                // does. Remove once the active-call-presentation bug is found and fixed.
                Text(debugStateLabel(coordinator))
                    .font(.caption2)
                    .accessibilityIdentifier("gtDebugState")
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
        let presentation = coordinator.activeCallPresentation != nil ? "SET" : "nil"
        return "gtDebug active=\(active) incoming=\(incoming) presentation=\(presentation)"
    }

    @ViewBuilder
    private func signedInGate(coordinator: CallCoordinator) -> some View {
        // Read directly here, textually within this function's body computation, rather than
        // only inside the Binding's get closure below. @Observable's dependency tracking is
        // keyed to property reads that happen during a tracked body computation; a read that
        // only ever happens indirectly, inside a closure invoked later by a framework
        // modifier's own internal machinery, is not guaranteed to register the same way. This
        // capture is what actually guarantees signedInGate re-runs when it changes.
        let presentation = coordinator.presentation

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
        // A single cover for both incoming/active, not two chained `.fullScreenCover`
        // modifiers — see the CallPresentation doc comment in CallCoordinator.swift.
        .fullScreenCover(item: Binding(
            get: { presentation },
            set: { newValue in
                guard newValue == nil else { return }
                switch presentation {
                case .incoming: Task { await coordinator.declineIncomingCall() }
                case .active: coordinator.dismissActiveCall()
                case nil: break
                }
            }
        )) { item in
            switch item {
            case .incoming(let presentation):
                IncomingCallView(session: presentation.session, callerProfile: presentation.callerProfile)
            case .active(let presentation):
                ActiveCallView(session: presentation.session, otherPerson: presentation.otherPerson)
            }
        }
    }
}

#Preview {
    ContentView()
}
