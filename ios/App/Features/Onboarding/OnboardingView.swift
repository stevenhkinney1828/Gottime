import SwiftUI
import GotTimeCore

/// Shown once, right after first sign-in, when Sign in with Apple didn't supply a name (or
/// the user declined to share it) — profile.first_name is nullable at the database layer for
/// exactly this reason (see 0001_profiles.sql).
struct OnboardingView: View {
    let profile: Profile

    @Environment(\.appEnvironment) private var environment
    @State private var firstName: String = ""
    @State private var isSaving = false

    private var trimmedName: String {
        firstName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 8) {
                Text("What should we call you?")
                    .font(.title2.bold())
                    .foregroundStyle(Color.gtTextPrimary)
                Text("This is what connected people will see when you call.")
                    .font(.subheadline)
                    .foregroundStyle(Color.gtTextSecondary)
                    .multilineTextAlignment(.center)
            }

            TextField("First name", text: $firstName)
                .textContentType(.givenName)
                .font(.title3)
                .padding()
                .background(Color.gtSurface)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .submitLabel(.done)
                .padding(.horizontal, 32)

            PrimaryButton(title: "Continue", isDisabled: trimmedName.isEmpty || isSaving) {
                Task {
                    isSaving = true
                    try? await environment.authService.updateFirstName(trimmedName)
                    isSaving = false
                }
            }
            .padding(.horizontal, 32)

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.gtBackground)
    }
}
