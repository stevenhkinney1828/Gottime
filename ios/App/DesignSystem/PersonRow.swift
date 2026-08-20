import SwiftUI
import GotTimeCore

/// A connected-person list item. Fast-tap target, generous height per DESIGN_SYSTEM.md.
struct PersonRow: View {
    let person: ConnectedPerson
    var subtitle: String?

    var body: some View {
        HStack(spacing: 16) {
            Circle()
                .fill(Color.gtAccent.opacity(0.15))
                .frame(width: 48, height: 48)
                .overlay(
                    Text(initial)
                        .font(.headline)
                        .foregroundStyle(Color.gtAccent)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(person.profile.firstName ?? "Unknown")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.gtTextPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(Color.gtTextSecondary)
                }
            }

            Spacer()

            Image(systemName: "phone.circle.fill")
                .font(.title2)
                .foregroundStyle(Color.gtAccent)
        }
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Call \(person.profile.firstName ?? "Unknown")")
    }

    private var initial: String {
        guard let first = person.profile.firstName?.first else { return "?" }
        return String(first).uppercased()
    }
}
