import Foundation
import GotTimeCore
import PushKit
import Supabase
import TwilioVoice

/// Real `PushService`: registers this device for Twilio Voice's own VoIP push delivery and
/// routes incoming call invites to `TwilioVoiceAdapter`. `TwilioVoiceSDK.register` is what
/// makes `<Dial><Client>` reachable at all — confirmed as a hard requirement only by testing a
/// real call between two real devices (every attempt reached Twilio correctly but ended in
/// "no-answer," since neither side had ever registered — see DECISIONS.md). Twilio delivers
/// its own VoIP push once registered; no custom backend push path
/// (`register-device`/`device_registrations`) is needed for this core mechanism, so neither is
/// built yet — a real, if richer, enhancement left for later, not a prerequisite.
public final class PushKitAdapter: NSObject, PushService, @unchecked Sendable {
    private let client: SupabaseClient
    private let voiceAdapter: TwilioVoiceAdapter

    private let lock = NSLock()
    private var registry: PKPushRegistry?
    private var latestToken: Data?

    public init(client: SupabaseClient, voiceAdapter: TwilioVoiceAdapter) {
        self.client = client
        self.voiceAdapter = voiceAdapter
        super.init()
    }

    // MARK: - PushService

    /// Safe to call before sign-in completes — setting up the registry itself needs no auth;
    /// only the later `TwilioVoiceAdapter.registerDeviceToken(_:)` call (triggered once a real
    /// token arrives, see the delegate below) needs a signed-in user, and simply fails quietly
    /// if called too early rather than blocking this method on auth state.
    public func registerForVoIPPushes() async throws {
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        lock.lock()
        self.registry = registry
        lock.unlock()
        // "requested" written up front, separately from "registered"/"failed" below, so a row
        // stuck at "requested" forever is itself a diagnostic: it means PKPushRegistry never
        // handed out a token at all (an entitlements/provisioning problem), as distinct from a
        // token arriving but TwilioVoiceSDK.register failing (a credential/backend problem).
        // See DECISIONS.md and migration 0007.
        //
        // First real retest came back with exactly that "requested, then nothing" result on
        // both phones. PushKit requires the "voip" UIBackgroundModes entry to ever call back at
        // all -- but this project only ever *confirmed* the INFOPLIST_KEY_UIBackgroundModes
        // space-separated-array pattern works via a different key (UISupportedInterfaceOrientations);
        // it was never independently checked for this one. Reading it back directly from the
        // actual compiled bundle here, the same "settle it with on-screen/remote evidence, don't
        // assume precedent transfers" approach that found the real Info.plist bug earlier in
        // this project (see DECISIONS.md).
        let backgroundModes = Bundle.main.infoDictionary?["UIBackgroundModes"] as? [String] ?? []
        await reportPushRegistrationStatus(status: "requested", detail: "UIBackgroundModes=\(backgroundModes)")
    }

    public func currentDeviceToken() async -> String? {
        lock.lock()
        let token = latestToken
        lock.unlock()
        return token?.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Incoming push -> caller profile + session lookup

    /// Sequential, not concurrent (`async let`) — these are two small, fast PostgREST reads,
    /// not a performance-sensitive path, and the simpler sequential form has no `async let`
    /// syntax to get subtly wrong with no way to compile-check it locally.
    private func fetchIncomingCallContext(callerId: UUID, callSessionId: UUID) async throws -> (Profile, CallSession) {
        let profileRow: ProfileRow = try await client.from("profiles")
            .select()
            .eq("id", value: callerId)
            .single()
            .execute()
            .value
        let sessionRow: CallSessionTableRow = try await client.from("call_sessions")
            .select()
            .eq("id", value: callSessionId)
            .single()
            .execute()
            .value
        return (profileRow.profile, sessionRow.session)
    }

    /// Best-effort diagnostic write, not a critical-path operation: a failure here (e.g. no
    /// signed-in session yet) is silently swallowed rather than compounding the very failure
    /// this exists to diagnose. Writes to the caller's own `profiles` row, already permitted by
    /// the existing `profiles_update_self` RLS policy -- no new grant needed.
    private func reportPushRegistrationStatus(status: String, detail: String?) async {
        struct Update: Encodable {
            let pushRegistrationStatus: String
            let pushRegistrationDetail: String?
            let pushRegistrationUpdatedAt: String

            enum CodingKeys: String, CodingKey {
                case pushRegistrationStatus = "push_registration_status"
                case pushRegistrationDetail = "push_registration_detail"
                case pushRegistrationUpdatedAt = "push_registration_updated_at"
            }
        }
        guard let userId = client.auth.currentSession?.user.id else { return }
        let update = Update(
            pushRegistrationStatus: status,
            pushRegistrationDetail: detail.map { String($0.prefix(500)) },
            pushRegistrationUpdatedAt: ISO8601DateFormatter().string(from: Date())
        )
        try? await client.from("profiles").update(update).eq("id", value: userId).execute()
    }

    /// Same shape and same reasoning as `reportPushRegistrationStatus` above, for the other
    /// half of the pipeline that had zero visibility until now: whether an incoming push is
    /// actually received and handled at all. Added once outgoing registration started
    /// succeeding but the recipient's phone still never showed an incoming call -- Twilio's own
    /// call events proved a real ~10s ring was attempted (SIP 487, consistent with the caller
    /// canceling), so the open question shifted from "did registration work" to "what happens
    /// to the push once it arrives" — see DECISIONS.md and migration 0008.
    private func reportIncomingPushStatus(status: String, detail: String?) async {
        struct Update: Encodable {
            let lastIncomingPushStatus: String
            let lastIncomingPushDetail: String?
            let lastIncomingPushUpdatedAt: String

            enum CodingKeys: String, CodingKey {
                case lastIncomingPushStatus = "last_incoming_push_status"
                case lastIncomingPushDetail = "last_incoming_push_detail"
                case lastIncomingPushUpdatedAt = "last_incoming_push_updated_at"
            }
        }
        guard let userId = client.auth.currentSession?.user.id else { return }
        let update = Update(
            lastIncomingPushStatus: status,
            lastIncomingPushDetail: detail.map { String($0.prefix(500)) },
            lastIncomingPushUpdatedAt: ISO8601DateFormatter().string(from: Date())
        )
        try? await client.from("profiles").update(update).eq("id", value: userId).execute()
    }
}

// MARK: - PKPushRegistryDelegate

extension PushKitAdapter: PKPushRegistryDelegate {
    public func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        lock.lock()
        latestToken = credentials.token
        lock.unlock()
        Task { [weak self, voiceAdapter] in
            do {
                try await voiceAdapter.registerDeviceToken(credentials.token)
                await self?.reportPushRegistrationStatus(status: "registered", detail: nil)
            } catch {
                await self?.reportPushRegistrationStatus(status: "failed", detail: "\(error)")
            }
        }
    }

