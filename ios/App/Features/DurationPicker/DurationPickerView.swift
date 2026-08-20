import SwiftUI
import GotTimeCore

/// "How long do you have?" (spec section 6). Selecting a duration alone must never start a
/// call — only the explicit "Call X for N minutes" button does, and it's the only path that
/// calls CallCoordinator.call(_:durationSeconds:).
struct DurationPickerView: View {
    let person: ConnectedPerson
    /// Reports the confirmed duration up to whichever view presents this sheet, rather than
    /// starting the call directly from here — see the doc comment on `confirmCall()` for why.
    let onConfirm: (Int) -> Void

    @Environment(\.appEnvironment) private var environment
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

    /// Reports the confirmed duration via `onConfirm`, then dismisses — deliberately *not*
    /// calling `CallCoordinator.call()` directly from here. `MockVoiceService.startCall` has no
    /// real `await` suspension point in its body, so `Task { await coordinator.call(...) }` can
    /// run to completion on the very next run-loop turn — often before this sheet's own dismiss
    /// animation has actually finished, not just been requested. That raced the sheet's dismiss
    /// transition against the active-call screen's present transition and was the actual cause
    /// of GotTimeUITests' canonical flow test failing (see DECISIONS.md) — not any particular
    /// choice of presentation API, which is why switching between `.fullScreenCover(item:)`
    /// variants never fixed it. `onConfirm` only records the pending call; the presenting view
    /// (`PeopleListView`) is what actually starts it, from the sheet's `onDismiss` callback,
    /// which SwiftUI guarantees fires only once the dismissal has genuinely completed.
    private func confirmCall() {
        guard let minutes = resolvedMinutes else { return }
        onConfirm(DurationPolicy.seconds(forMinutes: minutes))
        dismiss()
    }
}
