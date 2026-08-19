import Foundation

public enum CallTransitionError: Error, Equatable, Sendable {
    case invalidTransition(from: CallStatus, to: CallStatus)
}

/// The single source of truth for which call-status transitions are valid. Stateless by
/// design — the actual state lives on a `CallSession`; this just validates and (via `apply`)
/// consistently stamps the right timestamp/duration fields when a transition happens.
/// Consulted both client-side (before optimistically updating UI) and, conceptually,
/// server-side (the request-call/call-action/twilio-status-callback Edge Functions apply the
/// same rules when writing call_sessions.status — see spec section 14: "prevent invalid
/// transitions where practical").
public enum CallStateMachine {
    /// True for a defined forward transition, or for repeating the same state — the latter
    /// is a deliberate no-op allowance for duplicate status-callback delivery (spec section
    /// 16: "duplicate/stale incoming invitation"), not a loophole.
    public static func canTransition(from: CallStatus, to: CallStatus) -> Bool {
        if from == to { return true }
        return allowedTransitions[from]?.contains(to) ?? false
    }

    @discardableResult
    public static func transition(from: CallStatus, to: CallStatus) throws -> CallStatus {
        guard canTransition(from: from, to: to) else {
            throw CallTransitionError.invalidTransition(from: from, to: to)
        }
        return to
    }

    /// Validates the transition and returns an updated copy of `session` with `status`,
    /// `updatedAt`, and the appropriate lifecycle timestamp set. Idempotent re-application of
    /// the same status never overwrites an already-set timestamp.
    public static func apply(_ status: CallStatus, to session: CallSession, at date: Date) throws -> CallSession {
        try transition(from: session.status, to: status)

        var updated = session
        updated.status = status
        updated.updatedAt = date

        switch status {
        case .created, .outgoing:
            break

        case .ringing:
            if updated.ringingAt == nil { updated.ringingAt = date }

        case .connected:
            if updated.connectedAt == nil { updated.connectedAt = date }

        case .declined, .missed, .failed, .canceled, .endedEarly, .timedOut, .completed:
            if updated.endedAt == nil { updated.endedAt = date }
            if let connectedAt = updated.connectedAt, updated.actualDurationSeconds == nil {
                updated.actualDurationSeconds = max(0, Int(date.timeIntervalSince(connectedAt)))
            }
        }

        return updated
    }

    /// created -> outgoing -> ringing -> connected -> {endedEarly | timedOut -> completed}
    /// is the happy path. Every other entry is a specific, deliberate early-exit; terminal
    /// states (see CallStatus.isTerminal) map to an empty set.
    static let allowedTransitions: [CallStatus: Set<CallStatus>] = [
        .created: [.outgoing, .failed],
        .outgoing: [.ringing, .canceled, .failed],
        .ringing: [.connected, .declined, .canceled, .missed, .failed],
        .connected: [.endedEarly, .timedOut, .failed],
        .timedOut: [.completed],
        .declined: [],
        .missed: [],
        .failed: [],
        .canceled: [],
        .endedEarly: [],
        .completed: [],
    ]
}
