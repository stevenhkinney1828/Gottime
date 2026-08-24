import SwiftUI

/// TEMPORARY diagnostic screen, shown instead of crashing when Release config is missing —
/// see SupabaseClientFactory.diagnoseConfig() and DECISIONS.md. Remove both once the real
/// cause of the launch crash is confirmed and fixed.
struct ConfigDiagnosticView: View {
    let details: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Configuration Problem")
                    .font(.title2.bold())
                Text("GotTime? couldn't find its Supabase configuration. This is a debugging screen, not a bug in your account — press and hold the text below to copy it, then send it back.")
                    .foregroundStyle(.secondary)
                Text(details)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.gray.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding()
        }
    }
}

#Preview {
    ConfigDiagnosticView(details: "GTSupabaseProjectRef: MISSING\nGTSupabaseAnonKey: MISSING")
}
