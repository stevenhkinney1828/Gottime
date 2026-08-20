import SwiftUI

/// Placeholder sign-in screen. Real Sign in with Apple lands in Phase 2 — MockAuthService
/// starts signed in by default, so this is rarely seen during Phase 1 testing, but it needs
/// to exist and work so signOut()/deleteAccount() (exercised from Settings) have somewhere
/// sensible to land.
struct SignedOutView: View {
    @Environment(\.appEnvironment) private var environment

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            VStack(spacing: 8) {
                Text("GotTime?")
                    .font(.largeTitle.bold())
                Text("Agree on a time. Talk. It ends on its own.")
                    .font(.subheadline)
                    .foregroundStyle(Color.gtTextSecondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            PrimaryButton(title: "Sign in with Apple") {
                Task { try? await environment.authService.signInWithApple() }
            }
            .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.gtBackground)
    }
}
