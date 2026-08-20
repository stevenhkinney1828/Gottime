import SwiftUI
import GotTimeCore

/// Private invite/pairing-code mechanism (spec section 5) — no address book import, no
/// public directory or search anywhere in this screen.
struct AddConnectionView: View {
    @Environment(\.appEnvironment) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var createdInvite: ConnectionInvite?
    @State private var isCreatingInvite = false
    @State private var redeemCode = ""
    @State private var isRedeeming = false
    @State private var redeemError: String?

    var body: some View {
        Form {
            Section {
                Text("Invite someone you know. Codes are just for finding each other — never a public search.")
                    .font(.footnote)
                    .foregroundStyle(Color.gtTextSecondary)
            }
            .listRowBackground(Color.clear)

            Section("Share a code") {
                if let createdInvite {
                    HStack {
                        Text(createdInvite.inviteCode)
                            .font(.title2.monospaced().bold())
                        Spacer()
                    }
                } else {
                    Button {
                        Task { await createInvite() }
                    } label: {
                        if isCreatingInvite {
                            ProgressView()
                        } else {
                            Text("Create an invite code")
                        }
                    }
                }
            }

            Section("Have a code?") {
                TextField("Enter code", text: $redeemCode)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                Button {
                    Task { await redeem() }
                } label: {
                    if isRedeeming {
                        ProgressView()
                    } else {
                        Text("Connect")
                    }
                }
                .disabled(redeemCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isRedeeming)
                if let redeemError {
                    Text(redeemError)
                        .font(.footnote)
                        .foregroundStyle(Color.gtDestructive)
                }
            }
        }
        .navigationTitle("Add a Connection")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Close") { dismiss() }
            }
        }
    }

    private func createInvite() async {
        isCreatingInvite = true
        createdInvite = try? await environment.connectionService.createInvite()
        isCreatingInvite = false
    }

    private func redeem() async {
        isRedeeming = true
        redeemError = nil
        do {
            _ = try await environment.connectionService.redeemInvite(code: redeemCode)
            dismiss()
        } catch {
            redeemError = "That code didn't work — check it and try again."
        }
        isRedeeming = false
    }
}
