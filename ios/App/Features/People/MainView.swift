import SwiftUI

/// Hosts the People list as the app's one primary screen (spec section 6), with History and
/// Settings reachable from the toolbar rather than as equal-weight tabs — this is a small
/// utility with one job, not a multi-section app.
struct MainView: View {
    @State private var showingHistory = false
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            PeopleListView()
                .navigationTitle("GotTime?")
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button {
                            showingHistory = true
                        } label: {
                            Image(systemName: "clock")
                        }
                        .accessibilityLabel("Call history")
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            showingSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Settings")
                    }
                }
        }
        .sheet(isPresented: $showingHistory) {
            NavigationStack { HistoryView() }
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack { SettingsView() }
        }
    }
}
