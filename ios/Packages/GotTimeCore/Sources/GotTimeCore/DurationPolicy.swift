import Foundation

/// Duration validation and the preset options from spec section 6. This is one of three
/// independent duration-enforcement layers (see DECISIONS.md) — the other two are the
/// request-call Edge Function and the `requested_duration_seconds` CHECK constraint in
/// 0004_call_sessions.sql (lowered by 0011_lower_duration_minimum.sql). All three must agree on
/// the same bound — originally 1-60 whole minutes, now 15-3600 seconds (the owner asked for
/// arbitrary sub-minute and non-round durations, not just whole minutes; `validateMinutes`/
/// `parseCustomMinutes` below still enforce the original whole-minute bound for whatever still
/// calls them, `validateSeconds`/`parseCustomDuration` are the real bound going forward).
public enum DurationPolicy {
    public static let presetMinutes: [Int] = [5, 10, 15, 20, 30]
    public static let minimumMinutes = 1
    public static let maximumMinutes = 60

    /// Short presets added directly in seconds, alongside (not replacing) `presetMinutes` above
    /// -- 15s/30s fall below the original whole-minute floor entirely, added per the owner's
    /// own request. Already-known-valid constants, same as `presetMinutes`' own entries — never
    /// re-validated before use, matching how a minute preset was never re-validated either.
    /// 60/180 (1 min/3 min) are included here too so the duration picker has one single ordered
    /// list to render instead of merging two. The 15s floor is matched by request-call's own
    /// `MIN_DURATION_SECONDS` and the `call_sessions` CHECK constraint (0011_lower_duration_minimum.sql).
    public static let presetSeconds: [Int] = [15, 30, 60, 180]

    /// The real floor once sub-minute presets/custom entry exist -- matches request-call's own
    /// `MIN_DURATION_SECONDS` and the `call_sessions` CHECK constraint
    /// (0011_lower_duration_minimum.sql). `minimumMinutes`/`maximumMinutes` above stay as they
    /// were for `validateMinutes`/`parseCustomMinutes`'s own whole-minute-only callers.
    public static let minimumSeconds = 15

    public enum ValidationError: Error, Equatable, Sendable {
        case tooShort(minutes: Int)
        case tooLong(minutes: Int)
        case notWholeMinutes
        /// For `validateSeconds`/`parseCustomDuration` below, which work in raw seconds rather
        /// than whole minutes -- carries the actual out-of-bounds value so a caller can decide
        /// whether it was too short or too long without a separate pair of cases.
        case outOfRange(seconds: Int)
    }

    /// Validates a whole-minute count already parsed as an Int (e.g. from a preset tap) and
    /// returns the duration in seconds.
    public static func validateMinutes(_ minutes: Int) -> Result<Int, ValidationError> {
        if minutes < minimumMinutes {
            return .failure(.tooShort(minutes: minutes))
        }
        if minutes > maximumMinutes {
            return .failure(.tooLong(minutes: minutes))
        }
        return .success(minutes * 60)
    }

    /// Parses free-form custom-duration text (from a text field) into whole minutes, then
    /// validates it. Anything that isn't a clean integer — decimals, blank input, non-numeric
    /// text — is rejected as `.notWholeMinutes` rather than silently truncated or defaulted.
    public static func parseCustomMinutes(_ text: String) -> Result<Int, ValidationError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let minutes = Int(trimmed) else {
            return .failure(.notWholeMinutes)
        }
        return validateMinutes(minutes)
    }

    public static func seconds(forMinutes minutes: Int) -> Int {
        minutes * 60
    }

    /// Validates a raw second count against the real floor/ceiling (15-3600s) -- unlike
    /// `validateMinutes`, this doesn't require the value to be a whole minute, since the owner
    /// specifically asked for arbitrary durations like "1 minute and 12 seconds," not just
    /// round minutes.
    public static func validateSeconds(_ seconds: Int) -> Result<Int, ValidationError> {
        guard seconds >= minimumSeconds, seconds <= maximumMinutes * 60 else {
            return .failure(.outOfRange(seconds: seconds))
        }
        return .success(seconds)
    }

    /// Parses a separate minutes field and seconds field (e.g. "1" and "12" from two text
    /// fields) into a validated total. Either field may be blank (treated as 0), but not both --
    /// a genuinely empty custom entry should show no confirmed duration, the same as the old
    /// single-field entry did. The seconds field must be 0-59; carrying "90 seconds" in the
    /// seconds field instead of "1 minute 30 seconds" would be a confusing way to enter the same
    /// duration two different ways.
    public static func parseCustomDuration(minutesText: String, secondsText: String) -> Result<Int, ValidationError> {
        let trimmedMinutes = minutesText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSeconds = secondsText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedMinutes.isEmpty && trimmedSeconds.isEmpty {
            return .failure(.notWholeMinutes)
        }
        guard
            let minutesValue = nonNegativeIntOrZero(trimmedMinutes),
            let secondsValue = nonNegativeIntOrZero(trimmedSeconds),
            (0..<60).contains(secondsValue)
        else {
            return .failure(.notWholeMinutes)
        }
        return validateSeconds(minutesValue * 60 + secondsValue)
    }

    /// A blank field means "0" (the other field carries the whole value); anything present that
    /// isn't a clean non-negative integer is rejected outright, same spirit as
    /// `parseCustomMinutes`'s own "reject, don't truncate or default" rule.
    private static func nonNegativeIntOrZero(_ trimmedText: String) -> Int? {
        if trimmedText.isEmpty { return 0 }
        guard let value = Int(trimmedText), value >= 0 else { return nil }
        return value
    }

    /// Formats a duration for display -- "45 seconds", "5 minutes", "1 minute 12 seconds".
    /// Omits the seconds component when it's exactly zero, so an exact-minute value (e.g. any of
    /// the presets) reads as "5 minutes," not "5 minutes 0 seconds." The single formatter used
    /// everywhere a duration is shown (incoming call, duration picker, history), replacing
    /// several slightly-different ad hoc implementations that assumed whole minutes and
    /// silently showed "0 minutes" for anything under 60 seconds.
    public static func formatDuration(_ totalSeconds: Int) -> String {
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if minutes == 0 {
            return "\(seconds) second\(seconds == 1 ? "" : "s")"
        }
        if seconds == 0 {
            return "\(minutes) minute\(minutes == 1 ? "" : "s")"
        }
        return "\(minutes) minute\(minutes == 1 ? "" : "s") \(seconds) second\(seconds == 1 ? "" : "s")"
    }
}
