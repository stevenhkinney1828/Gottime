# Build Status

Last updated: 2026-08-21

**Current phase: Phase 4 — Voice proof (backend done and verified live; TwilioVoiceAdapter built and wired in, CI verification in progress; 2-part owner gate remains for real device testing — see bottom)**

Phase 0 and Phase 1 are both complete, CI-verified, and committed.

Legend: ✅ done · 🔄 in progress · ⬜ not started · 🚧 blocked on owner gate

## Phase 0 — Foundation ✅ complete
- ✅ Git repository initialized; Phase 0 committed at `0b42f44`
- ✅ Repository folder structure created
- ✅ Root documentation (README, SETUP, ARCHITECTURE, DESIGN_SYSTEM, DECISIONS, KNOWN_LIMITATIONS, BUILD_STATUS, BETA_FEEDBACK, .env.example)
- ✅ Local tooling installed (Deno, PostgreSQL 17 — the Postgres install ran unusually slowly, ~40 minutes, because Windows Defender was scanning pgAdmin's large bundled Python environment file-by-file during unpacking; not needed for anything, just slow)
- ✅ `ios/project.yml` + empty App target + GotTimeCore/GotTimeMocks packages with placeholder tests
- ✅ `supabase/migrations` 0001-0006 (five tables + RLS policies) + `auth_shim.sql` + `seed.sql` — **applied to a real local Postgres 17 instance and verified working**: all 6 migrations ran clean, the `on_auth_user_created` trigger correctly creates profiles, RLS correctly denies an unconnected user (Carol) and allows a connected participant (Alice), `redeem_connection_invite()` correctly creates a connection and rejects re-redemption, direct client INSERT into `connections`/`call_sessions` is correctly denied (permission denied, as designed), and the `requested_duration_seconds` CHECK constraint correctly accepts 60s/3600s and rejects 59s/3601s
- ✅ `supabase/functions/` skeletons — `_shared/` helpers fully implemented (cors, logger, supabaseAdmin, twilioClient, apnsJwt) and unit-tested; the 7 feature functions are thin, tested stubs pending their real phase (noted in each file)
- ✅ CI workflows (`ios-ci.yml`, `backend-ci.yml`, `sql-lint.yml`) — written and connected to a real GitHub repository (`stevenhkinney1828/Gottime`). `ios-ci.yml` and `backend-ci.yml` have both run for real and gone green (see Phase 1 below). `sql-lint.yml` hasn't run yet — it only triggers on changes under `supabase/migrations`/`supabase/seed`, which haven't changed since the repo went up, and manual dispatch via the API 403s under the current fine-grained GitHub token (needs a one-click "Run workflow" in the browser instead — not urgent, the same assertions already passed locally against real Postgres, see below).
- ✅ Local verification: `deno test`/`deno lint`/`deno fmt --check` all pass (10/10 tests); full migration + RLS dry-run passes against real local Postgres. Caught and fixed three real bugs along the way (a TypeScript BufferSource typing issue in the APNs JWT signer, a transaction-scoping bug in the auth_shim test helpers, and a missing explicit grant on the invite-redemption function) — all before they could cause silent failures later.

## Phase 1 — Mocked UX ✅ complete, CI-verified
- ✅ `GotTimeCore` models: `Profile`, `CallStatus` (11 cases — see DECISIONS.md re: the added `canceled` status), `CallSession`, `Connection`/`ConnectedPerson`/`ConnectionInvite`, `CallHistoryEntry` — all pure Swift, zero Apple-framework imports (verified: only `Foundation` appears anywhere in GotTimeCore)
- ✅ `GotTimeCore` service protocols: `AuthService`, `ConnectionService`, `VoiceService`, `CallHistoryService`, `PushService`
- ✅ `CallStateMachine` — the full transition table, an `apply()` helper that stamps timestamps/computes actual duration, exhaustively tested (all 121 from/to pairs checked against an independently-written expected table, plus named tests for every path in spec sections 19-20)
- ✅ `DurationPolicy` — 1-60 whole-minute validation + presets, tested against the exact boundary matrix spec section 19 calls for
- ✅ `CallTimer` — connected-timestamp-anchored countdown math, zero accumulating state, tested including the specific "long background gap" scenario spec section 7 is worried about
- ✅ `request-call`/`call-action` real backend logic — server-side duration/connection/ownership validation, dependency-injected and fully tested (27/27 backend tests passing, lint clean, format clean). Caught a real bug in a *test* (not the implementation) along the way: a test meant to check status-based rejection was accidentally using the wrong actor and tripping a role-based rejection instead — fixed once the failure surfaced what it actually meant.
- ✅ `GotTimeMocks` — all 5 mock services implemented: simulated ringing/answer/decline/missed/failed outcomes, a dev-only accelerated timer (DEBUG-only, structurally can't affect production), seed data covering all 6 history statuses, and a `MockEnvironment` wiring them together the way the app actually needs. `MockVoiceService` in particular went through several careful correctness passes for concurrency safety (a single atomic "try apply transition" choke point every code path funnels through, so an explicit user action racing the simulated auto-progression timer can't double-fire a terminal state or double-record history) — reasoned through by hand since there's no compiler here to catch it.
- ✅ SwiftUI screens — People (list + single-person fast path per spec section 6), duration picker (explicit-confirm required, matches the "Call Chris for 10 minutes" phrasing exactly), active call (Calling/Ringing → live countdown → post-call summary, all one continuous screen), incoming call (in-app banner standing in for CallKit until Phase 5), history, settings, onboarding, add-connection. A `CallCoordinator` centralizes all call-state handling per spec section 14, driven by `VoiceService.events` and never storing remaining time itself — always recomputed fresh from `CallTimer`.
- ✅ `GotTimeUITests` — walks the full canonical flow (pick Chris → 5 min → explicit confirm → ringing → auto-connect → countdown → automatic ending → history gains exactly one new entry). Uses a `GOTTIME_DEV_TIME_SCALE` launch-environment override for test speed, separate from the gentler default a human manually testing the app gets.

**Verified for real in CI, not just reviewed.** `ios-ci.yml` now runs on every push against a real `macos-latest` GitHub Actions runner: `GotTimeCore`'s and `GotTimeMocks`' test suites both pass, the app target compiles, and `GotTimeUITests` walks the entire canonical flow end to end on a real iOS Simulator — pick Chris, choose 5 minutes, explicit confirm, simulated ringing, auto-connect, live countdown, automatic termination at zero, "Done," and a new History entry recorded — all green. Getting there took real debugging, not just the initial build: six compile-time errors (a missing platform target, a timer-math test with a wrong expected value, four tests missing a buffered status event, a missing `import SwiftUI`, and a `deinit`-isolation error) and then a genuine runtime bug where the active-call screen never appeared after confirming a call. That last one took five serious attempts to root-cause — the first four all adjusted *how* SwiftUI's `.fullScreenCover`/`.sheet` presented the call screen and all failed identically, which turned out to be the tell: the fix was removing that presentation mechanism entirely in favor of a plain view-composition overlay, not tuning it further. Full blow-by-blow is in [DECISIONS.md](DECISIONS.md) for anyone curious, but the short version is: Phase 1 is done, and "done" here means a real compiler and a real Simulator agreed, not just careful reading.

## Phase 2 — Authentication ✅ complete, verified against the real project
- ✅ Supabase project created; credentials (Project URL, publishable key, secret key) received and stored in `.env` (gitignored) — the client-safe pieces (project ref + publishable key) also live in `ios/Config/AppConfig.xcconfig`, committed deliberately (see DECISIONS.md for why that one's safe to commit).
- ✅ `SupabaseAuthAdapter` (`ios/App/Integrations/`) — real `AuthService` implementation: Sign in with Apple via `AuthenticationServices`, bridged into async/await; Supabase's auth-state stream bridged into `AuthState`, re-fetching the `profiles` row (not cached Apple/session metadata) as the source of truth for `first_name`.
- ✅ `delete-account` Edge Function — deleting an account needs the service_role key (admin-only), so this is a new, tested (`deno test`, 2/2 passing) server-side endpoint the adapter calls, rather than something the client could do directly under RLS.
- ✅ Supabase Swift SDK added as a dependency; `AppEnvironment.live()` wires real auth in, with connections/voice/history/push still mocked until their own phases (by design — see DECISIONS.md).
- ✅ Release builds (TestFlight) always use the real backend; Debug/Simulator builds (CI, GotTimeUITests) default to mocked so nothing about the now-passing canonical-flow test changed. Confirmed via a fresh `ios-ci.yml` run: compiles clean, package resolution succeeds, and the mocked UI test still passes end to end.
- ✅ All 3 owner setup steps done and **independently verified against the live project**, not just taken on the owner's word: all 5 tables exist via direct REST calls; RLS is actually active (an unauthenticated request against `profiles` correctly returns zero rows rather than an error or real data); `redeem_connection_invite()` exists and correctly rejects an unauthenticated call; and initiating a real Supabase auth request (`/auth/v1/authorize?provider=apple`) returns a proper redirect to `appleid.apple.com` with the correct `client_id=com.stevenkinney.gottime`, confirming the App ID registration, the Supabase Apple provider config, and the OAuth client-secret JWT (generated locally by reusing the same ES256-signing approach as the APNs helper, since Supabase's "Secret Key" field wants a signed token, not the raw `.p8` contents — see DECISIONS.md) are all correctly wired together end to end.
- Still can't be tested by actually tapping "Sign in with Apple" on a device until Phase 4's signed TestFlight builds exist — that remains an architectural fact (native Sign in with Apple needs a real signed build), not a gap in this phase's work. Everything server-side and client-code-side that *can* be verified without a physical sign-in has been.

## Phase 3 — Connections ✅ complete, verified against the real project
- ✅ `SupabaseConnectionAdapter` (`ios/App/Integrations/`) — real `ConnectionService`: `fetchConnections`/`createInvite`/`redeemInvite`/`removeConnection` against the real `connections`/`connection_invites` tables and the `redeem_connection_invite()` RPC. No UI changes needed — `AddConnectionView`/`PeopleListView` already called the protocol generically, so the real adapter drops in without touching view code.
- ✅ Invite-code generation promoted to `GotTimeCore.InviteCodeGenerator` (with tests), shared between the mock and the real adapter rather than duplicated.
- ✅ Confirmed via a fresh `ios-ci.yml` run: compiles clean, mocked UI test still passes end to end.
- ✅ **The whole security model verified live against the real project**, exactly as the build plan called for: `backend/scripts/verify-connections-rls.ts` creates three throwaway users through the Admin API (no real Apple ID needed), then as real authenticated requests — Alice creates an invite, Bob redeems it, both can then see each other's profile, a third unconnected user (Carol) sees neither the profile nor the connection, redeeming an already-redeemed code fails, and redeeming your own invite fails. All 8 checks passed on the first real run; cleanup of all three throwaway users independently confirmed afterward via a follow-up Admin API listing, not just assumed. Script is committed and re-runnable, not a one-off — see `backend/README.md`.

## Phase 4 — Voice proof (the hard thing) 🔄 Edge Function logic done; 🚧 blocked on owner gate for the real thing
- ✅ `issue-voice-token` — mints a real Twilio Voice Access Token (the exact JWT format Twilio's SDK expects: HS256, `cty: "twilio-fpa;v=1"`, `grants.identity`/`grants.voice.outgoing.application_sid`), identity = the caller's own Supabase user id. Tested including an independent HMAC-signature re-verification (5/5 tests), not just checking the decoded claims look right.
- ✅ `twiml-voice` — the webhook Twilio calls when the caller's Voice SDK connects; looks up the `call_sessions` row, verifies the request's `From: client:<identity>` actually matches that session's caller (closes a real, if narrow, spoofing gap — a client could otherwise supply any call_session_id as its own outgoing param), and returns `<Dial timeLimit="..."><Client statusCallbackEvent="..." statusCallback="...">` TwiML routing to the recipient. 7/7 tests passing.
- ✅ `twilio-status-callback` — records `ringing_at`/`connected_at` as Twilio itself reports them (server-side confirmation that "the timer starts only on connection," not just the client's own clock). Deliberately treats the terminal "completed" event as a no-op for now — distinguishing early-hangup from on-schedule-timeout needs Phase 6's full duration-enforcement design, not a guess made here. 4/4 tests passing.
- Every protocol detail above (JWT shape, TwiML attribute placement and exact vocabulary, how `<Parameter>` differs from a webhook's own query string) was checked against Twilio's current documentation before writing code against it, not assumed from memory — see DECISIONS.md for two real corrections this caught before they became bugs.
- ✅ **Twilio account created and fully wired up**: billing enabled (pay-as-you-go — confirmed the free trial genuinely can't work here, since Twilio's own docs list `<Dial><Client>` as a blocked verb combination on trial accounts), Account SID/Auth Token/API Key SID+Secret all supplied and stored. `backend/scripts/twilio-setup.ts` created the real TwiML Application (idempotent — safe to re-run, reuses the existing one by FriendlyName instead of duplicating) pointing at the real deployed `twiml-voice` function.
- ✅ **All 8 Edge Functions deployed to the real project for the first time** — along the way, found and fixed a real bug in `supabase/config.toml` dating back to Phase 0 (a placeholder `project_id` never updated, and a deprecated `[functions]` schema), which had silently blocked *any* real deployment since Phase 2 without anything surfacing it until a real deploy was actually attempted. See DECISIONS.md for the full story.
- ✅ **The entire voice-token pipeline verified end to end with a real authenticated user and real Twilio credentials**: created a throwaway test user, signed in, called the live `issue-voice-token` function, and got back a genuine Twilio Voice Access Token with the real TwiML App SID embedded and the correct identity — not just passing unit tests against fake credentials.
- ✅ **`TwilioVoiceAdapter` built** (`ios/App/Integrations/`) — real `VoiceService`: `startCall` requests a `call_sessions` row server-side first (`request-call`), mints a fresh Access Token (`issue-voice-token`), then connects through the Twilio Voice SDK, embedding the session id as the call's `callSessionId` param for `twiml-voice` to route on. Every `CallDelegate` callback funnels through the same `CallStateMachine.apply` transition rules `MockVoiceService` already uses. `answer`/`decline` are wired to a `pendingInvite`, populated by a plain method not yet called from anywhere — receiving a real incoming call needs Phase 5's PushKitAdapter first, which doesn't change anything about this adapter once it exists. Twilio Voice iOS SDK added as an SPM dependency (6.13.x); `AppEnvironment.live()` now constructs this adapter for `voiceService`, graduating it alongside the already-live `authService`/`connectionService`.
- ✅ **Caught a real decoding gap before it could surface on a device**: `FunctionsClient`'s default JSON decoder (unlike `PostgrestClient`'s) doesn't parse ISO 8601 date strings, which would have made the adapter's `request-call` response fail to decode its three timestamp fields. Fixed by passing an explicit custom decoder, verified against the SDK's actual `invoke(_:options:decoder:)` signature before relying on it. See DECISIONS.md for the full reasoning.
- 🔄 Pushed for CI verification that the new SPM dependency resolves and the whole App target (including this new file) actually builds — result pending, this line will be updated once it lands.
- 🚧 Still needed before a real two-way call can be tested: two physical iPhones, and an App Store Connect API key + Internal Testing group so CI can sign and upload a real TestFlight build.

## Phase 5 — CallKit / PushKit
⬜ Not started. 🚧 Will need: APNs VoIP Auth Key (.p8).

## Phase 6 — Timer enforcement
⬜ Not started.

## Phase 7 — Reliability
⬜ Not started.

## Phase 8 — Visual polish
⬜ Not started.

## Phase 9 — Friends & family beta
⬜ Not started. 🚧 Will need: external TestFlight testers + Beta App Review.

---

## Owner gates cleared so far
1. ~~GitHub account + repository~~ — repo created and connected; CI runs on every push
2. ~~Apple Developer Program enrollment~~ — already enrolled
3. ~~Sign-in-with-Apple Services ID/Key~~ — Team ID, Key ID, and private key supplied and stored
4. ~~Supabase project~~ — created; Project URL, publishable key, and secret key supplied and stored
5. ~~SQL migration script run~~ — verified: all 5 tables + RLS live on the real project
6. ~~App ID registered with Sign in with Apple~~ — verified via a real OAuth authorize request
7. ~~Supabase Apple provider configured~~ — verified the same way; end-to-end wiring confirmed
8. ~~Twilio account + billing~~ — created, funded, Account SID/Auth Token/API Key SID+Secret supplied and stored; TwiML Application created and verified issuing real tokens

## Owner gate now blocking (Phase 4)
Two things left, both needed before real two-way voice calling can be tested for real:
1. **Two physical iPhones** on hand — this is the one thing with no software substitute; the
   whole point of this phase is proving a real call works between two real devices.
2. **An App Store Connect API key + an Internal Testing group** set up in App Store Connect, so
   CI can sign a real build and upload it to TestFlight automatically. See SETUP.md for the
   walkthrough once ready to set this up.

In the meantime, `TwilioVoiceAdapter` (the Swift/iOS side that actually uses Twilio's Voice SDK)
has now been built without needing either of those — see Phase 4 above. What's left in this
phase is genuinely gated on both: no local or CI-only path can exercise a real two-way call.

See the table in the approved build plan / SETUP.md for the full list beyond this and what each
requires.
