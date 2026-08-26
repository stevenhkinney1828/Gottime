import SwiftUI
import GotTimeCore

/// The main screen (spec section 6): a simple list of connected people. Exactly one
/// connection gets a more prominent single-person layout instead of a one-row list — "make
/// calling that person especially fast."
struct PeopleListView: View {
    @Environment(\.appEnvironment) private var environment
    @Environment(CallCoordinator.self) private var coordinator
    @State private var people: [ConnectedPerson] = []
    @State private var isLoading = true
    @State private var selectedPerson: ConnectedPerson?
    @State private var showingAddConnection = false
    /// Set by DurationPickerView's onConfirm, consumed by the sheet's onDismiss — see the doc
    /// comment on DurationPickerView.confirmCall() for why the call starts here, only once the
    /// sheet has actually finished dismissing, rather than from inside the sheet itself.
    @State private var pendingCall: PendingCall?

    private struct PendingCall {
        let person: ConnectedPerson
        let durationSeconds: Int
        let topic: String?
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if people.isEmpty {
                emptyState
            } else if people.count == 1, let onlyPerson = people.first {
                singlePersonLayout(onlyPerson)
            } else {
                list
            }
        }
        .background(Color.gtBackground)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingAddConnection = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add a connection")
            }
        }
        .sheet(item: $selectedPerson, onDismiss: {
            guard let pendingCall else { return }
            self.pendingCall = nil
            Task {
                await coordinator.call(pendingCall.person, durationSeconds: pendingCall.durationSeconds, topic: pendingCall.topic)
            }
        }) { person in
            NavigationStack {
                DurationPickerView(person: person) { durationSeconds, topic in
                    pendingCall = PendingCall(person: person, durationSeconds: durationSeconds, topic: topic)
                }
            }
        }
        .sheet(isPresented: $showingAddConnection, onDismiss: {
            // Without this, a successful connection left the list showing whatever it had
            // before AddConnectionView ever appeared — .task only runs once on first
            // appearance, .refreshable only on a manual pull. A real connection could succeed
            // server-side (dismiss() only fires on success) with nothing on screen ever
            // reflecting it, making a second attempt look like the exact same failure again,
            // now correctly (if confusingly) rejected server-side as "Already connected."
            // Re-fetching unconditionally here — whether the sheet closed via a successful
            // connect or just Close — is simpler and just as correct as trying to track which.
            Task { await loadConnections() }
        }) {
            NavigationStack { AddConnectionView() }
        }
        .task { await loadConnections() }
        .refreshable { await loadConnections() }
    }

    private var list: some View {
        List(people) { person in
            Button {
                selectedPerson = person
            } label: {
                PersonRow(person: person)
            }
            .listRowBackground(Color.gtSurface)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func singlePersonLayout(_ person: ConnectedPerson) -> some View {
        VStack(spacing: 24) {
            Spacer()
            Circle()
                .fill(Color.gtAccent.opacity(0.15))
                .frame(width: 96, height: 96)
                .overlay(
                    Text((person.profile.firstName?.first).map(String.init)?.uppercased() ?? "?")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(Color.gtAccent)
                )
            Text(person.profile.firstName ?? "Unknown")
                .font(.title.bold())
                .foregroundStyle(Color.gtTextPrimary)
            PrimaryButton(title: "Call \(person.profile.firstName ?? "them")") {
                selectedPerson = person
            }
            .padding(.horizontal, 48)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            EmptyState(
                symbol: "person.badge.plus",
                title: "No one connected yet",
                message: "Add a friend or family member to start a timed call."
            )
            PrimaryButton(title: "Add a connection") {
                showingAddConnection = true
            }
            .padding(.horizontal, 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadConnections() async {
        isLoading = people.isEmpty
        people = (try? await environment.connectionService.fetchConnections()) ?? []
        isLoading = false
    }
}
