import Foundation

/// Duration validation and the preset options from spec section 6. This is one of three
/// independent duration-enforcement layers (see DECISIONS.md) — the other two are the
/// request-call Edge Function and the `requested_duration_seconds` CHECK constraint in
/// 0004_call_sessions.sql. All three must agree on the same 1-60 whole-minute bound.
public enum DurationPolicy {
    public static let presetMinutes: [Int] = [5, 10, 15, 20, 30]
    public static let minimumMinutes = 1
    public static let maximumMinutes = 60

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
