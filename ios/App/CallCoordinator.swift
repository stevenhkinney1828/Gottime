import Foundation
import Observation
import GotTimeCore

/// Identifiable wrappers bundling a session with the profile its view needs, so ContentView's
/// `callOverlay` can switch on one `CallPresentation` value instead of juggling several
/// optionals in sync (see DECISIONS.md for why this ended up as a plain ZStack overlay rather
/// than `.fullScreenCover`/`.sheet`).
struct ActiveCallPresentation: Identifiable {
    let session: CallSession
    let otherPerson: Profile
    var id: UUID { session.id }
}

struct IncomingCallPresentation: Identifiable {
    let session: CallSession
    let callerProfile: Profile
    var id: UUID { session.id }
}

/// Single combined presentation state, replacing two independent `.fullScreenCover(item:)`
/// modifiers that were previously chained on the same view (one for incoming, one for active).
/// That was never provably the cause of the active-call screen failing to appear (see
/// DECISIONS.md follow-ups), but it's a real, if lesser-known, SwiftUI rough edge — multiple
/// same-kind presentation modifiers stacked on one view aren't guaranteed to coordinate
/// cleanly — and modeling it as one value is also just a more accurate reflection of the real
/// invariant: incoming and active are mutually exclusive, never both showing at once.
enum CallPresentation: Identifiable {
    case incoming(IncomingCallPresentation)
    case active(ActiveCallPresentation)

    var id: UUID {
        switch self {
        case .incoming(let presentation): return presentation.id
        case .active(let presentation): return presentation.id
        }
    }
}

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
    // nonisolated(unsafe): deinit always runs in a nonisolated context in Swift's concurrency
    // model, even for a @MainActor class — deallocation can be triggered from any thread, so
    // the compiler can't assume deinit runs on the actor the rest of this class is isolated
    // to. That makes these two properties genuinely need nonisolated access from deinit. It's
    // actually safe here: both are only ever written from MainActor-isolated code (init,
    // startTicking, stopTicking), and deinit's nonisolated read happens only once, after every
    // other reference to self is already gone — nothing MainActor-isolated can race with it.
    nonisolated(unsafe) private var eventTask: Task<Void, Never>?
    nonisolated(unsafe) private var tickTask: Task<Void, Never>?

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

    // MARK: - Presentation wrappers (see the type-level doc comments above)

    var activeCallPresentation: ActiveCallPresentation? {
        guard let activeCall, let activeCallOtherPerson else { return nil }
        return ActiveCallPresentation(session: activeCall, otherPerson: activeCallOtherPerson)
    }

    var incomingCallPresentation: IncomingCallPresentation? {
        guard let incomingCall else { return nil }
        return IncomingCallPresentation(session: incomingCall.session, callerProfile: incomingCall.callerProfile)
    }

    /// Incoming takes priority in the (currently impossible, but not enforced anywhere) case
    /// both are somehow set at once — an incoming call ringing is a more time-sensitive thing
    /// to show than a summary/countdown screen for a call already in progress.
    var presentation: CallPresentation? {
        if let incomingCallPresentation { return .incoming(incomingCallPresentation) }
        if let activeCallPresentation { return .active(activeCallPresentation) }
        return nil
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

    func call(_ person: ConnectedPerson, durationSeconds: Int, topic: String? = nil) async {
        guard let session = try? await voiceService.startCall(to: person, durationSeconds: durationSeconds, topic: topic) else {
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

    /// `.statusChanged`/`.callEnded` no longer assume `answerIncomingCall()` was the thing that
    /// answered — CallKit's own native Answer action (see `CallKitAdapter`) calls
    /// `VoiceService.answer(callUUID:)` directly, with no reason to also duplicate
    /// `answerIncomingCall()`'s optimistic `activeCall` assignment. Both cases now check
    /// `incomingCall` too and promote it reactively, so the UI transitions correctly regardless
    /// of which path triggered the answer/decline/cancel — matching CXProvider(_:perform:)'s own
    /// role as just another caller of the same underlying VoiceService, not a special case.
    private func handle(_ event: VoiceEvent) {
        switch event {
        case .incomingCall(let session, let callerProfile):
            incomingCall = (session, callerProfile)

        case .statusChanged(let session):
            if activeCall?.callUUID == session.callUUID {
                activeCall = session
            } else if incomingCall?.session.callUUID == session.callUUID {
                activeCall = session
                activeCallOtherPerson = incomingCall?.callerProfile
                incomingCall = nil
            } else {
                return
            }
            if session.status == .connected {
                startTicking()
            }

        case .callEnded(let callUUID):
            if activeCall?.callUUID == callUUID {
                stopTicking()
                // activeCall intentionally stays set, now carrying its final terminal status,
                // so the active-call screen can render the post-call summary.
                // dismissActiveCall() is what actually clears it once the user acknowledges.
            } else if incomingCall?.session.callUUID == callUUID {
                // The pending incoming call ended before ever being answered (declined via
                // CallKit's native action, or the caller gave up) -- previously a known,
                // deliberately-accepted gap (the banner/lock-screen call never auto-dismissed in
                // this exact scenario, see DECISIONS.md); fixed as a side effect of making this
                // handler properly reactive rather than something needing its own separate fix.
                incomingCall = nil
            }
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
