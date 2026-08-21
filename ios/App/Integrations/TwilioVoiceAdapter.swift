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
/// — not called from anywhere yet, since receiving a `CallInvite` at all requires a VoIP push,
/// which needs `PushService`/PushKit registration (a separate, already-distinct protocol,
/// Phase 5). This adapter is structurally complete and correct for that day one regardless;
/// nothing here needs to change once PushKitAdapter starts feeding it real invites.
public final class TwilioVoiceAdapter: NSObject, VoiceService, @unchecked Sendable {
    private let client: SupabaseClient
    public let events: AsyncStream<VoiceEvent>
    private let continuation: AsyncStream<VoiceEvent>.Continuation

    private let lock = NSLock()
    private var activeCall: Call?
    private var activeSession: CallSession?
    private var pendingInvite: CallInvite?

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
        let session = try await requestCallSession(recipientId: recipient.profile.id, durationSeconds: durationSeconds)
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
        pendingInvite = nil
        lock.unlock()

        try? await performCallAction(callUUID: callUUID, action: "answer")
    }

    public func decline(callUUID: UUID) async throws {
        guard let invite = pendingInviteMatching(callUUID) else {
            throw TwilioVoiceAdapterError.noPendingInvite
        }
        invite.reject()
        lock.lock()
        pendingInvite = nil
        lock.unlock()
        try? await performCallAction(callUUID: callUUID, action: "decline")
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

    // MARK: - Incoming call plumbing (populated once PushKitAdapter exists — Phase 5)

    /// Called by the future PushKitAdapter's `NotificationDelegate.callInviteReceived(_:)` once
    /// VoIP push registration exists. Kept as a plain method (not a NotificationDelegate
    /// conformance on this type) so this adapter has no PushKit dependency of its own — it only
    /// needs to be handed a `CallInvite` however one arrives.
    public func handleIncomingCallInvite(_ callInvite: CallInvite, callerProfile: Profile, session: CallSession) {
        lock.lock()
        pendingInvite = callInvite
        lock.unlock()
        continuation.yield(.incomingCall(session: session, callerProfile: callerProfile))
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

    private func currentSession(matching callUUID: UUID) -> CallSession? {
        lock.lock()
        defer { lock.unlock() }
        guard activeSession?.callUUID == callUUID else { return nil }
        return activeSession
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
        guard var session = activeSession, session.callUUID == callUUID,
            let updated = try? CallStateMachine.apply(status, to: session, at: .now)
        else {
            lock.unlock()
            return
        }
        session = updated
        activeSession = session
        lock.unlock()
        continuation.yield(.statusChanged(session: session))
        if session.status.isTerminal {
            continuation.yield(.callEnded(callUUID: callUUID))
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
