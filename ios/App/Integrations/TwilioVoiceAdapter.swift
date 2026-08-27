import AVFoundation
import Foundation
import GotTimeCore
import Supabase
import TwilioVoice

enum TwilioVoiceAdapterError: Error {
    case notSignedIn
    case noActiveCall
    case noPendingInvite
}

/// Real Twilio Voice SDK + Supabase-backed `VoiceService`. `startCall` authorizes and creates
/// the `call_sessions` row server-side first (via `request-call`, which validates duration and
/// the caller/recipient connection — this adapter never trusts its own inputs for that, per
/// spec section 13), then mints a fresh Access Token (`issue-voice-token`) and connects through
/// Twilio, embedding the session id as the outgoing call's `callSessionId` param — the same id
/// `twiml-voice` reads server-side to route the call and correlate its status callbacks.
///
/// Handles the caller's own side of a call completely on its own. The recipient's side
/// (`answer`/`decline`) operates on `pendingInvite`, populated by `handleIncomingCallInvite(_:)`
/// — fed real invites by `PushKitAdapter` (see that type), which also calls
/// `registerDeviceToken(_:)` below once it has a real VoIP push token. Registration turned out
/// to be a hard requirement discovered only by testing a real call between two real devices:
/// every attempt reached Twilio correctly but ended in "no-answer," since neither side had ever
/// told Twilio how to reach it — see DECISIONS.md.
public final class TwilioVoiceAdapter: NSObject, VoiceService, @unchecked Sendable {
    private let client: SupabaseClient
    public let events: AsyncStream<VoiceEvent>
    private let continuation: AsyncStream<VoiceEvent>.Continuation

    private let lock = NSLock()
    private var activeCall: Call?
    private var activeSession: CallSession?
    private var pendingInvite: CallInvite?
    private var pendingSession: CallSession?
    /// Set immediately by `cancel`/`endEarly` before disconnecting, so `callDidDisconnect` (which
    /// only ever sees a generic "the call ended," with no way to tell *why* on its own) knows
    /// this exact disconnect was a local, deliberate action rather than something to guess
    /// about. See `callDidDisconnect`'s own comment.
    private var pendingLocalOutcome: CallStatus?

    /// A direct, synchronous mirror of every event this adapter also yields via `events` —
    /// `CallKitAdapter` needs its own copy (to start/stop its lock-screen countdown and end a
    /// CallKit-reported call the moment the real call ends), but `AsyncStream` only delivers
    /// each event to whichever single consumer happens to be awaiting `next()`, not to every
    /// interested party — a second `for await` loop over the same `events` stream would
    /// silently steal events from `CallCoordinator`'s own consumption rather than both sides
    /// reliably seeing every event. A closure sidesteps that: `AppEnvironment.live()` wires this
    /// to `CallKitAdapter.handle(_:)` once both are constructed. See `emit(_:)`.
    public var onVoiceEvent: ((VoiceEvent) -> Void)?

    public init(client: SupabaseClient) {
        self.client = client
        let (stream, continuation) = AsyncStream<VoiceEvent>.makeStream()
        self.events = stream
        self.continuation = continuation
        super.init()
        TwilioVoiceSDK.audioDevice = DefaultAudioDevice()
    }

    // MARK: - VoiceService