    public func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP else { return }
        lock.lock()
        latestToken = nil
        lock.unlock()
    }

    public func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        guard type == .voIP else {
            completion()
            return
        }
        // dictionaryPayload is [AnyHashable: Any] -- AnyHashable isn't Comparable, so map to
        // String before sorting (caught by a real CI compile failure, not spotted by review;
        // there's no local Swift toolchain to catch this ahead of a push -- see DECISIONS.md).
        let payloadKeys = payload.dictionaryPayload.keys.map { "\($0)" }.sorted().joined(separator: ",")
        Task { [weak self] in
            await self?.reportIncomingPushStatus(status: "push_received", detail: "keys=\(payloadKeys)")
        }
        TwilioVoiceSDK.handleNotification(payload.dictionaryPayload, delegate: self, delegateQueue: nil)
        completion()
    }
}

// MARK: - NotificationDelegate

extension PushKitAdapter: NotificationDelegate {
    /// `callInvite.from` arrives as `"client:<caller's Supabase user id>"` — the same identity
    /// format `twiml-voice` already verifies server-side. `callSessionId` is the same custom
    /// parameter `TwilioVoiceAdapter.startCall` embeds on the outgoing side. Silently drops a
    /// malformed/unresolvable invite rather than crash or surface an error with no UI to show
    /// it to — matches this adapter's own established risk tolerance elsewhere (`try?`).
    public func callInviteReceived(callInvite: CallInvite) {
        guard
            let callerIdString = callInvite.from?.replacingOccurrences(of: "client:", with: ""),
            let callerId = UUID(uuidString: callerIdString),
            let callSessionIdString = callInvite.customParameters?["callSessionId"],
            let callSessionId = UUID(uuidString: callSessionIdString)
        else {
            let detail = "from=\(callInvite.from ?? "nil") params=\(callInvite.customParameters ?? [:])"
            Task { [weak self] in
                await self?.reportIncomingPushStatus(status: "invite_unparseable", detail: detail)
            }
            return
        }

        Task { [weak self] in
            guard let self else { return }
            await self.reportIncomingPushStatus(
                status: "invite_parsed",
                detail: "callerId=\(callerId) callSessionId=\(callSessionId)"
            )
            do {
                let context = try await self.fetchIncomingCallContext(callerId: callerId, callSessionId: callSessionId)
                await self.reportIncomingPushStatus(status: "context_fetched", detail: nil)
                self.voiceAdapter.handleIncomingCallInvite(callInvite, callerProfile: context.0, session: context.1)
                await self.reportIncomingPushStatus(status: "delivered_to_coordinator", detail: nil)
            } catch {
                await self.reportIncomingPushStatus(status: "context_fetch_failed", detail: "\(error)")
            }
        }
    }

    public func cancelledCallInviteReceived(cancelledCallInvite: CancelledCallInvite, error: Error) {
        voiceAdapter.handleCancelledCallInvite(callSid: cancelledCallInvite.callSid)
    }
}

/// Mirrors `call_sessions`' real (snake_case) table columns directly — distinct from
/// `TwilioVoiceAdapter`'s own `CallSessionRow`, which decodes `request-call`'s Edge Function
/// response (camelCase JSON keys), not a raw table row. This one is read via a plain
/// PostgREST `.from("call_sessions")` query, which already applies Postgrest's own ISO 8601
/// date-decoding strategy by default — unlike Edge Function invocations, no custom decoder
/// needed here.
private struct CallSessionTableRow: Decodable {
    let id: UUID
    let callUuid: UUID
    let callerId: UUID
    let recipientId: UUID
    let requestedDurationSeconds: Int
    let status: CallStatus
    let initiatedAt: Date
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case callUuid = "call_uuid"
        case callerId = "caller_id"
        case recipientId = "recipient_id"
        case requestedDurationSeconds = "requested_duration_seconds"
        case status
        case initiatedAt = "initiated_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    var session: CallSession {
        CallSession(
            id: id,
            callUUID: callUuid,
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
