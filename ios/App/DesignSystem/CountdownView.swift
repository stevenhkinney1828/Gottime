import SwiftUI
import GotTimeCore

/// The active-call hero. Color shifts (calm -> warning amber) are always paired with a
/// weight/size change, never color alone (DESIGN_SYSTEM.md) — someone who can't distinguish
/// the color still gets the signal from the digits visibly growing bolder.
struct CountdownView: View {
    let remainingSeconds: Int
    let warningLevel: CallTimer.WarningLevel

    private var minutes: Int { remainingSeconds / 60 }
    private var seconds: Int { remainingSeconds % 60 }

    private var formatted: String {
        String(format: "%d:%02d", minutes, seconds)
    }

    private var color: Color {
        switch warningLevel {
        case .normal: return .gtTimerCalm
        case .oneMinuteRemaining, .finalTenSeconds: return .gtTimerWarning
        }
    }

    private var weight: Font.Weight {
        switch warningLevel {
        case .normal: return .semibold
        case .oneMinuteRemaining: return .bold
        case .finalTenSeconds: return .heavy
        }
    }

    private var fontSize: CGFloat {
        switch warningLevel {
        case .normal, .oneMinuteRemaining: return 72
        case .finalTenSeconds: return 80
        }
    }

    var body: some View {
        Text(formatted)
            .font(.system(size: fontSize, weight: weight, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(color)
            .contentTransition(.numericText(countsDown: true))
            .animation(.easeInOut(duration: 0.2), value: remainingSeconds)
            .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        if minutes > 0 {
            return "\(minutes) minute\(minutes == 1 ? "" : "s") \(seconds) second\(seconds == 1 ? "" : "s") remaining"
        }
        return "\(seconds) second\(seconds == 1 ? "" : "s") remaining"
    }
}
