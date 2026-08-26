import AVFoundation
import CallKit
import Foundation
import GotTimeCore
import TwilioVoice

/// Reports incoming calls to CallKit so they ring on the lock screen, show up correctly even
/// when this app isn't already open, and can be answered/declined via iOS's own native call UI
/// — the actual reason Phase 5 exists (`PushKitAdapter`'s own VoIP registration was pulled
/// forward into Phase 4 out of necessity; full lock-screen calling was deliberately deferred
/// until now — see DECISIONS.md). Two explicit owner requirements this exists to satisfy: the
/// lock screen must show the requested duration, not just the caller's name, and Answer/Decline
/// must work directly from the lock screen.
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
public final class CallKitAdapter: NSObject {
    private let voiceAdapter: TwilioVoiceAdapter
    private let provider: CXProvider

    private let lock = NSLock()
    /// Keyed by the uuid CallKit itself tracks each call under (`CallInvite.uuid`) -- this app's
    /// own `call_uuid` plays no part in this mapping, deliberately: `TwilioVoiceAdapter` no
    /// longer depends on Twilio's own uuid fields for anything (see its own comments), so this
    /// is the one place the two uuid spaces need to be bridged at all. Filled in once the async
    /// caller/session lookup completes; `answer`/`decline` need this app's own `callUUID` to
    /// call into `TwilioVoiceAdapter` correctly.
    private var pendingAppCallUUIDs: [UUID: UUID] = [:]

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
    /// and the session's requested duration aren't known yet (they need a database lookup);
    /// reported as a plain placeholder here, corrected moments later via `updateReportedCall`.
    public func reportIncomingCall(_ callInvite: CallInvite) {
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

    /// Corrects the placeholder once the caller's real name and the session's requested
    /// duration are known, and records this app's own `callUUID` so the CXProviderDelegate
    /// actions below can call into `TwilioVoiceAdapter` correctly. CallKit has no reliable
    /// separate subtitle field shown before the phone unlocks, so both are composed into one
    /// `localizedCallerName` — e.g. "Thunder • 10 min" — matching this project's own original
    /// design decision (see DECISIONS.md).
    public func updateReportedCall(callKitUUID: UUID, appCallUUID: UUID, callerName: String, requestedDurationSeconds: Int) {
        lock.lock()
        pendingAppCallUUIDs[callKitUUID] = appCallUUID
        lock.unlock()

        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: callerName)
        update.localizedCallerName = "\(callerName) \u{2022} \(DurationPolicy.formatDuration(requestedDurationSeconds))"
        update.hasVideo = false
        provider.reportCall(with: callKitUUID, updated: update)
    }

    /// The async caller/session lookup failed (see `PushKitAdapter`'s own `context_fetch_failed`
    /// diagnostic) or the caller gave up before this device answered — ends the already-reported
    /// call rather than leaving a lock-screen call ringing forever.
    public func endReportedCall(callKitUUID: UUID, reason: CXCallEndedReason) {
        lock.lock()
        pendingAppCallUUIDs[callKitUUID] = nil
        lock.unlock()
        provider.reportCall(with: callKitUUID, endedAt: Date(), reason: reason)
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
        let appCallUUID = pendingAppCallUUIDs[action.callUUID]
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
        let appCallUUID = pendingAppCallUUIDs[action.callUUID]
        pendingAppCallUUIDs[action.callUUID] = nil
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