    @discardableResult
    public func startCall(to recipient: ConnectedPerson, durationSeconds: Int, topic: String? = nil) async throws -> CallSession {
        let createdSession = try await requestCallSession(recipientId: recipient.profile.id, durationSeconds: durationSeconds, topic: topic)
        // request-call now creates the row as "outgoing" directly (see DECISIONS.md), but this
        // applies the same transition locally regardless of the exact value the server returned
        // -- CallStateMachine.apply's own from->to check is what actually matters, and every
        // subsequent real event (callDidStartRinging/callDidConnect/callDidDisconnect below)
        // was silently no-op'ing via `try?` in applyAndEmit because activeSession never left
        // .created, which .ringing can't follow directly. Confirmed via a real device test that
        // reached "ringing" in Twilio's own logs (see DECISIONS.md) but never advanced past the
        // caller's own "Calling..." screen.
        let session = (try? CallStateMachine.apply(.outgoing, to: createdSession, at: .now)) ?? createdSession
        let token = try await issueVoiceAccessToken()

        let connectOptions = ConnectOptions(accessToken: token) { builder in
            builder.params = ["callSessionId": session.id.uuidString]
            // Deliberately NOT setting builder.uuid, unlike answer()'s AcceptOptions (which now
            // does set it again, paired with CallKitAdapter -- see that comment). Confirmed
            // directly from Twilio's own documentation (not guessed): setting ConnectOptions.uuid/
            // AcceptOptions.uuid tells the SDK "this app manages CallKit's own audio-session
            // activation" -- the SDK then never automatically enables the audio device unless
            // something else (a CXProviderDelegate) does. Outgoing calls don't go through
            // CallKit in this round (see CallKitAdapter's own top-level comment for why that's
            // scoped out deliberately, not an oversight), so leaving this nil keeps outgoing
            // calls on the SDK's own automatic audio activation, which already works correctly
            // — confirmed on real devices. Because `Call.uuid` is documented as genuinely
            // optional and has no reason to relate to this app's own call_uuid once not forced,
            // matching below doesn't read it at all regardless of which path a given call took
            // — see applyAndEmit/clearIfActive, and DECISIONS.md.
        }
        let call = TwilioVoiceSDK.connect(options: connectOptions, delegate: self)

        lock.lock()
        activeCall = call
        activeSession = session
        lock.unlock()

        return session
    }

    public func answer(callUUID: UUID) async throws {
        guard let invite = pendingInviteMatching(callUUID) else {
            throw TwilioVoiceAdapterError.noPendingInvite
        }
        // builder.uuid = invite.uuid IS set here, unlike startCall's ConnectOptions (still
        // deliberately unset -- outgoing calls stay on the SDK's own automatic audio
        // management, which already works correctly). Every real incoming call now goes through
        // CallKit (see CallKitAdapter), which reported this exact invite.uuid to
        // reportNewIncomingCall -- setting it here is what tells the SDK "audio activation is
        // externally managed," which CallKitAdapter's own provider(_:didActivate:)/
        // didDeactivate: now correctly provides. This doesn't reintroduce the earlier uuid-
        // matching bug (see DECISIONS.md): nothing in this file reads Call.uuid/CallInvite.uuid
        // for matching anymore (applyAndEmit uses object identity; pendingInviteMatching/
        // disconnectActiveCall use this app's own call_uuid) -- this uuid exists purely for
        // CallKit's benefit now.
        let acceptOptions = AcceptOptions(callInvite: invite) { builder in
            builder.uuid = invite.uuid
        }
        let call = invite.accept(options: acceptOptions, delegate: self)

        lock.lock()
        activeCall = call
        // Promote the invite's session into activeSession, pre-advanced through
        // outgoing -> ringing, before clearing it. Without this, activeSession stays nil on the
        // recipient's side for the whole call: applyAndEmit's own guard (`guard var session =
        // activeSession, ...`) silently no-ops callDidConnect below exactly the same way the
        // caller's own "Calling..." screen got stuck forever (see startCall's comment and
        // DECISIONS.md) -- the same root gap on both ends, just reached via different code
        // paths. callDidStartRinging is never expected to fire on an *accepted* invite's own
        // Call object the way it does for the caller's outgoing one, so ringing is pre-applied
        // here rather than waited for.
        if let session = pendingSession, session.callUUID == callUUID {
            let ringing = (try? CallStateMachine.apply(.outgoing, to: session, at: .now))
                .flatMap { try? CallStateMachine.apply(.ringing, to: $0, at: .now) }
            activeSession = ringing ?? session
        }
        pendingInvite = nil
        pendingSession = nil
        lock.unlock()

        try? await performCallAction(callUUID: callUUID, action: "answer")
    }

    public func decline(callUUID: UUID) async throws {
        guard let invite = pendingInviteMatching(callUUID) else {
            throw TwilioVoiceAdapterError.noPendingInvite
        }
        invite.reject()
        // performCallAction looks up its session via currentSession(matching:), which falls
        // back to pendingSession for exactly this case (see that method) -- so this must run
        // before pendingSession is cleared below, or call-action never even gets invoked (it
        // silently returns with nothing to report, the same "looks fine, does nothing" failure
        // mode this whole session's diagnostics were built to catch). See DECISIONS.md.
        try? await performCallAction(callUUID: callUUID, action: "decline")
        lock.lock()
        pendingInvite = nil
        pendingSession = nil
        lock.unlock()
    }

