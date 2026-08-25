import Foundation

/// Duration validation and the preset options from spec section 6. This is one of three
/// independent duration-enforcement layers (see DECISIONS.md) — the other two are the
/// request-call Edge Function and the `requested_duration_seconds` CHECK constraint in
/// 0004_call_sessions.sql. All three must agree on the same 1-60 whole-minute bound.
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

    public enum ValidationError: Error, Equatable, Sendable {
        case tooShort(minutes: Int)
        case tooLong(minutes: Int)
        case notWholeMinutes
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
}
