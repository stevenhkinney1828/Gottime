import AVFoundation
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
    @State private var hasRequestedMicrophonePermission = false

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
                // VoIP push registration itself now happens at true app-launch time
                // (GotTimeAppDelegate), not here — needed so a terminated app can still be woken
                // and correctly report an incoming call to CallKit before any SwiftUI view,
                // including this one, has rendered. See GotTimeAppDelegate's own comment.
                if case .signedIn(let profile) = state, profile.hasCompletedOnboarding {
                    // The very first real connected call had no audio in either direction on a
                    // real device -- confirmed nothing anywhere in this codebase had ever
                    // explicitly requested microphone access (NSMicrophoneUsageDescription in
                    // Info.plist only supplies the prompt's text; it doesn't trigger the prompt
                    // itself). Without an explicit, resolved grant before a call starts,
                    // AVAudioSession's .playAndRecord activation (which TwilioVoiceSDK's
                    // DefaultAudioDevice performs internally) can silently fail to produce a
                    // working audio route in either direction. Requested here, once, well before
                    // any call could plausibly happen, so the system prompt is already resolved
                    // by the time one does. See DECISIONS.md.
                    if !hasRequestedMicrophonePermission {
                        hasRequestedMicrophonePermission = true
                        AVAudioApplication.requestRecordPermission { _ in }
                    }
                }
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