    public func cancel(callUUID: UUID) async throws {
        lock.lock()
        pendingLocalOutcome = .canceled
        lock.unlock()
        try disconnectActiveCall(matching: callUUID)
        try? await performCallAction(callUUID: callUUID, action: "cancel")
    }

    public func endEarly(callUUID: UUID) async throws {
        lock.lock()
        pendingLocalOutcome = .endedEarly
        lock.unlock()
        try disconnectActiveCall(matching: callUUID)
        try? await performCallAction(callUUID: callUUID, action: "end_early")
    }

    public func setMuted(_ muted: Bool) async throws {
        lock.lock()
        let call = activeCall
        lock.unlock()
        guard let call else { throw TwilioVoiceAdapterError.noActiveCall }
        call.isMuted = muted
    }

    /// Matches the SDK's own quickstart pattern: speaker routing goes through the audio
    /// device's `block`, not a direct property on `Call` — there is no simpler documented API
    /// for this.
    public func setSpeakerEnabled(_ enabled: Bool) async throws {
        guard let audioDevice = TwilioVoiceSDK.audioDevice as? DefaultAudioDevice else { return }
        audioDevice.block = {
            try? AVAudioSession.sharedInstance().overrideOutputAudioPort(enabled ? .speaker : .none)
        }
        audioDevice.block()
    }

    // MARK: - Incoming call plumbing (fed by PushKitAdapter)

    /// Called by `PushKitAdapter`'s `NotificationDelegate.callInviteReceived(callInvite:)` once
    /// a real VoIP push delivers one. Kept as a plain method (not a NotificationDelegate
    /// conformance on this type) so this adapter has no PushKit dependency of its own — it only
    /// needs to be handed a `CallInvite` however one arrives.
    public func handleIncomingCallInvite(_ callInvite: CallInvite, callerProfile: Profile, callerNickname: String?, session: CallSession) {
        lock.lock()
        pendingInvite = callInvite
        pendingSession = session
        lock.unlock()
        emit(.incomingCall(session: session, callerProfile: callerProfile, callerNickname: callerNickname))
    }

    /// Called by `PushKitAdapter`'s `NotificationDelegate.cancelledCallInviteReceived(...)` when
    /// the caller gives up before this invite is answered/declined. Takes a `callSid`, not a
    /// UUID — `CancelledCallInvite` doesn't expose the local call UUID directly, only the
    /// identifier from Twilio's own side, matching the SDK's own quickstart sample's matching
    /// strategy (compare against the still-held `CallInvite`'s own `callSid`, since that one
    /// does carry the local UUID). Clears local state so a stale invite can't be acted on
    /// later. Does not itself clear the UI's own incoming-call presentation —
    /// `CallCoordinator`'s `.callEnded` handling only reacts once `activeCall` is set, which an
    /// invite that's never answered doesn't reach — a known, narrow gap (spec section 16's
    /// edge-case list territory), not something fixable at this layer alone.
    /// Returns the matched invite's own `.uuid` (CallKit's uuid, distinct from the `callUUID`
    /// emitted below) so `PushKitAdapter` can also end the corresponding CallKit-reported call —
    /// otherwise a call the caller gave up on would keep ringing on the lock screen indefinitely.
    @discardableResult
    public func handleCancelledCallInvite(callSid: String) -> UUID? {
        lock.lock()
        let matched = pendingInvite?.callSid == callSid
        // Matched by callSid (Twilio's own call identifier, reliable and unrelated to .uuid).
        // Emits pendingSession?.callUUID below -- this app's own value, matching what
        // CallCoordinator's incomingCall.session.callUUID actually is -- not pendingInvite?.uuid
        // (as this did before the audio fix), which is no longer forced to relate to anything
        // CallCoordinator holds. callKitUUID (returned separately, for CallKit's own benefit) is
        // the one place that Twilio-facing value still matters.
        let appCallUUID = matched ? pendingSession?.callUUID : nil
        let callKitUUID = matched ? pendingInvite?.uuid : nil
        if matched {
            pendingInvite = nil
            pendingSession = nil
        }
        lock.unlock()
        if let appCallUUID {
            emit(.callEnded(callUUID: appCallUUID))
        }
        return callKitUUID
    }

