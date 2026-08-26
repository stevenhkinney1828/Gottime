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

    @State private var selectedSeconds: Int?
    @State private var customMinutesText: String = ""
    @State private var customSecondsText: String = ""
    @State private var isCustomSelected = false
    @State private var validationMessage: String?

    /// `presetSeconds` (15s/30s/1min/3min) and `presetMinutes` (5/10/15/20/30 min) combined into
    /// one ordered, seconds-denominated list — the picker renders a single grid of chips rather
    /// than two separate rows, so both sets need to live in the same unit to sort together.
    private var allPresetsInSeconds: [Int] {
        (DurationPolicy.presetSeconds + DurationPolicy.presetMinutes.map { $0 * 60 }).sorted()
    }

    private var resolvedSeconds: Int? {
        if isCustomSelected {
            switch DurationPolicy.parseCustomDuration(minutesText: customMinutesText, secondsText: customSecondsText) {
            case .success(let seconds): return seconds
            case .failure: return nil
            }
        }
        return selectedSeconds
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
                isDisabled: resolvedSeconds == nil
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
        guard let seconds = resolvedSeconds else { return "Call" }
        let name = person.profile.firstName ?? "them"
        return "Call \(name) for \(DurationPolicy.formatDuration(seconds))"
    }

    private var presetGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 12) {
            ForEach(allPresetsInSeconds, id: \.self) { seconds in
                DurationChip(
                    label: chipLabel(seconds),
                    isSelected: !isCustomSelected && selectedSeconds == seconds
                ) {
                    isCustomSelected = false
                    selectedSeconds = seconds
                    validationMessage = nil
                }
            }
            DurationChip(label: "Custom", isSelected: isCustomSelected) {
                isCustomSelected = true
                selectedSeconds = nil
            }
        }
        .padding(.horizontal, 24)
    }

    private func chipLabel(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds) sec" : "\(seconds / 60) min"
    }

    /// Two separate fields (not one "MM:SS" text field) so numeric-keyboard entry stays simple
    /// on each side — per the owner's own request for truly arbitrary durations ("5 seconds,"
    /// "1 minute and 12 seconds," anything), not just the original whole-minutes-only entry.
    @ViewBuilder
    private var customEntry: some View {
        if isCustomSelected {
            HStack(spacing: 8) {
                TextField("0", text: $customMinutesText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .font(.title2)
                    .frame(width: 64)
                    .padding(8)
                    .background(Color.gtSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Text("min")
                    .foregroundStyle(Color.gtTextSecondary)
                TextField("0", text: $customSecondsText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .font(.title2)
                    .frame(width: 64)
                    .padding(8)
                    .background(Color.gtSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Text("sec")
                    .foregroundStyle(Color.gtTextSecondary)
            }
            .onChange(of: customMinutesText) { _, _ in validate() }
            .onChange(of: customSecondsText) { _, _ in validate() }
        }
    }

    private func validate() {
        if customMinutesText.isEmpty && customSecondsText.isEmpty {
            validationMessage = nil
            return
        }
        switch DurationPolicy.parseCustomDuration(minutesText: customMinutesText, secondsText: customSecondsText) {
        case .success:
            validationMessage = nil
        case .failure(.notWholeMinutes):
            validationMessage = "Enter whole numbers — seconds must be 0-59."
        case .failure(.outOfRange(let seconds)):
            validationMessage = seconds < DurationPolicy.minimumSeconds
                ? "Minimum is 15 seconds."
                : "Maximum is 60 minutes."
        case .failure(.tooShort), .failure(.tooLong):
            // parseCustomDuration only ever produces .notWholeMinutes/.outOfRange -- these two
            // belong to the older whole-minutes-only parseCustomMinutes path, kept for that
            // function's own callers/tests, not reachable from here.
            validationMessage = nil
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
        guard let seconds = resolvedSeconds else { return }
        onConfirm(seconds)
        dismiss()
    }
}
