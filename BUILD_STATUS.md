# Build Status

Last updated: 2026-08-27 (build 26 built: per-connection nicknames, the first of three features the owner asked to build in sequence — Siri and "Respond with Text" deferred, in that order, until this one and everything before it is confirmed solid on a real device)

**Current phase: Phase 5/6 complete and confirmed (see below). Now building owner-requested features on top, one at a time, in an agreed order: nicknames → Siri → Respond-with-Text.** Phase 4's real two-way calling, CallKit lock-screen answering/declining, the auto-end-at-zero fix, real History, the live ticking countdown, the optional call topic, and the Phase 6 sweep backstop are all built and confirmed working (see below for the full sequence), including a missed-call ring timeout tuned down to 20s per the owner's own request after timing a real one at 33s. **Per-connection nicknames (build 26)** are now built — prompted by the owner asking how self-reported names work and realizing a connection could rename themselves "Mom" as a prank, since names are entirely self-reported and unrestricted. Not yet confirmed on a real device.

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

## Phase 4 — Voice proof (the hard thing) ✅ complete, confirmed on real devices
Real two-way audio between two real iPhones, in both directions, with the timer starting only
on genuine connection and the call auto-ending at zero — the phase's actual exit criterion,
confirmed by the owner on build 19/20. Getting here took 20 real builds and roughly a dozen
distinct real bugs, each root-caused from actual evidence (crash reports, on-device diagnostics,
Twilio's own call logs, direct database queries) rather than guessed — full blow-by-blow of
every one is in DECISIONS.md, not repeated here. The headline sequence, for context on how this
phase actually unfolded:

- **Backend + signing pipeline built and proven first** (`issue-voice-token`/`twiml-voice`/
  `twilio-status-callback`, all Twilio protocol details verified against real documentation; CI's
  `sign-and-upload` job reaching TestFlight for the first time, four real signing issues found
  and fixed along the way).
- **Real-device testing then surfaced bugs no amount of mocked/CI testing could have caught**,
  roughly in this order: a launch crash from custom `INFOPLIST_KEY_*` values never actually
  synthesizing into the compiled Info.plist (fixed by moving them to a plain Swift constants
  file); onboarding's Continue button not re-emitting auth state after a database write; invite
  redemption swallowing real Postgres error text; the People list never refreshing after adding a
  connection; and the big one — **real calls could never connect at all**, because receiving a
  call requires PushKit VoIP registration, a Phase 5 dependency the original phase boundary
  didn't anticipate needing this early.
- **Getting PushKit registration itself working took several more real rounds**: a silently
  swallowed SDK error, `UIBackgroundModes` never actually synthesizing into Info.plist (fixed
  with a partial physical `Info.plist` merged via `INFOPLIST_FILE`), and a VoIP Services
  Certificate/Twilio Push Credential pipeline that had to be built and verified end to end.
- **Once registration worked, a deeper state-machine bug was found**: `CallStateMachine` requires
  `created -> outgoing` before `ringing`/`connected` are valid, but nothing anywhere ever
  performed that transition — every real call event, on both sides, had been silently rejected
  the whole project. Fixing it made the caller's side work for the first time.
- **The recipient's side needed one more fix**: Twilio's own `CallInvite.uuid` never matched this
  app's `call_uuid`, so `answer()`/`decline()` always threw before ever reaching Twilio —
  confirmed with real diagnostic data (two different UUIDs shown side by side), not guessed.
- **With signaling fully working, three final gaps surfaced**: no audio in either direction
  (root cause: forcing `ConnectOptions.uuid`/`AcceptOptions.uuid` silently disables the SDK's
  automatic audio-device activation outside of CallKit — confirmed via Twilio's own docs, fixed
  by matching on Call object identity instead of any uuid field); the two participants' timers
  desyncing (fixed by reconciling to the server's authoritative `connected_at`); and that fix
  only being possible once a naming bug was found — Twilio's real event is `"in-progress"`, not
  `"answered"`.
- **Also delivered along the way**: fully arbitrary call durations (15 seconds to 60 minutes,
  not just whole-minute presets) per the owner's own request, and the 15s/30s/1min/3min preset
  buttons.

Every one of these was root-caused from real evidence — crash reports, on-screen diagnostics
written specifically to answer one question, Twilio's own call/event logs, direct Postgres
queries — never guessed twice. See DECISIONS.md for the complete technical account.

## Phase 5 — CallKit / PushKit 🔄 in progress, core build complete
✅ PushKit VoIP registration (pulled forward into Phase 4 out of necessity — see above),
confirmed working end to end. ✅ Full native CallKit lock-screen integration built (build 23,
after build 22 failed CI outright on a real `Self`-in-stored-property-initializer compile error
— fixed, see DECISIONS.md), 🔄 awaiting its real-device test. Two explicit owner requirements drove this work: the lock
screen must show the requested duration (not just the caller's name), and Answer/Decline must
work directly from the lock screen.

- ✅ **Owner also asked to distinguish "declined" from "no answer."** Found this was already
  fully designed since Phase 1 (`CallStatus.declined`/`.missed` are distinct cases,
  `ActiveCallView` already has distinct summary text for both) but never correctly produced by
  the real `TwilioVoiceAdapter` — every never-connected disconnect fell back to `.failed`,
  including the caller's own explicit Cancel action (which should have shown "Call canceled").
  Fixed: local actions (`cancel`/`endEarly`) now set their real outcome immediately, before
  disconnecting; the ambiguous "disconnected, never connected, no local action" case defaults to
  `.missed` and briefly checks the server for `.declined` (recorded authoritatively by the
  *recipient's* own decline action, which the caller's device has no other way to learn about).
  Build 21 confirmed on TestFlight (both CI jobs green). Not yet confirmed on a real device —
  will be verified together with the CallKit test below, since both need the same kind of
  deliberate real-call testing.
- ✅ **`CallKitAdapter` built** (`CXProvider`/`CXProviderDelegate`) — reports incoming calls to
  the lock screen with a composed "Name • Duration" display, routes native Answer/Decline into
  `TwilioVoiceAdapter`, and manages audio-session activation for CallKit-answered calls (paired
  with reintroducing `AcceptOptions.uuid`, safely this time — see DECISIONS.md for why that's
  different from the build-18 regression). Scoped to incoming calls only; outgoing stays on its
  already-proven non-CallKit path.
- ✅ **`GotTimeAppDelegate` added** so VoIP push registration happens at true app-launch time
  (`UIApplicationDelegateAdaptor`, not a SwiftUI `.task`) — required so a fully terminated app can
  still be woken and correctly report an incoming call before any view has rendered.
- ✅ **`CallCoordinator` made properly reactive** to CallKit's native Answer path, and a related
  gap fixed as a side effect: a cancelled/declined incoming call now always clears correctly,
  even when never promoted to an active call.
- ✅ **Build 23 confirmed on a real locked phone**: lock-screen answer via CallKit's native UI
  worked — the actual core deliverable of this phase. The same test surfaced two real gaps, both
  unrelated to CallKit itself and both fixed in build 24 (see Phase 6 below for the serious one):
  no visible countdown while the phone stayed locked, and the call answered from the lock screen
  never actually ending when the timer reached zero.
- ✅ **Build 25: live ticking lock-screen countdown + optional call topic, per the owner's own
  follow-up requests.** `CallKitAdapter` now updates its displayed label once per second while
  connected (e.g. "Thunder • 4:32 left • Dinner tonight"), and callers can now optionally type
  what a call is about, shown alongside name/duration both on the lock screen and in the in-app
  incoming-call screen. **The countdown is explicitly flagged best-effort, not guaranteed** — real
  research (not guessed) found multiple long-standing, still-unresolved Apple Developer Forum
  reports that this exact mechanism (`CXProvider.reportCall(with:updated:)` on an already-active
  call) frequently fails to visibly refresh on real hardware, spanning iOS 17-18. Built anyway
  since it was explicitly requested and costs little either way; the upcoming real-device test
  needs to specifically settle whether it actually ticks on the owner's own phones. Also closed a
  related gap found while building this: nothing previously told CallKit when a call ended for a
  reason it didn't itself initiate (a remote hangup, or this device's own new auto-expiry timeout)
  — see DECISIONS.md for the full account, including why this needed a closure
  (`TwilioVoiceAdapter.onVoiceEvent`) rather than a second consumer of the existing event stream.
- ✅ **Build 25 confirmed on a real device, including the one genuinely uncertain part**: native
  Answer/Decline both work (Decline on the actual lock screen is the iOS side-button gesture, not
  an on-screen button — confirmed from a real screenshot, standard OS behavior for any call, not
  specific to this app); declined vs. no-answer confirmed as genuinely distinct in real History
  data (verified directly against the database, not just the app's own display); the typed topic
  works end to end; and **the ticking countdown actually ticks** on the owner's real phones,
  resolving the one open question the best-effort research-backed caveat above was flagged for.
- ✅ **Build 26: per-connection nicknames — the first of three owner-requested features,
  agreed to be built one at a time (nicknames → Siri → Respond-with-Text), rather than all at
  once.** Found while the owner asked how self-reported names actually work: a connection's
  displayed name (People list, lock screen, History) was entirely self-reported and freely
  editable via Settings at any time, with zero validation — a connection really could rename
  themselves "Mom" as a prank. Fixed with a private, per-viewer nickname (new
  `contact_nicknames` table, migration 0014) that overrides what's shown on *your* side only,
  independent of whatever the other person calls themselves — matching how phone Contacts apps
  solve the same problem. Renamable anytime from the People list (a swipe action, or a pencil
  button in the single-connection layout) — not tied to the moment you first connect. Every
  screen that shows a connection's name (People list, duration picker, active/incoming call,
  the CallKit lock-screen label, History) now uses it. See DECISIONS.md for the full design
  account, including why this is keyed by the two user ids rather than the connection itself
  (survives a disconnect/reconnect) and why `Profile.firstName` itself was deliberately left
  untouched rather than silently overwritten. Not yet confirmed on a real device.
- 🔄 **Deferred at the owner's own request, not forgotten** — two more features, wanted next,
  once nicknames are confirmed solid on a real device:
  1. **Siri support** (via App Intents — real and buildable, confirmed via research; requires the
     app to briefly foreground itself when actually placing a call, a real Apple-enforced
     constraint, not a design choice).
  2. **"Respond with Text"** (Apple's own version is genuinely unavailable to third-party CallKit
     apps — confirmed via research and via a real screenshot showing no "Message" quick action
     even appears; the buildable alternative is an in-app quick-reply delivered as a regular push
     notification after declining, not a literal lock-screen button).
  See DECISIONS.md for the full research behind both.

## Phase 6 — Timer enforcement ✅ complete — all three planned layers now real
**Correction to an earlier claim in this section**: the client-side disconnect-at-zero was
previously believed confirmed working on real devices "for free" once Phase 4's signaling was
fixed. Build 23's real CallKit test proved that wrong — grepping the codebase for `.timedOut`
(the status this mechanism produces) found it was only ever implemented in `MockVoiceService`;
`TwilioVoiceAdapter`, the real adapter, never once produced it. Fixed in build 24:
`TwilioVoiceAdapter` now schedules its own local expiry from `connectedAt` and genuinely calls
`call.disconnect()` at zero — confirmed on a real device: with the countdown now visibly ticking
down to zero, the owner watched it happen and confirmed the call actually hangs up at that point.

**The third layer — the `pg_cron`/`pg_net` sweep backstop — is now built too**, and not
speculatively: asked to keep troubleshooting before moving to new features, a direct database
query found dozens of real `call_sessions` rows stuck in `created`/`outgoing`/`ringing` for
hours — one for over a day — with nothing ever going to resolve them (the only thing that ever
did was the caller's own device, which a killed app, a dropped network, or abandoned testing can
silently prevent from reporting back). Built `expire-call-sweep` for real (pure, tested logic;
runs every minute via `pg_cron` + `pg_net`, authenticated with a service-role credential stored in
Supabase Vault, never committed to git); a manual first run swept all 45 genuinely stale sessions
found; the cron job's own scheduled ticks were independently confirmed actually firing and
succeeding (real `200` responses pulled from `net._http_response`, not just trusted). See
DECISIONS.md for the full account, including a real CI gap this surfaced and fixed
(`sql-lint.yml` now skips this one migration — its plain Postgres container can't run
`pg_cron`/`pg_net`, which need server-level config a Docker container isn't started with; every
other migration still applies and still gets its RLS checks run normally).

All three of Phase 6's originally-planned enforcement layers (client-side, per-device disconnect;
server-side status recording; and now this backstop sweep) are real and independently verified.

**A genuine missed call (left ringing, untouched) was also explicitly tested and confirmed** —
resolves to "Missed" in History correctly, not stuck as "In progress." The owner timed it at 33
seconds and flagged it as feeling long; traced to Twilio's `<Dial>` never setting its own
`timeout` attribute (distinct from `timeLimit`), so it fell back to Twilio's undocumented-in-code
30s default. Made explicit and lowered to 20s per the owner's own request ("low 20s... 30 seconds
seems long") — deployed and sanity-checked directly against the live project.

## Also fixed in build 24: History was showing mock data, not real calls
`callHistoryService` had been deliberately left on `MockEnvironment` since Phase 1 while the
harder voice/CallKit work took priority (documented plainly in `AppEnvironment.swift`'s own doc
comment) — every History screen the owner has seen so far was always the mock's seeded
placeholder data, never a real call. Not a new bug, just a gap whose time had come now that real
calls exist to show. Added `SupabaseCallHistoryAdapter`, reading `call_sessions` directly (RLS
already scopes results to the signed-in user). Not yet confirmed on a real device.

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
9. ~~App Store Connect API key + app record~~ — Admin-role Team API key created, app registered as "GotTime? Calling", all four secrets saved; **CI now genuinely signs and uploads a real build to TestFlight, verified by an actual successful run**, not just by the pipeline existing.
10. ~~Internal Testing group~~ — "Family Tester" group created, automatic build distribution turned on, owner added as a tester (adding a tester turned out to be a separate screen from creating the group itself — normal App Store Connect behavior, not a bug).
11. ~~Two physical iPhones~~ — both on hand, TestFlight installed, real device testing actually underway (see the crash finding above).
12. ~~VoIP Services Certificate~~ — generated via the Apple Developer Portal, verified as a matched pair with its private key, and turned into a Twilio Push Credential wired into real token minting (see above).

## No owner gate currently blocking — real device testing is in progress
Every setup gate for this phase is cleared. What's happening now is the actual real-device
testing this whole phase exists for: install the build, sign in, connect, place a real call.
The first real launch surfaced one genuine bug (see above, now fixed) — expect this kind of
finding to keep happening for a bit as more of the app runs for the first time ever on real
hardware, the same way the CI signing pipeline needed several real rounds before every part of
it had actually been exercised.

See the table in the approved build plan / SETUP.md for the full list beyond this and what each
requires.