    /// Every event this adapter reports goes through here — both to `events` (consumed by
    /// `CallCoordinator`) and, synchronously, to `onVoiceEvent` (consumed by `CallKitAdapter`).
    /// See `onVoiceEvent`'s own doc comment for why a second `AsyncStream` consumer isn't safe.
    private func emit(_ event: VoiceEvent) {
        continuation.yield(event)
        onVoiceEvent?(event)
    }

    /// Registers this device to actually *receive* calls — without this, Twilio has no route to
    /// notify a device of an incoming `<Dial><Client>`, confirmed directly from Twilio's own
    /// call logs after a real two-device test: the caller leg always succeeded, the callee leg
    /// always ended in "no-answer." Reuses the same `issue-voice-token` token-minting path
    /// `startCall` already uses for outgoing calls — the SDK's `register` call is keyed off the
    /// token's own encoded identity, not a separate parameter.
    public func registerDeviceToken(_ deviceToken: Data) async throws {
        let token = try await issueVoiceAccessToken()
        // Named distinctly from this class's own `continuation` property (the VoiceEvent
        // stream) purely for a future reader's clarity — Swift resolves this correctly either
        // way, since the closure parameter shadows it within this scope alone.
        try await withCheckedThrowingContinuation { (registrationContinuation: CheckedContinuation<Void, Error>) in
            TwilioVoiceSDK.register(accessToken: token, deviceToken: deviceToken) { error in
                if let error {
                    registrationContinuation.resume(throwing: error)
                } else {
                    registrationContinuation.resume()
                }
            }
        }
    }

    // MARK: - Backend calls

    private func requestCallSession(recipientId: UUID, durationSeconds: Int, topic: String?) async throws -> CallSession {
        struct RequestBody: Encodable {
            let recipientId: UUID
            let requestedDurationSeconds: Int
            let topic: String?
        }
        struct ResponseBody: Decodable {
            let session: CallSessionRow
        }
        let response: ResponseBody = try await client.functions.invoke(
            "request-call",
            options: FunctionInvokeOptions(
                body: RequestBody(recipientId: recipientId, requestedDurationSeconds: durationSeconds, topic: topic)
            ),
            decoder: Self.postgresTimestampDecoder
        )
        return response.session.session
    }

    /// `FunctionsClient`'s own default decoder is a plain `JSONDecoder()` — unlike
    /// `PostgrestClient`'s, it does *not* parse ISO 8601 date strings automatically, so a
    /// response containing `Date` fields (like `CallSessionRow`'s three timestamps) needs this
    /// passed explicitly or decoding throws. Handles Postgres's timestamptz output both with
    /// and without fractional seconds, matching what was actually observed from a live
    /// `request-call` response (`"...2026-08-21T02:03:47.681663+00:00"`) rather than assuming
    /// one specific format.
    private static let postgresTimestampDecoder: JSONDecoder = {
        let withFractionalSeconds = ISO8601DateFormatter()
        withFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let withoutFractionalSeconds = ISO8601DateFormatter()
        withoutFractionalSeconds.formatOptions = [.withInternetDateTime]

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { fieldDecoder in
            let container = try fieldDecoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = withFractionalSeconds.date(from: string) { return date }
            if let date = withoutFractionalSeconds.date(from: string) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(string)")
        }
        return decoder
    }()

    private func issueVoiceAccessToken() async throws -> String {
        struct TokenResponse: Decodable {
            let token: String
        }
        let response: TokenResponse = try await client.functions.invoke("issue-voice-token")
        return response.token
    }

    private func performCallAction(callUUID: UUID, action: String) async throws {
        guard let session = currentSession(matching: callUUID) else { return }
        struct ActionBody: Encodable {
            let callSessionId: UUID
            let action: String
        }
        try await client.functions.invoke(
            "call-action",
            options: FunctionInvokeOptions(body: ActionBody(callSessionId: session.id, action: action))
        )
    }

