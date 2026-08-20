import SwiftUI
import GotTimeCore

/// The main screen (spec section 6): a simple list of connected people. Exactly one
/// connection gets a more prominent single-person layout instead of a one-row list — "make
/// calling that person especially fast."
struct PeopleListView: View {
    @Environment(\.appEnvironment) private var environment
    @State private var people: [ConnectedPerson] = []
    @State private var isLoading = true
    @State private var selectedPerson: ConnectedPerson?
    @State private var showingAddConnection = false

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
        .sheet(item: $selectedPerson) { person in
            NavigationStack {
                DurationPickerView(person: person)
            }
        }
        .sheet(isPresented: $showingAddConnection) {
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
