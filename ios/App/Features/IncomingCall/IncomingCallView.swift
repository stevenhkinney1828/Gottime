import SwiftUI
import GotTimeCore

/// In-app incoming-call presentation for Phase 1 mock mode. Real incoming calls are reported
/// straight to CallKit's native system UI in Phase 5 (spec section 6: the recipient must see
/// identity + requested duration before answering, without needing to unlock and open the
/// app) — this screen exists so the same experience can be exercised end-to-end before
/// CallKit is wired in, not as a permanent secondary UI once it is.
struct IncomingCallView: View {
    let session: CallSession
    let callerProfile: Profile

    @Environment(CallCoordinator.self) private var coordinator

    private var requestedDurationLabel: String {
        DurationPolicy.formatDuration(session.requestedDurationSeconds)
    }

    private var accessibilityLabel: String {
        let base = "\(callerProfile.firstName ?? "Unknown") is calling for \(requestedDurationLabel)"
        guard let topic = session.topic, !topic.isEmpty else { return base }
        return "\(base), about \(topic)"
    }

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Circle()
                .fill(Color.gtAccent.opacity(0.15))
                .frame(width: 120, height: 120)
                .overlay(
                    Text((callerProfile.firstName?.first).map(String.init)?.uppercased() ?? "?")
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundStyle(Color.gtAccent)
                )

            VStack(spacing: 8) {
                Text(callerProfile.firstName ?? "Unknown")
                    .font(.largeTitle.bold())
                    .foregroundStyle(Color.gtTextPrimary)
                Text(requestedDurationLabel)
                    .font(.title3)
                    .foregroundStyle(Color.gtTextSecondary)
                if let topic = session.topic, !topic.isEmpty {
                    Text(topic)
                        .font(.body)
                        .foregroundStyle(Color.gtTextSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)

            Spacer()

            HStack(spacing: 48) {
                answerControl(
                    symbol: "phone.down.fill",
                    label: "Decline",
                    tint: .gtDestructive
                ) {
                    Task { await coordinator.declineIncomingCall() }
                }
                answerControl(
                    symbol: "phone.fill",
                    label: "Answer",
                    tint: .gtAccent
                ) {
                    Task { await coordinator.answerIncomingCall() }
                }
            }

            Spacer().frame(height: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.gtBackground)
    }

    private func answerControl(symbol: String, label: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Circle()
                    .fill(tint)
                    .frame(width: 68, height: 68)
                    .overlay(
                        Image(systemName: symbol)
                            .font(.title2)
                            .foregroundStyle(Color.white)
                    )
                Text(label)
                    .font(.callout)
                    .foregroundStyle(Color.gtTextSecondary)
            }
        }
        .accessibilityLabel(label)
    }
}