    // MARK: - Local state helpers

    /// Falls back to `pendingSession` so `decline` (which never sets `activeSession` — a
    /// declined call never becomes "active") can still resolve a session id for
    /// `performCallAction`. See `decline`'s own comment.
    private func currentSession(matching callUUID: UUID) -> CallSession? {
        lock.lock()
        defer { lock.unlock() }
        if activeSession?.callUUID == callUUID { return activeSession }
        if pendingSession?.callUUID == callUUID { return pendingSession }
        return nil
    }

    /// Matches against `pendingSession?.callUUID` (this app's own `call_uuid`) rather than
    /// `pendingInvite?.uuid` (Twilio's own SDK-local id) — confirmed via a real device test
    /// (build 16) that those two are genuinely different values, which made every `answer()`/
    /// `decline()` throw before `invite.accept()`/`.reject()` was ever reached. Comparing against
    /// our own app-level value instead, which `CallCoordinator` already threads through
    /// unchanged from the same `pendingSession` this method reads, makes this match correct by
    /// construction rather than by coincidence. See DECISIONS.md.
    private func pendingInviteMatching(_ callUUID: UUID) -> CallInvite? {
        lock.lock()
        let invite = pendingInvite
        let session = pendingSession
        lock.unlock()
        guard session?.callUUID == callUUID else {
            report(status: "invite_not_pending", detail: "requested=\(callUUID) pendingSessionCallUUID=\(session?.callUUID.uuidString ?? "nil")")
            return nil
        }
        report(status: "invite_matched", detail: "uuid=\(callUUID)")
        return invite
    }

    /// Matches against `activeSession?.callUUID` (this app's own value) rather than
    /// `activeCall?.uuid` (Twilio's own, now genuinely optional and no longer forced — see
    /// `startCall`'s comment) — same reasoning as `pendingInviteMatching` above.
    private func disconnectActiveCall(matching callUUID: UUID) throws {
        lock.lock()
        let call = activeCall
        let matches = activeSession?.callUUID == callUUID
        lock.unlock()
        guard let call, matches else {
            throw TwilioVoiceAdapterError.noActiveCall
        }
        call.disconnect()
    }

    /// Applies a `CallStateMachine` transition to the tracked session and emits the result —
    /// the single choke point every delegate callback below funnels through, so GotTimeCore's
    /// own transition rules (not ad hoc logic here) decide what's valid, exactly like
    /// `MockVoiceService.tryApply` does for the mocked path.
    ///
    /// Matches by object identity (`activeCall === call`), not by any UUID field on `call` —
    /// `Call.uuid`/`CallInvite.uuid` are documented as genuinely optional and, once no longer
    /// forced via ConnectOptions/AcceptOptions.uuid (see `startCall`'s comment, required to fix
    /// real audio), have no guaranteed value at all. Since this adapter only ever tracks one
    /// `activeCall` at a time by design, identity is a strictly more reliable check than a UUID
    /// that might not even be populated.
    private func applyAndEmit(_ status: CallStatus, for call: Call) {
        lock.lock()
        guard let activeCallRef = activeCall, activeCallRef === call else {
            lock.unlock()
            report(status: "no_active_session", detail: "attempted=\(status) (call is not the tracked activeCall)")
            return
        }
        guard let session = activeSession else {
            lock.unlock()
            report(status: "no_active_session", detail: "attempted=\(status) (activeCall set, activeSession nil)")
            return
        }
        guard let updated = try? CallStateMachine.apply(status, to: session, at: .now) else {
            lock.unlock()
            report(status: "invalid_transition", detail: "from=\(session.status) to=\(status)")
            return
        }
        activeSession = updated
        lock.unlock()
        report(status: "applied", detail: "to=\(status)")
        emit(.statusChanged(session: updated))
        if updated.status.isTerminal {
            emit(.callEnded(callUUID: updated.callUUID))
        }
        if status == .connected, let connectedAt = updated.connectedAt {
            Task { [weak self] in await self?.reconcileConnectedAt(callUUID: updated.callUUID) }
            scheduleAutoExpiry(callUUID: updated.callUUID, connectedAt: connectedAt, requestedDurationSeconds: updated.requestedDurationSeconds)
        }
    }

