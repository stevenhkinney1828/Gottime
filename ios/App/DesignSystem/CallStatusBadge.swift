import SwiftUI
import GotTimeCore

/// A history row's status indicator — icon + text together, never color alone, matching
/// CountdownView's same principle.
struct CallStatusBadge: View {
    let status: CallStatus

    private var config: (symbol: String, label: String, tint: Color) {
        switch status {
        case .completed:
            return ("checkmark.circle.fill", "Completed", .gtTextSecondary)
        case .endedEarly:
            return ("arrow.down.right.circle.fill", "Ended early", .gtTextSecondary)
        case .declined:
            return ("phone.down.fill", "Declined", .gtDestructive)
        case .missed:
            return ("phone.arrow.down.left.fill", "Missed", .gtDestructive)
        case .canceled:
            return ("xmark.circle.fill", "Canceled", .gtTextSecondary)
        case .failed:
            return ("exclamationmark.triangle.fill", "Failed", .gtDestructive)
        case .created, .outgoing, .ringing, .connected, .timedOut:
            // Never actually shown in History — these are non-terminal/in-progress states —
            // but exhaustive so this view compiles without a default case masking a future
            // missing status.
            return ("clock.fill", "In progress", .gtTextSecondary)
        }
    }

    var body: some View {
        Label(config.label, systemImage: config.symbol)
            .font(.footnote)
            .foregroundStyle(config.tint)
    }
}
