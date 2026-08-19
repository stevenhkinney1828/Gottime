import Foundation

/// The full call lifecycle, matching the `call_sessions.status` values exactly — the raw
/// values are the literal strings stored in Postgres, so this type can decode directly from
/// API responses without a separate mapping layer. Eleven cases, not the ten in spec section
/// 14: `canceled` was added to reconcile section 14 with section 8's required History
/// outcomes and section 16's "caller cancels while ringing" case — see DECISIONS.md.
public enum CallStatus: String, Codable, Sendable, CaseIterable {
    case created
    case outgoing
    case ringing
    case connected
    case declined
    case missed
    case failed
    case canceled
    case endedEarly = "ended_early"
    case timedOut = "timed_out"
    case completed

    /// No further transitions are possible from this status — CallStateMachine consults this
    /// to reject any transition attempted from a terminal state. `timedOut` is deliberately
    /// NOT terminal: it always proceeds to `completed` once teardown is confirmed (see
    /// ARCHITECTURE.md's call lifecycle walkthrough) — it's a narrow waypoint, not an ending.
    public var isTerminal: Bool {
        switch self {
        case .declined, .missed, .failed, .canceled, .endedEarly, .completed:
            return true
        case .created, .outgoing, .ringing, .connected, .timedOut:
            return false
        }
    }

    /// The call reached a real, connected, two-way-audio state at some point. Distinguishes
    /// "timed out/ended after a real conversation" from "never connected" outcomes for
    /// History.
    public var wasEverConnected: Bool {
        switch self {
        case .endedEarly, .timedOut, .completed:
            return true
        case .created, .outgoing, .ringing, .connected, .declined, .missed, .failed, .canceled:
            return false
        }
    }
}
