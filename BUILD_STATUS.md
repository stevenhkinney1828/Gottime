# Build Status

Last updated: 2026-08-20

**Current phase: Phase 2 — Authentication (code done, CI-verified; blocked on 3 owner steps — see bottom)**

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

## Phase 2 — Authentication 🔄 code complete and CI-verified; blocked on 3 owner steps for real-world verification
- ✅ Supabase project created; credentials (Project URL, publishable key, secret key) received and stored in `.env` (gitignored) — the client-safe pieces (project ref + publishable key) also live in `ios/Config/AppConfig.xcconfig`, committed deliberately (see DECISIONS.md for why that one's safe to commit).
- ✅ `SupabaseAuthAdapter` (`ios/App/Integrations/`) — real `AuthService` implementation: Sign in with Apple via `AuthenticationServices`, bridged into async/await; Supabase's auth-state stream bridged into `AuthState`, re-fetching the `profiles` row (not cached Apple/session metadata) as the source of truth for `first_name`.
- ✅ `delete-account` Edge Function — deleting an account needs the service_role key (admin-only), so this is a new, tested (`deno test`, 2/2 passing) server-side endpoint the adapter calls, rather than something the client could do directly under RLS.
- ✅ Supabase Swift SDK added as a dependency; `AppEnvironment.live()` wires real auth in, with connections/voice/history/push still mocked until their own phases (by design — see DECISIONS.md).
- ✅ Release builds (TestFlight) always use the real backend; Debug/Simulator builds (CI, GotTimeUITests) default to mocked so nothing about the now-passing canonical-flow test changed. **Confirmed via a fresh `ios-ci.yml` run**: compiles clean, package resolution succeeds, and the mocked UI test still passes end to end.
- 🚧 **3 owner steps still needed before this is testable against reality** (asked for in chat; not yet confirmed done — checked directly against the live project's REST API and the `profiles` table doesn't exist yet, confirming migrations haven't run):
  1. Run the combined SQL script (sent as a file) in Supabase's SQL Editor, once.
  2. Register an App ID (`com.stevenkinney.gottime`) with Sign in with Apple enabled, in the Apple Developer portal.
  3. Enable and configure the Apple provider in Supabase's Authentication settings (Team ID/Key ID/private key already known to Claude Code, will need re-entering into Supabase's own form since Claude Code can't do that step directly).
- Also genuinely can't be end-to-end tested (tapping "Sign in with Apple" on a real device and having it work) until Phase 4's signed TestFlight builds exist — that's an architectural fact, not a gap in this phase's work: real Sign in with Apple needs a real signed build, which is Phase 4's whole gate.

## Phase 3 — Connections
⬜ Not started.

## Phase 4 — Voice proof (the hard thing)
⬜ Not started. 🚧 Will need: Twilio account/billing/credentials; two physical iPhones; App Store Connect API key + Internal Testing group.

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

## Owner steps now blocking (Phase 2 → Phase 3)
Three small one-time setup steps, all explained in chat: run the combined SQL migration script
in Supabase's SQL Editor; register the app's App ID with Sign in with Apple in the Apple
Developer portal; enable and configure the Apple provider in Supabase's Authentication settings.
None of these need new credentials — everything required for them was already supplied. Phase 3
(Connections) also can't meaningfully start until the SQL script has run, since it needs the
`connections`/`connection_invites` tables to exist on the real project.

## Owner gates still ahead
See the table in the approved build plan / SETUP.md for the full list and what each requires.
