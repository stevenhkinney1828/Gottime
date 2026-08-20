import Foundation
import GotTimeCore

/// What the simulated ringing period resolves to. Defaults to the happy path; a developer
/// or UI test sets this before calling startCall to exercise the other outcomes (spec
/// section 19: "ringing, answer, decline, no answer, failure").
public enum MockCallOutcome: Sendable {
    case autoConnect
    case autoDecline
    case autoMissed
    case autoFail
}

/// Development-only VoiceService: simulates ringing -> connected -> countdown -> automatic
/// ending entirely locally, with no CallKit/PushKit/Twilio involved (those are Phase 4+).
/// A plain class with explicit locking, matching MockAuthService's rationale (a non-async
/// protocol requirement can't be satisfied by actor-isolated property access).
///
/// Every state transition, whether triggered by an explicit client call (answer/decline/
/// cancel/endEarly) or by the simulated-timing background tasks, funnels through `tryApply`,
/// which does its read-check-write atomically under one lock hold. That's what makes this
/// safe against a real (if narrow) race: e.g. the user tapping "End Call" at the exact
/// instant the simulated timer independently reaches zero. Whichever wins the race succeeds;
/// the other observes the already-changed state and cleanly no-ops rather than double-firing
/// a terminal transition or double-recording history.
public final class MockVoiceService: VoiceService, @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: AsyncStream<VoiceEvent>.Continuation
    public let events: AsyncStream<VoiceEvent>

    private var sessions: [UUID: CallSession] = [:]
    private var profileDirectory: [UUID: Profile]
    private var muted = false
    private var speakerEnabled = false

    private let selfUserId: UUID
    public var nextCallOutcome: MockCallOutcome = .autoConnect

    #if DEBUG
    /// e.g. 60 means a call that would really run 600s (10 min) instead runs 10s, countdown
    /// display included — spec section 17's "development-only accelerated timer," scoped
    /// entirely to this file so CallTimer itself never has to know acceleration exists.
    /// Never read outside a DEBUG build, so it structurally cannot affect production.
    public var devTimeScale: Double = 1.0
    #endif

    /// Not part of VoiceService — how a completed/ended call reaches History in mock mode,
    /// where (unlike the real backend) there's no shared database both services read from.
    public var onCallEnded: (@Sendable (CallHistoryEntry) -> Void)?

    private let ringingDelay: Duration = .milliseconds(600)
    private let ringToOutcomeDelay: Duration = .milliseconds(900)

    public init(
        selfUserId: UUID = MockData.me.id,
        knownProfiles: [Profile] = [MockData.me, MockData.chris, MockData.jordan]
    ) {
        self.selfUserId = selfUserId
        var directory: [UUID: Profile] = [:]
        for profile in knownProfiles { directory[profile.id] = profile }
        self.profileDirectory = directory
        let (stream, continuation) = AsyncStream<VoiceEvent>.makeStream()
        self.events = stream
        self.continuation = continuation
    }

    // MARK: - VoiceService

    @discardableResult
    public func startCall(to recipient: ConnectedPerson, durationSeconds: Int) async throws -> CallSession {
        print("[GotTime DEBUG] MockVoiceService.startCall: entry")
        lock.lock()
        profileDirectory[recipient.id] = recipient.profile
        lock.unlock()
        print("[GotTime DEBUG] MockVoiceService.startCall: profileDirectory updated, lock released")

        var effectiveDuration = durationSeconds
        #if DEBUG
        if devTimeScale > 1 {
            effectiveDuration = max(1, Int((Double(durationSeconds) / devTimeScale).rounded()))
        }
        #endif

        let now = Date()
        var session = CallSession(
            id: UUID(),
            callUUID: UUID(),
            callerId: selfUserId,
            recipientId: recipient.id,
            requestedDurationSeconds: effectiveDuration,
            initiatedAt: now,
            status: .created,
            createdAt: now,
            updatedAt: now
        )
        session = (try? CallStateMachine.apply(.outgoing, to: session, at: now)) ?? session
        print("[GotTime DEBUG] MockVoiceService.startCall: about to storeNew, status=\(session.status)")
        storeNew(session)
        print("[GotTime DEBUG] MockVoiceService.startCall: stored, about to emitStatusChanged")
        emitStatusChanged(session)
        print("[GotTime DEBUG] MockVoiceService.startCall: emitted, scheduling auto-ringing, about to return")

        scheduleAutoRinging(callUUID: session.callUUID)
        print("[GotTime DEBUG] MockVoiceService.startCall: returning session \(session.callUUID)")
        return session
    }

    public func answer(callUUID: UUID) async throws {
        guard currentSession(callUUID) != nil else { throw MockServiceError.unknownCall }
        if let session = tryApply(callUUID: callUUID, to: .connected) {
            scheduleAutoExpiry(callUUID: callUUID, session: session)
        }
    }

    public func decline(callUUID: UUID) async throws {
        guard currentSession(callUUID) != nil else { throw MockServiceError.unknownCall }
        if tryApply(callUUID: callUUID, to: .declined) != nil {
            finalizeIfTerminal(callUUID: callUUID)
        }
    }

    public func cancel(callUUID: UUID) async throws {
        guard currentSession(callUUID) != nil else { throw MockServiceError.unknownCall }
        if tryApply(callUUID: callUUID, to: .canceled) != nil {
            finalizeIfTerminal(callUUID: callUUID)
        }
    }

    public func endEarly(callUUID: UUID) async throws {
        guard currentSession(callUUID) != nil else { throw MockServiceError.unknownCall }
        if tryApply(callUUID: callUUID, to: .endedEarly) != nil {
            finalizeIfTerminal(callUUID: callUUID)
        }
    }

    public func setMuted(_ muted: Bool) async throws {
        lock.lock()
        self.muted = muted
        lock.unlock()
    }

    public func setSpeakerEnabled(_ enabled: Bool) async throws {
        lock.lock()
        self.speakerEnabled = enabled
        lock.unlock()
    }

    // MARK: - Mock-only: testing the incoming-call path without a second device

    /// Not part of VoiceService. Lets a developer or UI test exercise the incoming-call
    /// screen directly — spec section 6: the recipient must see caller identity + requested
    /// duration before answering — without needing startCall's caller-side flow at all.
    @discardableResult
    public func simulateIncomingCall(from caller: Profile, requestedDurationSeconds: Int) -> CallSession {
        lock.lock()
        profileDirectory[caller.id] = caller
        lock.unlock()

        let now = Date()
        var session = CallSession(
            id: UUID(),
            callUUID: UUID(),
            callerId: caller.id,
            recipientId: selfUserId,
            requestedDurationSeconds: requestedDurationSeconds,
            initiatedAt: now,
            status: .created,
            createdAt: now,
            updatedAt: now
        )
        session = (try? CallStateMachine.apply(.outgoing, to: session, at: now)) ?? session
        session = (try? CallStateMachine.apply(.ringing, to: session, at: now)) ?? session
        storeNew(session)
        continuation.yield(.incomingCall(session: session, callerProfile: caller))
        return session
    }

    // MARK: - Internal simulation

    private func storeNew(_ session: CallSession) {
        lock.lock()
        sessions[session.callUUID] = session
        lock.unlock()
    }

    private func currentSession(_ callUUID: UUID) -> CallSession? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[callUUID]
    }

    private func profile(for id: UUID) -> Profile? {
        lock.lock()
        defer { lock.unlock() }
        return profileDirectory[id]
    }

    private func emitStatusChanged(_ session: CallSession) {
        continuation.yield(.statusChanged(session: session))
    }

    /// The single choke point every transition goes through — see the type-level doc comment
    /// for why this needs to be atomic. Returns the updated session on success, or nil if the
    /// call is unknown, the transition is invalid, or something else already moved the call
    /// to a different state first (a stale/lost race, not an error).
    @discardableResult
    private func tryApply(callUUID: UUID, to status: CallStatus) -> CallSession? {
        lock.lock()
        guard
            let session = sessions[callUUID],
            CallStateMachine.canTransition(from: session.status, to: status),
            let updated = try? CallStateMachine.apply(status, to: session, at: .now)
        else {
            lock.unlock()
            return nil
        }
        sessions[callUUID] = updated
        lock.unlock()
        emitStatusChanged(updated)
        return updated
    }

    private func scheduleAutoRinging(callUUID: UUID) {
        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.ringingDelay)
            guard self.tryApply(callUUID: callUUID, to: .ringing) != nil else { return }

            try? await Task.sleep(for: self.ringToOutcomeDelay)
            self.resolveAutoOutcome(callUUID: callUUID)
        }
    }

    private func resolveAutoOutcome(callUUID: UUID) {
        guard let session = currentSession(callUUID), session.status == .ringing else { return }
        let targetStatus: CallStatus
        switch nextCallOutcome {
        case .autoConnect: targetStatus = .connected
        case .autoDecline: targetStatus = .declined
        case .autoMissed: targetStatus = .missed
        case .autoFail: targetStatus = .failed
        }

        guard let updated = tryApply(callUUID: callUUID, to: targetStatus) else { return }
        if updated.status == .connected {
            scheduleAutoExpiry(callUUID: callUUID, session: updated)
        } else {
            finalizeIfTerminal(callUUID: callUUID)
        }
    }

    private func scheduleAutoExpiry(callUUID: UUID, session: CallSession) {
        guard let connectedAt = session.connectedAt else { return }
        let timer = CallTimer(connectedAt: connectedAt, requestedDurationSeconds: session.requestedDurationSeconds)
        let remaining = timer.remainingSeconds(at: .now)

        Task { [weak self] in
            guard let self else { return }
            if remaining > 0 {
                try? await Task.sleep(for: .seconds(remaining))
            }
            // Mirrors the real system's primary enforcement layer (spec section 7 /
            // DECISIONS.md): the client computes its own expiry and disconnects locally,
            // independent of any server confirmation.
            guard self.tryApply(callUUID: callUUID, to: .timedOut) != nil else { return }
            guard self.tryApply(callUUID: callUUID, to: .completed) != nil else { return }
            self.finalizeIfTerminal(callUUID: callUUID)
        }
    }

    private func finalizeIfTerminal(callUUID: UUID) {
        guard let session = currentSession(callUUID), session.status.isTerminal else { return }
        continuation.yield(.callEnded(callUUID: callUUID))
        guard
            let onCallEnded,
            let otherId = session.otherParticipant(from: selfUserId),
            let otherProfile = profile(for: otherId)
        else { return }
        let entry = CallHistoryEntry(session: session, otherPerson: otherProfile, isOutgoing: session.callerId == selfUserId)
        onCallEnded(entry)
    }
}
