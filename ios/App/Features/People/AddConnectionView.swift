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
            // Trimmed defensively — a keyboard-inserted leading/trailing space would make an
            // otherwise-correct code fail the server's exact-match lookup with no visual sign
            // anything was wrong, since the code is retyped by eye off another screen, not
            // pasted.
            let code = redeemCode.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try await environment.connectionService.redeemInvite(code: code)
            dismiss()
        } catch {
            // Surfaces the real reason (e.g. Postgres's own "Invalid invite code"/"Invite has
            // expired"/"Cannot redeem your own invite"/"Already connected" from
            // redeem_connection_invite(), since PostgrestError conforms to LocalizedError)
            // rather than a single generic message that can't be told apart from any other
            // failure — this exact class of real-device-only bug has repeatedly turned out to
            // need the actual error text to diagnose, not another guess (see DECISIONS.md).
            redeemError = "That code didn't work: \(error.localizedDescription)"
        }
        isRedeeming = false
    }
}
