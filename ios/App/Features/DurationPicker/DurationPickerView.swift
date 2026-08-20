import SwiftUI
import GotTimeCore

/// "How long do you have?" (spec section 6). Selecting a duration alone must never start a
/// call — only the explicit "Call X for N minutes" button does, and it's the only path that
/// calls CallCoordinator.call(_:durationSeconds:).
struct DurationPickerView: View {
    let person: ConnectedPerson

    @Environment(\.appEnvironment) private var environment
    @Environment(CallCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    @State private var selectedMinutes: Int?
    @State private var customText: String = ""
    @State private var isCustomSelected = false
    @State private var validationMessage: String?

    private var resolvedMinutes: Int? {
        if isCustomSelected {
            switch DurationPolicy.parseCustomMinutes(customText) {
            case .success(let seconds): return seconds / 60
            case .failure: return nil
            }
        }
        return selectedMinutes
    }

    var body: some View {
        VStack(spacing: 32) {
            VStack(spacing: 4) {
                Text("How long do you have?")
                    .font(.title2.bold())
                    .foregroundStyle(Color.gtTextPrimary)
                Text("for \(person.profile.firstName ?? "them")")
                    .font(.subheadline)
                    .foregroundStyle(Color.gtTextSecondary)
            }
            .padding(.top, 24)

            presetGrid

            customEntry

            if let validationMessage {
                Text(validationMessage)
                    .font(.footnote)
                    .foregroundStyle(Color.gtDestructive)
            }

            Spacer()

            PrimaryButton(
                title: confirmTitle,
                isDisabled: resolvedMinutes == nil
            ) {
                confirmCall()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .background(Color.gtBackground)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Cancel") { dismiss() }
            }
        }
    }

    private var confirmTitle: String {
        guard let minutes = resolvedMinutes else { return "Call" }
        let name = person.profile.firstName ?? "them"
        return "Call \(name) for \(minutes) minute\(minutes == 1 ? "" : "s")"
    }

    private var presetGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 12) {
            ForEach(DurationPolicy.presetMinutes, id: \.self) { minutes in
                DurationChip(
                    label: "\(minutes) min",
                    isSelected: !isCustomSelected && selectedMinutes == minutes
                ) {
                    isCustomSelected = false
                    selectedMinutes = minutes
                    validationMessage = nil
                }
            }
            DurationChip(label: "Custom", isSelected: isCustomSelected) {
                isCustomSelected = true
                selectedMinutes = nil
            }
        }
        .padding(.horizontal, 24)
    }

    @ViewBuilder
    private var customEntry: some View {
        if isCustomSelected {
            HStack {
                TextField("1-60", text: $customText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .font(.title2)
                    .frame(width: 80)
                    .padding(8)
                    .background(Color.gtSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Text("minutes")
                    .foregroundStyle(Color.gtTextSecondary)
            }
            .onChange(of: customText) { _, newValue in
                validate(newValue)
            }
        }
    }

    private func validate(_ text: String) {
        if text.isEmpty {
            validationMessage = nil
            return
        }
        switch DurationPolicy.parseCustomMinutes(text) {
        case .success:
            validationMessage = nil
        case .failure(.notWholeMinutes):
            validationMessage = "Enter a whole number of minutes."
        case .failure(.tooShort):
            validationMessage = "Minimum is 1 minute."
        case .failure(.tooLong):
            validationMessage = "Maximum is 60 minutes."
        }
    }

    /// Dismisses immediately, then starts the call in the background — deliberately in that
    /// order, not the reverse. Awaiting the call first and dismissing after would mean the
    /// sheet's dismiss-animation and ContentView's active-call fullScreenCover-present could
    /// both kick off at nearly the same instant; dismissing first gives one clean sequential
    /// transition (sheet fully closes, then the call screen appears) instead of two
    /// overlapping ones.
    private func confirmCall() {
        guard let minutes = resolvedMinutes else { return }
        dismiss()
        Task {
            await coordinator.call(person, durationSeconds: DurationPolicy.seconds(forMinutes: minutes))
        }
    }
}
