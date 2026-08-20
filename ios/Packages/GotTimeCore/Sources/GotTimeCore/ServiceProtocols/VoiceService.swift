import Foundation

/// Something happened to a call that the UI layer (or CallStateMachine-driving code) needs
/// to react to. In production this is driven by CallKit actions + Twilio Voice SDK
/// delegates + backend status callbacks; in GotTimeMocks it's driven by simulated timers.
/// Either way, the rest of the app reacts to this stream the same way regardless of which
/// implementation is behind it.
public enum VoiceEvent: Equatable, Sendable {
    /// A call is incoming and should be reported to CallKit (or, in mock mode, shown as an
    /// in-app incoming-call banner). `callerProfile` is what lets the recipient see identity
    /// + requested duration before answering (spec section 6).
    case incomingCall(session: CallSession, callerProfile: Profile)

    /// The call transitioned to a new status. Carries the full session (not just the status)
    /// so a consumer never needs a separate "fetch current session" query to know
    /// `connectedAt`/`ringingAt`/etc. — `connected_at` being set is what starts the timer,
    /// see CallTimer.
    case statusChanged(session: CallSession)

    /// The underlying voice connection is fully torn down (CallKit cleaned up, Twilio call
    /// ended). Always follows a terminal `statusChanged` event; exists as its own case
    /// because teardown can lag the status transition slightly in the real implementation.
    case callEnded(callUUID: UUID)
}

/// Implemented by GotTimeMocks (development) and by a real CallKit + Twilio Voice SDK
/// adapter (Phase 4+). Deliberately does not expose CallKit/Twilio types — this protocol is
/// the boundary that keeps GotTimeCore free of Apple-framework imports.
public protocol VoiceService {
    var events: AsyncStream<VoiceEvent> { get }

    /// Caller-initiated. `durationSeconds` must already be validated by DurationPolicy —
    /// this method does not re-validate it, matching the real implementation where duration
    /// authorization actually happens server-side (spec section 13).
    @discardableResult
    func startCall(to recipient: ConnectedPerson, durationSeconds: Int) async throws -> CallSession

    /// Recipient action: accept an incoming call.
    func answer(callUUID: UUID) async throws

    /// Recipient action: reject an incoming call before it connects.
    func decline(callUUID: UUID) async throws

    /// Caller action: give up on an outgoing call while it's still ringing.
    func cancel(callUUID: UUID) async throws

    /// Either participant, only while `connected`: hang up before the timer reaches zero.
    /// There is no "extend" action anywhere in this protocol — that's deliberate (spec
    /// section 2: "the current call cannot be extended").
    func endEarly(callUUID: UUID) async throws

    func setMuted(_ muted: Bool) async throws
    func setSpeakerEnabled(_ enabled: Bool) async throws
}
