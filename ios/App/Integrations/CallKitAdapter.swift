import AVFoundation
import CallKit
import Foundation
import GotTimeCore
import TwilioVoice

/// Reports incoming calls to CallKit so they ring on the lock screen, show up correctly even
/// when this app isn't already open, and can be answered/declined via iOS's own native call UI
/// — the actual reason Phase 5 exists (`PushKitAdapter`'s own VoIP registration was pulled
/// forward into Phase 4 out of necessity; full lock-screen calling was deliberately deferred
/// until now — see DECISIONS.md). Explicit owner requirements this exists to satisfy: the lock
/// screen must show the requested duration, not just the caller's name; Answer/Decline must
/// work directly from the lock screen; the recipient must be able to see how much time is left
/// *during* the call, not just at ring time; and, when the caller provided one, what the call is
/// about.
///
/// Scoped to incoming calls only for this round — the caller's own outgoing-call side already
/// works correctly without CallKit (confirmed on real devices this session), and routing it
/// through CallKit too is a real, separate follow-up, not attempted here to avoid risking a
/// newly-confirmed-working path for a requirement nobody asked for yet.
///
/// Every integration detail below was checked against Twilio's own official quickstart source
/// before writing this, not assumed from memory: `reportNewIncomingCall` must be called
/// synchronously, before any async lookup (Apple can terminate an app that doesn't honor this);
/// pairing `AcceptOptions.uuid` (reintroduced in `TwilioVoiceAdapter.answer`, see its own
/// comment) with `provider(_:didActivate:)`/`didDeactivate:` toggling
/// `DefaultAudioDevice.isEnabled` is what actually activates real audio for a CallKit-managed
/// call — the SDK's own automatic activation (still relied on for outgoing calls, unchanged)
/// only applies when neither `ConnectOptions.uuid` nor `AcceptOptions.uuid` is set, which is
/// exactly why forcing it without a paired `CXProviderDelegate` silently broke all audio a few
/// builds ago (see DECISIONS.md).
///
/// **The live countdown is best-effort, not guaranteed** — real research (not guessed) turned up
/// multiple long-standing Apple Developer Forum reports that `CXProvider.reportCall(with:
/// updated:)` updates to `localizedCallerName` on an *already-active* call frequently fail to
/// visibly refresh on real hardware, spanning iOS 17 through 18 with no confirmed fix as of this
/// writing. This still updates once per second while connected (built because the owner
/// explicitly asked for a ticking countdown the recipient can see), but the real-device test
/// this build needs must specifically check whether it actually ticks or sits frozen at its
/// first value — if the latter, the in-app countdown (which has no such issue) remains the
/// reliable fallback once the phone is unlocked. See DECISIONS.md.
public final class CallKitAdapter: NSObject {
    private let voiceAdapter: TwilioVoiceAdapter
    private let provider: CXProvider

    private let lock = NSLock()

    /// Every callKitUUID `reportNewIncomingCall` has been given that hasn't been reported ended
    /// yet — the source of truth for whether `endReportedCall` still needs to actually tell
    /// CallKit anything (it's given a callKitUUID immediately, before any of the rest of this
    /// call's info is known, so this can't just be inferred from `trackedCalls` below).
    private var reportedCallKitUUIDs: Set<UUID> = []

    private struct TrackedCall {
        let appCallUUID: UUID
        let callerName: String
        let topic: String?
        let requestedDurationSeconds: Int
    }
    /// Caller/topic/duration info, filled in once the async caller/session lookup completes —
    /// keyed by callKitUUID, the id CallKit itself tracks this call under (`CallInvite.uuid`).
    /// This app's own `call_uuid` plays no part in this key, deliberately: `TwilioVoiceAdapter`
    /// no longer depends on Twilio's own uuid fields for anything (see its own comments), so
    /// this is the one place the two uuid spaces need to be bridged at all.
    private var trackedCalls: [UUID: TrackedCall] = [:]
    /// The reverse of the key above (appCallUUID -> callKitUUID) — `VoiceEvent`s carry this
    /// app's own `callUUID`, never CallKit's, so reacting to one needs this direction too.
    private var appToCallKitUUID: [UUID: UUID] = [:]
    /// The running per-second ticking task for a connected call, keyed by callKitUUID.
    private var countdownTasks: [UUID: Task<Void, Never>] = [:]

