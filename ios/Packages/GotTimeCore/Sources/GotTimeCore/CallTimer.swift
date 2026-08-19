import Foundation

/// Computes call countdown state from authoritative timestamps only — never from an
/// accumulated, decrementing counter (spec section 7: "do not implement the timer as a
/// fragile once-per-second decrement... so backgrounding, screen locking, and UI pauses do
/// not corrupt remaining time"). Every value here is a pure function of `connectedAt` +
/// `requestedDurationSeconds` + "now" — there is no mutable internal state to drift, so a
/// read taken after any gap (background, lock screen, a paused Timer, a relaunch) is exactly
/// as correct as one taken every second. Deliberately has no dev-acceleration concept of its
/// own — that's GotTimeMocks' responsibility (scale the duration before constructing this),
/// keeping this production math unconditional and free of debug-flag branching.
public struct CallTimer: Equatable, Sendable {
    public let connectedAt: Date
    public let requestedDurationSeconds: Int

    public init(connectedAt: Date, requestedDurationSeconds: Int) {
        self.connectedAt = connectedAt
        self.requestedDurationSeconds = requestedDurationSeconds
    }

    public var expiresAt: Date {
        connectedAt.addingTimeInterval(TimeInterval(requestedDurationSeconds))
    }

    /// Seconds remaining at `now`, clamped to zero. Rounds up (ceiling): the displayed count
    /// should only step down once a full second has actually elapsed, not the instant a
    /// fraction of a second passes — otherwise a countdown from "10:00" would flicker to
    /// "9:59" a millisecond after connecting.
    public func remainingSeconds(at now: Date) -> Int {
        max(0, Int(expiresAt.timeIntervalSince(now).rounded(.up)))
    }

    /// Seconds actually elapsed since connection, clamped to [0, requestedDurationSeconds].
    /// Rounds down (floor), the mirror of remainingSeconds' rounding, so the two stay
    /// consistent with each other at any instant. Never exceeds the requested duration even
    /// if `now` is well past expiry — this is a pure query, not the thing that actually ends
    /// the call; the caller is responsible for disconnecting at zero.
    public func elapsedSeconds(at now: Date) -> Int {
        let raw = now.timeIntervalSince(connectedAt)
        return min(requestedDurationSeconds, max(0, Int(raw.rounded(.down))))
    }

    public func isExpired(at now: Date) -> Bool {
        now >= expiresAt
    }

    public enum WarningLevel: Equatable, Sendable {
        case normal
        case oneMinuteRemaining
        case finalTenSeconds
    }

    /// Matches spec section 6's thresholds exactly: subtle indication at 60s remaining,
    /// slightly stronger (still calm) emphasis in the final 10 seconds. Stateless and pure —
    /// deciding whether a level is *new* (and therefore worth a haptic/animation) is the
    /// caller's job, by comparing against the level it last observed.
    public func warningLevel(at now: Date) -> WarningLevel {
        let remaining = remainingSeconds(at: now)
        if remaining <= 10 { return .finalTenSeconds }
        if remaining <= 60 { return .oneMinuteRemaining }
        return .normal
    }
}
