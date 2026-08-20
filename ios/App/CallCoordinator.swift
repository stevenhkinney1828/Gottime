import Foundation
import Observation
import GotTimeCore

/// Centralizes call-state logic per spec section 14, rather than scattering it across
/// SwiftUI views. Owns the VoiceService event subscription for the app's lifetime and
/// exposes the two things views actually need: `incomingCall` (drives the incoming-call
/// presentation) and `activeCall` (drives the active-call / post-call-summary presentation).
///
/// Never stores or decrements remaining time itself — `remainingSeconds`/`warningLevel` are
/// computed fresh from CallTimer on every read. `tickTrigger` exists purely to give SwiftUI's
/// observation system something to invalidate on periodically; if a tick is delayed or
/// skipped entirely (the view isn't visible, the app is backgrounded), the next one still
/// recomputes correctly from `connectedAt`, because CallTimer has no memory of previous
/// reads (spec section 7).
@Observable
@MainActor
final class CallCoordinator {
    private let voiceService: any VoiceService

    private(set) var activeCall: CallSession?
    private(set) var activeCallOtherPerson: Profile?
    private(set) var incomingCall: (session: CallSession, callerProfile: Profile)?

    private var tickTrigger: Date = .now
    private var eventTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?

    init(voiceService: any VoiceService) {
        self.voiceService = voiceService
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.voiceService.events {
                self.handle(event)
            }
        }
    }

    deinit {
        eventTask?.cancel()
        tickTask?.cancel()
    }

    // MARK: - Derived, always-fresh countdown state

    var remainingSeconds: Int? {
        _ = tickTrigger
        guard let activeCall, let connectedAt = activeCall.connectedAt else { return nil }
        return CallTimer(connectedAt: connectedAt, requestedDurationSeconds: activeCall.requestedDurationSeconds)
            .remainingSeconds(at: .now)
    }

    var warningLevel: CallTimer.WarningLevel {
        _ = tickTrigger
        guard let activeCall, let connectedAt = activeCall.connectedAt else { return .normal }
        return CallTimer(connectedAt: connectedAt, requestedDurationSeconds: activeCall.requestedDurationSeconds)
            .warningLevel(at: .now)
    }

    // MARK: - Intents

    func call(_ person: ConnectedPerson, durationSeconds: Int) async {
        guard let session = try? await voiceService.startCall(to: person, durationSeconds: durationSeconds) else {
            // Phase 7 (Reliability) adds structured logging and a user-facing error state
            // here; for now a failed startCall simply never presents an active call.
            return
        }
        activeCall = session
        activeCallOtherPerson = person.profile
    }

    func answerIncomingCall() async {
        guard let incoming = incomingCall else { return }
        activeCall = incoming.session
        activeCallOtherPerson = incoming.callerProfile
        incomingCall = nil
        try? await voiceService.answer(callUUID: incoming.session.callUUID)
    }

    func declineIncomingCall() async {
        guard let incoming = incomingCall else { return }
        incomingCall = nil
        try? await voiceService.decline(callUUID: incoming.session.callUUID)
    }

    /// Covers both "caller cancels while ringing" and "either participant ends a connected
    /// call early" — the view doesn't need to know which is valid right now; the underlying
    /// service (and, ultimately, CallStateMachine) is the source of truth for that, and
    /// simply no-ops a call to the wrong one.
    func endActiveCall() async {
        guard let activeCall, !activeCall.status.isTerminal else { return }
        if activeCall.status == .connected {
            try? await voiceService.endEarly(callUUID: activeCall.callUUID)
        } else {
            try? await voiceService.cancel(callUUID: activeCall.callUUID)
        }
    }

    func setMuted(_ muted: Bool) async {
        try? await voiceService.setMuted(muted)
    }

    func setSpeakerEnabled(_ enabled: Bool) async {
        try? await voiceService.setSpeakerEnabled(enabled)
    }

    /// Called when the user acknowledges the post-call summary ("Time's up" / early-end
    /// screen) — clears the active call so its full-screen presentation dismisses. "Call
    /// Again" is handled by the People/DurationPicker flow starting an entirely new call, not
    /// by anything in this method (spec section 2: no extending or resuming a call).
    func dismissActiveCall() {
        activeCall = nil
        activeCallOtherPerson = nil
        stopTicking()
    }

    // MARK: - Event handling

    private func handle(_ event: VoiceEvent) {
        switch event {
        case .incomingCall(let session, let callerProfile):
            incomingCall = (session, callerProfile)

        case .statusChanged(let session):
            guard activeCall?.callUUID == session.callUUID else { return }
            activeCall = session
            if session.status == .connected {
                startTicking()
            }

        case .callEnded(let callUUID):
            guard activeCall?.callUUID == callUUID else { return }
            stopTicking()
            // activeCall intentionally stays set, now carrying its final terminal status, so
            // the active-call screen can render the post-call summary. dismissActiveCall()
            // is what actually clears it once the user acknowledges.
        }
    }

    private func startTicking() {
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                self.tickTrigger = .now
            }
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }
}
