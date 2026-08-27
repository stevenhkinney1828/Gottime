import SwiftUI
import GotTimeCore

/// Owner's own request: a private label overriding what a connection's name shows as
/// everywhere in this app, since their self-reported name is entirely unrestricted and freely
/// editable by them at any time (see DECISIONS.md — a connection really could rename themselves
/// "Mom" as a prank). Presented from `PeopleListView` as a sheet. "Reset to their own name" only
/// appears once a nickname is actually set, since that's the only time there's anything to
/// revert — clearing the text field and saving does the same thing, for anyone who finds that
/// more natural than a separate button.
struct RenamePersonView: View {
    let person: ConnectedPerson
    let onSave: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var nicknameText: String

    init(person: ConnectedPerson, onSave: @escaping (String?) -> Void) {
        self.person = person
        self.onSave = onSave
        _nicknameText = State(initialValue: person.nickname ?? "")
    }

    private var canSave: Bool {
        !nicknameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || person.nickname != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $nicknameText)
                        .textContentType(.givenName)
                } footer: {
                    Text("This is just for you — \(person.profile.firstName ?? "they") won't see it, and it's separate from whatever they call themselves.")
                }

                if person.nickname != nil {
                    Section {
                        Button("Reset to their own name", role: .destructive) {
                            onSave(nil)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Rename \(person.profile.firstName ?? "Contact")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        let trimmed = nicknameText.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(trimmed.isEmpty ? nil : trimmed)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }
}
