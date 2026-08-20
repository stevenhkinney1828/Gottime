import SwiftUI

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.gtTextSecondary)
            .textCase(.uppercase)
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 40))
                .foregroundStyle(Color.gtTextSecondary)
            Text(title)
                .font(.headline)
                .foregroundStyle(Color.gtTextPrimary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Color.gtTextSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}
