import SwiftUI
import GotTimeCore

/// The countdown is the visual hero once connected (spec section 6). This same screen also
/// covers the pre-connection "Calling..." wait and the post-call summary — one continuous
/// full-screen presentation from the moment a call starts until the user dismisses the
/// result, rather than three separate screens the coordinator would have to choreograph
/// transitions between.
struct ActiveCallView: View {
    let session: CallSession
    let otherPerson: Profile

    @Environment(CallCoordinator.self) private var coordinator
    @State private var isMuted = false
    @State private var isSpeakerOn = false

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            Text(otherPerson.firstName ?? "Unknown")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.gtTextPrimary)

            content

            Spacer()

            if session.status == .connected {
                controls
            } else if !session.status.isTerminal {
                DestructiveButton(title: "Cancel") {
                    Task { await coordinator.endActiveCall() }
                }
                .padding(.horizontal, 48)
            }

            Spacer().frame(height: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.gtBackground)
    }

    @ViewBuilder
    private var content: some View {
        if session.status.isTerminal {
            postCallSummary
        } else if session.status == .connected {
            VStack(spacing: 8) {
                Text("Time remaining")
                    .font(.footnote)
                    .foregroundStyle(Color.gtTextSecondary)
                CountdownView(
                    remainingSeconds: coordinator.remainingSeconds ?? session.requestedDurationSeconds,
                    warningLevel: coordinator.warningLevel
                )
            }
        } else {
            VStack(spacing: 12) {
                ProgressView()
                Text(session.status == .ringing ? "Ringing..." : "Calling...")
                    .font(.headline)
                    .foregroundStyle(Color.gtTextSecondary)
            }
        }
    }

    private var postCallSummary: some View {
        VStack(spacing: 12) {
            Text(summaryTitle)
                .font(.title.bold())
                .foregroundStyle(Color.gtTextPrimary)
            if let actualDuration = session.actualDurationSeconds, actualDuration > 0 {
                Text(formattedDuration(actualDuration))
                    .font(.subheadline)
                    .foregroundStyle(Color.gtTextSecondary)
            }
            CallStatusBadge(status: session.status)

            VStack(spacing: 12) {
                PrimaryButton(title: "Call \(otherPerson.firstName ?? "again") again") {
                    coordinator.dismissActiveCall()
                }
                Button("Done") {
                    coordinator.dismissActiveCall()
                }
                .font(.body)
                .foregroundStyle(Color.gtTextSecondary)
            }
            .padding(.horizontal, 48)
            .padding(.top, 16)
        }
    }

    private var summaryTitle: String {
        switch session.status {
        case .completed: return "Time's up"
        case .endedEarly: return "Call ended"
        case .declined: return "\(otherPerson.firstName ?? "They") declined"
        case .missed: return "No answer"
        case .canceled: return "Call canceled"
        case .failed: return "Call failed"
        default: return "Call ended"
        }
    }

    private var controls: some View {
        HStack(spacing: 32) {
            controlButton(symbol: isMuted ? "mic.slash.fill" : "mic.fill", label: "Mute", isActive: isMuted) {
                isMuted.toggle()
                Task { await coordinator.setMuted(isMuted) }
            }
            controlButton(symbol: "phone.down.fill", label: "End", isActive: false, tint: .gtDestructive) {
                Task { await coordinator.endActiveCall() }
            }
            controlButton(symbol: "speaker.wave.2.fill", label: "Speaker", isActive: isSpeakerOn) {
                isSpeakerOn.toggle()
                Task { await coordinator.setSpeakerEnabled(isSpeakerOn) }
            }
        }
    }

    private func controlButton(symbol: String, label: String, isActive: Bool, tint: Color = .gtAccent, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Circle()
                    .fill(isActive ? tint : Color.gtSurface)
                    .frame(width: 60, height: 60)
                    .overlay(
                        Image(systemName: symbol)
                            .font(.title3)
                            .foregroundStyle(isActive ? Color.white : tint)
                    )
                Text(label)
                    .font(.caption)
                    .foregroundStyle(Color.gtTextSecondary)
            }
        }
        .accessibilityLabel(label)
    }

    private func formattedDuration(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        if minutes == 0 {
            return "\(remainingSeconds) second\(remainingSeconds == 1 ? "" : "s")"
        }
        return "\(minutes) minute\(minutes == 1 ? "" : "s") \(remainingSeconds) second\(remainingSeconds == 1 ? "" : "s")"
    }
}