    /// The primary duration-enforcement layer (spec section 7: "the caller is responsible for
    /// disconnecting at zero" — see `CallTimer`'s own doc comment). Build 23's real two-device
    /// CallKit test found this had never actually been built for this adapter at all: the
    /// caller's own screen moved on to its post-call summary when the countdown reached zero,
    /// but the *recipient's* real phone call (answered via CallKit from a locked screen) kept
    /// running indefinitely. Confirmed by grep, not guessed — `.timedOut` was only ever produced
    /// by `MockVoiceService`'s `scheduleAutoExpiry`, which this mirrors exactly; nothing in this
    /// file ever called it. Twilio's own `<Dial timeLimit>` (`twiml-voice/logic.ts`) was assumed
    /// to be a working backstop, but the same real test proved it doesn't reliably end the call
    /// either — this is now the one enforcement layer actually verified to run, not a backstop.
    private func scheduleAutoExpiry(callUUID: UUID, connectedAt: Date, requestedDurationSeconds: Int) {
        let timer = CallTimer(connectedAt: connectedAt, requestedDurationSeconds: requestedDurationSeconds)
        let remaining = timer.remainingSeconds(at: .now)
        Task { [weak self] in
            guard let self else { return }
            if remaining > 0 {
                try? await Task.sleep(for: .seconds(remaining))
            }
            self.disconnectForTimeout(callUUID: callUUID)
        }
    }

    /// Applies both local transitions (`.timedOut` then `.completed`, mirroring
    /// `MockVoiceService`) *before* calling `call.disconnect()` — deliberately in this order, so
    /// that by the time Twilio's own `callDidDisconnect` delegate callback fires moments later,
    /// `activeSession` is already terminal and `CallStateMachine` correctly rejects
    /// `callDidDisconnect`'s own (now-irrelevant) guess at an outcome as an invalid transition
    /// from a terminal state, rather than the two racing to double-report this call's ending.
    private func disconnectForTimeout(callUUID: UUID) {
        lock.lock()
        let call = activeCall
        let matches = activeSession?.callUUID == callUUID
        lock.unlock()
        guard let call, matches else { return }
        applyAndEmit(.timedOut, for: call)
        applyAndEmit(.completed, for: call)
        call.disconnect()
    }

    /// The `connectedAt` stamped above is read from this device's own clock at the exact
    /// moment its own `callDidConnect` fired — close to, but not identical to, when the *other*
    /// participant's device reaches the same local milestone, since push delivery, invite
    /// parsing, database lookups, human reaction time, and SDK negotiation all happen on their
    /// side first (see PushKitAdapter/DECISIONS.md). Reported by the owner as a real,
    /// visible desync: the caller's countdown starts before the recipient's screen even shows
    /// theirs. Twilio's own "in-progress" status callback records one single, server-side
    /// `connected_at` (see twilio-status-callback/logic.ts — its "answered"/"in-progress"
    /// naming bug meant this had never actually been set, for any call, before this same build)
    /// that both devices can fetch and agree on. Retries for up to a minute since this fetch is
    /// racing an independent webhook delivery this device has no way to await directly — the
    /// first version of this retried for only 2 seconds total, which is far shorter than a
    /// realistic time-to-answer and left the desync just as visible as before whenever the
    /// recipient took longer than that to pick up (which is the normal case, not an edge case).
    /// A minute comfortably covers any realistic ring/answer window; if it never lands even
    /// then, the locally-stamped time stands rather than leaving the countdown stuck.
    private func reconcileConnectedAt(callUUID: UUID) async {
        struct Row: Decodable {
            let connectedAt: Date?
            enum CodingKeys: String, CodingKey { case connectedAt = "connected_at" }
        }
        guard let session = currentSession(matching: callUUID) else { return }
        for _ in 0..<60 {
            try? await Task.sleep(for: .seconds(1))
            guard
                let row: Row = try? await client.from("call_sessions")
                    .select("connected_at")
                    .eq("id", value: session.id)
                    .single()
                    .execute()
                    .value,
                let serverConnectedAt = row.connectedAt
            else { continue }

            lock.lock()
            guard var current = activeSession, current.callUUID == callUUID else {
                lock.unlock()
                return
            }
            current.connectedAt = serverConnectedAt
            activeSession = current
            lock.unlock()
            emit(.statusChanged(session: current))
            return
        }
    }

