import SwiftUI

/// One of the 5/10/15/20/30-minute preset pills, or the custom-entry chip. Minimum 44x44
/// tap target per DESIGN_SYSTEM.md regardless of the label's natural size.
struct DurationChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.headline)
                .padding(.horizontal, 20)
                .frame(minHeight: 44)
        }
        .background(isSelected ? Color.gtAccent : Color.gtSurface)
        .foregroundStyle(isSelected ? Color.white : Color.gtTextPrimary)
        .clipShape(Capsule())
        .overlay(
            Capsule().strokeBorder(isSelected ? Color.clear : Color.gtTextSecondary.opacity(0.25), lineWidth: 1)
        )
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