    public init(voiceAdapter: TwilioVoiceAdapter) {
        self.voiceAdapter = voiceAdapter
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.maximumCallsPerCallGroup = 1
        configuration.maximumCallGroups = 1
        configuration.supportedHandleTypes = [.generic]
        self.provider = CXProvider(configuration: configuration)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    /// Called by `PushKitAdapter.callInviteReceived` immediately, before any async work —
    /// CallKit requires this within (effectively) the same runloop turn a VoIP push is
    /// received, or iOS can terminate the app for violating the contract. The caller's real name
    /// and the session's requested duration/topic aren't known yet (they need a database
    /// lookup); reported as a plain placeholder here, corrected moments later via
    /// `updateReportedCall`.
    public func reportIncomingCall(_ callInvite: CallInvite) {
        lock.lock()
        reportedCallKitUUIDs.insert(callInvite.uuid)
        lock.unlock()

        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: callInvite.from ?? "unknown")
        update.localizedCallerName = "Incoming call"
        update.hasVideo = false
        update.supportsDTMF = false
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        provider.reportNewIncomingCall(with: callInvite.uuid, update: update) { _ in }
    }

    /// Corrects the placeholder once the caller's real name, the session's requested duration,
    /// and its optional topic are known, and records this app's own `callUUID` so the
    /// `CXProviderDelegate` actions below can call into `TwilioVoiceAdapter` correctly. CallKit
    /// has no reliable separate subtitle field shown before the phone unlocks, so all three are
    /// composed into one `localizedCallerName` — e.g. "Thunder • 10 min • Dinner tonight" — per
    /// the owner's own explicit requests (see DECISIONS.md).
    public func updateReportedCall(callKitUUID: UUID, appCallUUID: UUID, callerName: String, requestedDurationSeconds: Int, topic: String?) {
        lock.lock()
        trackedCalls[callKitUUID] = TrackedCall(
            appCallUUID: appCallUUID,
            callerName: callerName,
            topic: topic,
            requestedDurationSeconds: requestedDurationSeconds
        )
        appToCallKitUUID[appCallUUID] = callKitUUID
        lock.unlock()

        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: callerName)
        update.localizedCallerName = Self.composeRingingLabel(callerName: callerName, requestedDurationSeconds: requestedDurationSeconds, topic: topic)
        update.hasVideo = false
        provider.reportCall(with: callKitUUID, updated: update)
    }

    /// The async caller/session lookup failed (see `PushKitAdapter`'s own `context_fetch_failed`
    /// diagnostic), the caller gave up before this device answered, or the real call ended (for
    /// any reason — see `handle(_:)` below) — ends the already-reported call rather than leaving
    /// a lock-screen call ringing (or displayed as connected) forever. A no-op if this
    /// callKitUUID was never reported or was already ended, so a second, redundant call from a
    /// different code path (e.g. this app's own `CXEndCallAction` handler having already cleared
    /// tracking, followed moments later by the resulting `VoiceEvent`) can't double-report to
    /// CallKit.
    public func endReportedCall(callKitUUID: UUID, reason: CXCallEndedReason) {
        lock.lock()
        let wasReported = reportedCallKitUUIDs.contains(callKitUUID)
        clearTracking(callKitUUID: callKitUUID)
        lock.unlock()
        guard wasReported else { return }
        provider.reportCall(with: callKitUUID, endedAt: Date(), reason: reason)
    }

    /// Reacts to the same events `CallCoordinator` reacts to, delivered directly (not via
    /// `events`, see `TwilioVoiceAdapter.onVoiceEvent`'s own comment) — starts the lock-screen
    /// countdown the moment a call actually connects, and ends the CallKit-reported call the
    /// moment the real call ends for *any* reason (the owner's own explicit Cancel/End, this
    /// device's own new `scheduleAutoExpiry` timeout, or the other participant hanging up) —
    /// closing a real gap that predates this build: nothing previously told CallKit when a call
    /// ended for a reason CallKit didn't itself initiate via `CXEndCallAction`, which would have
    /// left its native call screen displayed (and, once the ticking countdown existed, frozen)
    /// after the real call was already over.
    public func handle(_ event: VoiceEvent) {
        switch event {
        case .incomingCall:
            break
        case .statusChanged(let session):
            guard session.status == .connected, let connectedAt = session.connectedAt else { return }
            startCountdown(appCallUUID: session.callUUID, connectedAt: connectedAt)
        case .callEnded(let callUUID):
            lock.lock()
            let callKitUUID = appToCallKitUUID[callUUID]
            lock.unlock()
            guard let callKitUUID else { return }
            endReportedCall(callKitUUID: callKitUUID, reason: .remoteEnded)
        }
    }

    /// Clears all bookkeeping for one call without itself telling CallKit anything — used both
    /// by `endReportedCall` (which does also report to CallKit) and by the native
    /// `CXEndCallAction` handler (which never needs to, since CallKit already knows: it's the
    /// one that asked). Must be called with `lock` held.
    private func clearTracking(callKitUUID: UUID) {
        reportedCallKitUUIDs.remove(callKitUUID)
        if let info = trackedCalls.removeValue(forKey: callKitUUID) {
            appToCallKitUUID.removeValue(forKey: info.appCallUUID)
        }
        countdownTasks.removeValue(forKey: callKitUUID)?.cancel()
    }

    /// One update per second while connected — see this type's own top-level comment for the
    /// real, documented Apple-side uncertainty about whether this actually renders live on
    /// every iOS version. Guarded to start at most once per call (a later `connectedAt`
    /// correction from `TwilioVoiceAdapter.reconcileConnectedAt` re-emits `.statusChanged` with
    /// the same `.connected` status, which must not restart this from a second anchor — staying
    /// on the first, locally-observed `connectedAt` keeps this countdown consistent with
    /// `TwilioVoiceAdapter.scheduleAutoExpiry`'s own real hangup timer, which uses the same
    /// anchor for the same reason).
    private func startCountdown(appCallUUID: UUID, connectedAt: Date) {
        lock.lock()
        guard
            let callKitUUID = appToCallKitUUID[appCallUUID],
            let info = trackedCalls[callKitUUID],
            countdownTasks[callKitUUID] == nil
        else {
            lock.unlock()
            return
        }
        let task = Task { [weak self, provider] in
            let timer = CallTimer(connectedAt: connectedAt, requestedDurationSeconds: info.requestedDurationSeconds)
            while !Task.isCancelled {
                let remaining = timer.remainingSeconds(at: .now)
                let update = CXCallUpdate()
                update.remoteHandle = CXHandle(type: .generic, value: info.callerName)
                update.localizedCallerName = Self.composeConnectedLabel(callerName: info.callerName, remainingSeconds: remaining, topic: info.topic)
                update.hasVideo = false
                provider.reportCall(with: callKitUUID, updated: update)
                guard self != nil, remaining > 0 else { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        countdownTasks[callKitUUID] = task
        lock.unlock()
    }

    private static func composeRingingLabel(callerName: String, requestedDurationSeconds: Int, topic: String?) -> String {
        var label = "\(callerName) \u{2022} \(DurationPolicy.formatDuration(requestedDurationSeconds))"
        if let topic, !topic.isEmpty {
            label += " \u{2022} \(topic)"
        }
        return label
    }

    private static func composeConnectedLabel(callerName: String, remainingSeconds: Int, topic: String?) -> String {
        let minutes = remainingSeconds / 60
        let seconds = remainingSeconds % 60
        var label = "\(callerName) \u{2022} \(String(format: "%d:%02d", minutes, seconds)) left"
        if let topic, !topic.isEmpty {
            label += " \u{2022} \(topic)"
        }
        return label
    }
}

extension CallKitAdapter: CXProviderDelegate {
    public func providerDidReset(_ provider: CXProvider) {
        if let audioDevice = TwilioVoiceSDK.audioDevice as? DefaultAudioDevice {
            audioDevice.isEnabled = false
        }
    }

    public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        lock.lock()
        let appCallUUID = trackedCalls[action.callUUID]?.appCallUUID
        lock.unlock()
        guard let appCallUUID else {
            // The async lookup hasn't completed yet (or failed) -- extremely unlikely in
            // practice, since a human tapping Answer is far slower than the network round-trip
            // this depends on, but fail the action honestly rather than pretending to answer a
            // call this app can't actually route yet.
            action.fail()
            return
        }
        Task { [voiceAdapter] in
            do {
                try await voiceAdapter.answer(callUUID: appCallUUID)
                action.fulfill()
            } catch {
                action.fail()
            }
        }
    }

    public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        lock.lock()
        let appCallUUID = trackedCalls[action.callUUID]?.appCallUUID
        clearTracking(callKitUUID: action.callUUID)
        lock.unlock()
        guard let appCallUUID else {
            action.fulfill()
            return
        }
        Task { [voiceAdapter] in
            // The same CXEndCallAction covers both "decline before answering" and "hang up an
            // already-connected call" -- TwilioVoiceAdapter's own tracked state (pendingInvite
            // vs. activeCall) already knows which is actually valid, so try decline first and
            // fall back to endEarly rather than this adapter needing to duplicate that tracking.
            // decline()'s own pendingInviteMatching check is the only thing that runs before it
            // would throw, so falling through on failure has no side effects to worry about.
            if (try? await voiceAdapter.decline(callUUID: appCallUUID)) != nil {
                action.fulfill()
                return
            }
            try? await voiceAdapter.endEarly(callUUID: appCallUUID)
            action.fulfill()
        }
    }

    public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        if let audioDevice = TwilioVoiceSDK.audioDevice as? DefaultAudioDevice {
            audioDevice.isEnabled = true
        }
    }

    public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        if let audioDevice = TwilioVoiceSDK.audioDevice as? DefaultAudioDevice {
            audioDevice.isEnabled = false
        }
    }
}