    /// Resolves the one outcome this device's own signal genuinely can't distinguish on its
    /// own: a clean disconnect before ever connecting, with no local action of this device's
    /// own to explain it (see `callDidDisconnect`'s own comment — that's already narrowed down
    /// to "recipient declined" or "recipient never answered in time"). `activeSession`/
    /// `activeCall` are already cleared by the time this runs (the call has genuinely ended),
    /// so this works from the `originalSession` snapshot handed to it rather than this
    /// adapter's own state, and emits a corrected `CallSession` built from that snapshot
    /// directly — `CallCoordinator` matches purely on the emitted session's own `callUUID`, not
    /// on anything this adapter still holds. A short window (5 attempts, 500ms apart): a
    /// decline is either recorded within a second or two of the disconnect (the recipient's own
    /// `call-action` call almost always lands right around the same time Twilio notifies the
    /// caller) or it never was a decline at all — unlike `reconcileConnectedAt`, there's no
    /// human "time to answer" to wait out here. If the server never shows `.declined`, the
    /// `.missed` already applied stands, which is the correct default for "didn't answer."
    private func reconcileFinalOutcome(originalSession: CallSession) async {
        struct Row: Decodable {
            let status: CallStatus
        }
        for _ in 0..<5 {
            try? await Task.sleep(for: .milliseconds(500))
            guard
                let row: Row = try? await client.from("call_sessions")
                    .select("status")
                    .eq("id", value: originalSession.id)
                    .single()
                    .execute()
                    .value,
                row.status == .declined
            else { continue }

            let corrected = CallSession(
                id: originalSession.id,
                callUUID: originalSession.callUUID,
                callerId: originalSession.callerId,
                recipientId: originalSession.recipientId,
                requestedDurationSeconds: originalSession.requestedDurationSeconds,
                topic: originalSession.topic,
                initiatedAt: originalSession.initiatedAt,
                ringingAt: originalSession.ringingAt,
                connectedAt: originalSession.connectedAt,
                endedAt: Date(),
                actualDurationSeconds: nil,
                providerCallSid: originalSession.providerCallSid,
                status: .declined,
                createdAt: originalSession.createdAt,
                updatedAt: Date()
            )
            emit(.statusChanged(session: corrected))
            return
        }
    }

    /// Diagnostic added after build 14's real retest: the caller's side genuinely worked for
    /// the first time (a real countdown ran), but the recipient's own screen still never left
    /// its spinner, even though the caller's success proves invite.accept() was reached and
    /// Twilio genuinely bridged the call. That means the remaining gap is specifically in how
    /// each device's own CallDelegate events get processed by `applyAndEmit` above afterward --
    /// distinguishing exactly which of its three failure modes (or success) fires, on both the
    /// caller's and recipient's own device, rather than guessing a fifth code change blind. See
    /// DECISIONS.md and migration 0009. Best-effort, same reasoning as the other reporters in
    /// this file: a failure here must never compound the failure it's diagnosing.
    private func report(status: String, detail: String?) {
        struct Update: Encodable {
            let lastCallEventStatus: String
            let lastCallEventDetail: String?
            let lastCallEventUpdatedAt: String

            enum CodingKeys: String, CodingKey {
                case lastCallEventStatus = "last_call_event_status"
                case lastCallEventDetail = "last_call_event_detail"
                case lastCallEventUpdatedAt = "last_call_event_updated_at"
            }
        }
        guard let userId = client.auth.currentSession?.user.id else { return }
        let update = Update(
            lastCallEventStatus: status,
            lastCallEventDetail: detail.map { String($0.prefix(500)) },
            lastCallEventUpdatedAt: ISO8601DateFormatter().string(from: Date())
        )
        Task { [client] in
            try? await client.from("profiles").update(update).eq("id", value: userId).execute()
        }
    }
}

// MARK: - CallDelegate

extension TwilioVoiceAdapter: CallDelegate {
    public func callDidStartRinging(call: Call) {
        applyAndEmit(.ringing, for: call)
    }

