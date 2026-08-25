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
    public func startCall(to recipient: ConnectedPerson, durationSeconds: Int) async throws -> CallSession {
        let createdSession = try await requestCallSession(recipientId: recipient.profile.id, durationSeconds: durationSeconds)
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
            builder.uuid = session.callUUID
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
        try disconnectActiveCall(matching: callUUID)
        try? await performCallAction(callUUID: callUUID, action: "cancel")
    }

    public func endEarly(callUUID: UUID) async throws {
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
    public func handleIncomingCallInvite(_ callInvite: CallInvite, callerProfile: Profile, session: CallSession) {
        lock.lock()
        pendingInvite = callInvite
        pendingSession = session
        lock.unlock()
        continuation.yield(.incomingCall(session: session, callerProfile: callerProfile))
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
    public func handleCancelledCallInvite(callSid: String) {
        lock.lock()
        let matchedUUID = pendingInvite?.callSid == callSid ? pendingInvite?.uuid : nil
        if matchedUUID != nil {
            pendingInvite = nil
            pendingSession = nil
        }
        lock.unlock()
        if let matchedUUID {
            continuation.yield(.callEnded(callUUID: matchedUUID))
        }
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

    private func requestCallSession(recipientId: UUID, durationSeconds: Int) async throws -> CallSession {
        struct RequestBody: Encodable {
            let recipientId: UUID
            let requestedDurationSeconds: Int
        }
        struct ResponseBody: Decodable {
            let session: CallSessionRow
        }
        let response: ResponseBody = try await client.functions.invoke(
            "request-call",
            options: FunctionInvokeOptions(
                body: RequestBody(recipientId: recipientId, requestedDurationSeconds: durationSeconds)
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

    private func pendingInviteMatching(_ callUUID: UUID) -> CallInvite? {
        lock.lock()
        defer { lock.unlock() }
        guard pendingInvite?.uuid == callUUID else { return nil }
        return pendingInvite
    }

    private func disconnectActiveCall(matching callUUID: UUID) throws {
        lock.lock()
        let call = activeCall
        lock.unlock()
        guard let call, call.uuid == callUUID else {
            throw TwilioVoiceAdapterError.noActiveCall
        }
        call.disconnect()
    }

    /// Applies a `CallStateMachine` transition to the tracked session and emits the result —
    /// the single choke point every delegate callback below funnels through, so GotTimeCore's
    /// own transition rules (not ad hoc logic here) decide what's valid, exactly like
    /// `MockVoiceService.tryApply` does for the mocked path.
    private func applyAndEmit(_ status: CallStatus, callUUID: UUID) {
        lock.lock()
        guard let session = activeSession else {
            lock.unlock()
            report(status: "no_active_session", detail: "attempted=\(status)")
            return
        }
        guard session.callUUID == callUUID else {
            lock.unlock()
            report(status: "uuid_mismatch", detail: "attempted=\(status) callUUID=\(callUUID) sessionCallUUID=\(session.callUUID)")
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
        continuation.yield(.statusChanged(session: updated))
        if updated.status.isTerminal {
            continuation.yield(.callEnded(callUUID: callUUID))
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
        guard let uuid = call.uuid else { return }
        applyAndEmit(.ringing, callUUID: uuid)
    }

    public func callDidConnect(call: Call) {
        guard let uuid = call.uuid else { return }
        applyAndEmit(.connected, callUUID: uuid)
    }

    public func callDidFailToConnect(call: Call, error: Error) {
        guard let uuid = call.uuid else { return }
        applyAndEmit(.failed, callUUID: uuid)
        clearIfActive(call)
    }

    public func callDidDisconnect(call: Call, error: Error?) {
        guard let uuid = call.uuid else { return }
        lock.lock()
        let wasConnected = activeSession?.status == .connected
        lock.unlock()
        // A real Twilio-reported error, or a disconnect before ever connecting, is a failure;
        // a clean disconnect from a connected call is an early hangup. Distinguishing "hung up
        // on schedule at zero" from this is deliberately not attempted here — same reasoning
        // as twilio-status-callback's own "completed" no-op: that needs Phase 6's full
        // duration-enforcement design, and CallStateMachine simply rejects an invalid
        // .endedEarly attempt on a session this adapter itself already marked .timedOut via
        // that mechanism, so nothing here can incorrectly overwrite it.
        applyAndEmit(error != nil ? .failed : (wasConnected ? .endedEarly : .failed), callUUID: uuid)
        clearIfActive(call)
    }

    public func callIsReconnecting(call: Call, error: Error) {}
    public func callDidReconnect(call: Call) {}

    private func clearIfActive(_ call: Call) {
        lock.lock()
        if activeCall?.uuid == call.uuid {
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
    let status: CallStatus
    let initiatedAt: Date
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case callUUID = "callUuid"
        case callerId, recipientId, requestedDurationSeconds, status, initiatedAt, createdAt, updatedAt
    }

    var session: CallSession {
        CallSession(
            id: id,
            callUUID: callUUID,
            callerId: callerId,
            recipientId: recipientId,
            requestedDurationSeconds: requestedDurationSeconds,
            initiatedAt: initiatedAt,
            status: status,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}
