import SwiftUI
import GotTimeCore

/// Kept simple per spec section 8: connected person, date/time, requested duration, actual
/// connected duration, and status — nothing more (no analytics, no charts).
struct HistoryView: View {
    @Environment(\.appEnvironment) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [CallHistoryEntry] = []
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if entries.isEmpty {
                EmptyState(
                    symbol: "clock",
                    title: "No calls yet",
                    message: "Calls you make or receive will show up here."
                )
            } else {
                List(entries) { entry in
                    HistoryRow(entry: entry)
                        .listRowBackground(Color.gtSurface)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .accessibilityIdentifier("historyList")
            }
        }
        .background(Color.gtBackground)
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Close") { dismiss() }
            }
        }
        .task {
            entries = (try? await environment.callHistoryService.fetchHistory()) ?? []
            isLoading = false
        }
    }
}

private struct HistoryRow: View {
    let entry: CallHistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.otherPerson.firstName ?? "Unknown")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.gtTextPrimary)
                Spacer()
                Text(entry.session.initiatedAt, style: .date)
                    .font(.footnote)
                    .foregroundStyle(Color.gtTextSecondary)
            }

            HStack {
                Text(directionAndDuration)
                    .font(.footnote)
                    .foregroundStyle(Color.gtTextSecondary)
                Spacer()
                CallStatusBadge(status: entry.session.status)
            }
        }
        .padding(.vertical, 6)
    }

    private var directionAndDuration: String {
        let direction = entry.isOutgoing ? "Outgoing" : "Incoming"
        let requestedMinutes = entry.session.requestedDurationSeconds / 60
        if let actual = entry.session.actualDurationSeconds, actual > 0 {
            return "\(direction) • requested \(requestedMinutes) min • talked \(formattedDuration(actual))"
        }
        return "\(direction) • requested \(requestedMinutes) min"
    }

    private func formattedDuration(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        if minutes == 0 { return "\(remainingSeconds)s" }
        return "\(minutes)m \(remainingSeconds)s"
    }
}
