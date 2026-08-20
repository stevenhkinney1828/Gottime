import SwiftUI
import GotTimeCore

/// Exactly the list from spec section 8 — nothing more. "Avoid... unnecessary settings" is a
/// direct instruction, not just a suggestion.
struct SettingsView: View {
    @Environment(\.appEnvironment) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var profile: Profile?
    @State private var isEditingName = false
    @State private var editedName = ""
    @State private var showingDeleteConfirmation = false
    @State private var showingHowItWorks = false

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    var body: some View {
        Form {
            Section("Profile") {
                if isEditingName {
                    TextField("First name", text: $editedName)
                        .textContentType(.givenName)
                    Button("Save") {
                        Task { await saveName() }
                    }
                    .disabled(editedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    HStack {
                        Text("First name")
                        Spacer()
                        Text(profile?.firstName ?? "—")
                            .foregroundStyle(Color.gtTextSecondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        editedName = profile?.firstName ?? ""
                        isEditingName = true
                    }
                }
            }

            Section("Connections") {
                NavigationLink("Add a connection") {
                    AddConnectionView()
                }
            }

            Section("Notifications") {
                HStack {
                    Text("Incoming call alerts")
                    Spacer()
                    Text("Not yet set up")
                        .foregroundStyle(Color.gtTextSecondary)
                }
            }

            Section {
                Button("How GotTime? works") {
                    showingHowItWorks = true
                }
            }

            Section {
                Button("Sign out") {
                    Task { try? await environment.authService.signOut() }
                }
                .foregroundStyle(Color.gtTextPrimary)
            }

            Section {
                Button("Delete account") {
                    showingDeleteConfirmation = true
                }
                .foregroundStyle(Color.gtDestructive)
            }

            Section {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(appVersion)
                        .foregroundStyle(Color.gtTextSecondary)
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Close") { dismiss() }
            }
        }
        .confirmationDialog(
            "Delete your account?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Account", role: .destructive) {
                Task { try? await environment.authService.deleteAccount() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes your profile, connections, and call history. This can't be undone.")
        }
        .sheet(isPresented: $showingHowItWorks) {
            HowItWorksView()
        }
        .task {
            if case .signedIn(let signedInProfile) = await environment.authService.currentState() {
                profile = signedInProfile
            }
        }
    }

    private func saveName() async {
        let trimmed = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? await environment.authService.updateFirstName(trimmed)
        if case .signedIn(let updated) = await environment.authService.currentState() {
            profile = updated
        }
        isEditingName = false
    }
}

private struct HowItWorksView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Pick someone, pick a length of time, and call.")
                    Text("They'll see who's calling and how long you're asking for before they answer.")
                    Text("Once they answer, a countdown starts. When it reaches zero, the call ends automatically — no confirmation needed.")
                    Text("Want to keep talking? Start another call.")
                }
                .font(.body)
                .foregroundStyle(Color.gtTextPrimary)
                .padding(24)
            }
            .navigationTitle("How GotTime? Works")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}
