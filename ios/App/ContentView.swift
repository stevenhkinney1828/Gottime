import SwiftUI

/// Placeholder root view for Phase 0. Replaced in Phase 1 by the real People list — see
/// BUILD_STATUS.md. Exists so the App target has something to compile and launch against,
/// proving the project/package wiring works before any feature code is written.
struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("GotTime?")
                .font(.largeTitle.bold())
            Text("Foundation phase — screens land in Phase 1.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