    public func callDidConnect(call: Call) {
        applyAndEmit(.connected, for: call)
    }

    public func callDidFailToConnect(call: Call, error: Error) {
        applyAndEmit(.failed, for: call)
        clearIfActive(call)
    }

    public func callDidDisconnect(call: Call, error: Error?) {
        lock.lock()
        let wasConnected = activeSession?.status == .connected
        let originalSession = activeSession
        let localOutcome = pendingLocalOutcome
        pendingLocalOutcome = nil
        lock.unlock()
        // A real Twilio-reported error is a failure; a clean disconnect from a connected call is
        // an early hangup. Distinguishing "hung up on schedule at zero" from an early hangup is
        // deliberately not attempted here — same reasoning as twilio-status-callback's own
        // "completed" no-op: that needs Phase 6's full duration-enforcement design, and
        // CallStateMachine simply rejects an invalid .endedEarly attempt on a session this
        // adapter itself already marked .timedOut via that mechanism, so nothing here can
        // incorrectly overwrite it.
        //
        // A clean disconnect that never connected is genuinely ambiguous from this device's own
        // signal alone: the caller's own SDK sees "the call ended," full stop, regardless of
        // whether the recipient explicitly declined or simply never answered in time —
        // previously both were mislabeled `.failed` (and even the caller's own explicit
        // cancel/endEarly action fell into this same generic bucket, showing "Call failed" for
        // what was actually a deliberate cancel). `pendingLocalOutcome`, set immediately by
        // `cancel`/`endEarly` before disconnecting, resolves the local-action case outright.
        // Otherwise this defaults to `.missed` and kicks off a brief server check for
        // `.declined` — set authoritatively by the *recipient's* own explicit decline action via
        // call-action, which this device has no other way to learn about. See
        // `reconcileFinalOutcome`'s own comment.
        // `.missed` is only a valid transition from `.ringing` (CallStateMachine); a clean
        // disconnect while still `.outgoing` (Twilio never got as far as ringing the recipient
        // at all) falls back to `.failed` instead, matching the original safe behavior for that
        // narrower case rather than risking an invalid-transition no-op for a label that isn't
        // really earned yet.
        let status: CallStatus
        if let localOutcome {
            status = localOutcome
        } else if error != nil {
            status = .failed
        } else if wasConnected {
            status = .endedEarly
        } else if originalSession?.status == .ringing {
            status = .missed
        } else {
            status = .failed
        }
        applyAndEmit(status, for: call)
        clearIfActive(call)
        // Only worth checking for a decline if this was actually applied as .missed above --
        // the recipient can't decline a call that never reached them in the first place.
        if status == .missed, let originalSession {
            Task { [weak self] in await self?.reconcileFinalOutcome(originalSession: originalSession) }
        }
    }

    public func callIsReconnecting(call: Call, error: Error) {}
    public func callDidReconnect(call: Call) {}

    /// Identity, not `.uuid` — see `applyAndEmit`'s own comment.
    private func clearIfActive(_ call: Call) {
        lock.lock()
        if activeCall === call {
            activeCall = nil
            activeSession = nil
        }
        lock.unlock()
    }
}

/// Mirrors `request-call`'s response shape exactly (only the fields it actually returns — the
/// remaining lifecycle timestamps are correctly absent from a freshly-created session and
/// default to nil via `CallSession`'s own initializer, matching how `request-call/logic.ts`
/// documents that same omission server-side).
private struct CallSessionRow: Decodable {
    let id: UUID
    let callUUID: UUID
    let callerId: UUID
    let recipientId: UUID
    let requestedDurationSeconds: Int
    let topic: String?
    let status: CallStatus
    let initiatedAt: Date
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case callUUID = "callUuid"
        case callerId, recipientId, requestedDurationSeconds, topic, status, initiatedAt, createdAt, updatedAt
    }

    var session: CallSession {
        CallSession(
            id: id,
            callUUID: callUUID,
            callerId: callerId,
            recipientId: recipientId,
            requestedDurationSeconds: requestedDurationSeconds,
            topic: topic,
            initiatedAt: initiatedAt,
            status: status,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}
