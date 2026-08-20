# Build Status

Last updated: 2026-08-19

**Current phase: Phase 1 — Mocked UX (in progress)**

Phase 0 is complete and committed (`0b42f44`).

Legend: ✅ done · 🔄 in progress · ⬜ not started · 🚧 blocked on owner gate

## Phase 0 — Foundation ✅ complete
- ✅ Git repository initialized; Phase 0 committed at `0b42f44`
- ✅ Repository folder structure created
- ✅ Root documentation (README, SETUP, ARCHITECTURE, DESIGN_SYSTEM, DECISIONS, KNOWN_LIMITATIONS, BUILD_STATUS, BETA_FEEDBACK, .env.example)
- ✅ Local tooling installed (Deno, PostgreSQL 17 — the Postgres install ran unusually slowly, ~40 minutes, because Windows Defender was scanning pgAdmin's large bundled Python environment file-by-file during unpacking; not needed for anything, just slow)
- ✅ `ios/project.yml` + empty App target + GotTimeCore/GotTimeMocks packages with placeholder tests
- ✅ `supabase/migrations` 0001-0006 (five tables + RLS policies) + `auth_shim.sql` + `seed.sql` — **applied to a real local Postgres 17 instance and verified working**: all 6 migrations ran clean, the `on_auth_user_created` trigger correctly creates profiles, RLS correctly denies an unconnected user (Carol) and allows a connected participant (Alice), `redeem_connection_invite()` correctly creates a connection and rejects re-redemption, direct client INSERT into `connections`/`call_sessions` is correctly denied (permission denied, as designed), and the `requested_duration_seconds` CHECK constraint correctly accepts 60s/3600s and rejects 59s/3601s
- ✅ `supabase/functions/` skeletons — `_shared/` helpers fully implemented (cors, logger, supabaseAdmin, twilioClient, apnsJwt) and unit-tested; the 7 feature functions are thin, tested stubs pending their real phase (noted in each file)
- ✅ CI workflows (`ios-ci.yml`, `backend-ci.yml`, `sql-lint.yml`) — written; the `sql-lint.yml` assertions are the same ones just verified locally above, so it's expected to pass once it can actually run; cannot execute for real until a GitHub remote exists (see gate below)
- ✅ Local verification: `deno test`/`deno lint`/`deno fmt --check` all pass (10/10 tests); full migration + RLS dry-run passes against real local Postgres. Caught and fixed three real bugs along the way (a TypeScript BufferSource typing issue in the APNs JWT signer, a transaction-scoping bug in the auth_shim test helpers, and a missing explicit grant on the invite-redemption function) — all before they could cause silent failures later.
- 🚧 **Owner gate #1 (remaining piece): an empty GitHub repository.** Owner already has a GitHub account. Once a repo exists and is connected, CI can run for real (Simulator build/test, SQL/RLS check) instead of relying on local verification alone — see the chat message asking for this.

## Phase 1 — Mocked UX ✅ functionally complete, pending first compile
- ✅ `GotTimeCore` models: `Profile`, `CallStatus` (11 cases — see DECISIONS.md re: the added `canceled` status), `CallSession`, `Connection`/`ConnectedPerson`/`ConnectionInvite`, `CallHistoryEntry` — all pure Swift, zero Apple-framework imports (verified: only `Foundation` appears anywhere in GotTimeCore)
- ✅ `GotTimeCore` service protocols: `AuthService`, `ConnectionService`, `VoiceService`, `CallHistoryService`, `PushService`
- ✅ `CallStateMachine` — the full transition table, an `apply()` helper that stamps timestamps/computes actual duration, exhaustively tested (all 121 from/to pairs checked against an independently-written expected table, plus named tests for every path in spec sections 19-20)
- ✅ `DurationPolicy` — 1-60 whole-minute validation + presets, tested against the exact boundary matrix spec section 19 calls for
- ✅ `CallTimer` — connected-timestamp-anchored countdown math, zero accumulating state, tested including the specific "long background gap" scenario spec section 7 is worried about
- ✅ `request-call`/`call-action` real backend logic — server-side duration/connection/ownership validation, dependency-injected and fully tested (27/27 backend tests passing, lint clean, format clean). Caught a real bug in a *test* (not the implementation) along the way: a test meant to check status-based rejection was accidentally using the wrong actor and tripping a role-based rejection instead — fixed once the failure surfaced what it actually meant.
- ✅ `GotTimeMocks` — all 5 mock services implemented: simulated ringing/answer/decline/missed/failed outcomes, a dev-only accelerated timer (DEBUG-only, structurally can't affect production), seed data covering all 6 history statuses, and a `MockEnvironment` wiring them together the way the app actually needs. `MockVoiceService` in particular went through several careful correctness passes for concurrency safety (a single atomic "try apply transition" choke point every code path funnels through, so an explicit user action racing the simulated auto-progression timer can't double-fire a terminal state or double-record history) — reasoned through by hand since there's no compiler here to catch it.
- ✅ SwiftUI screens — People (list + single-person fast path per spec section 6), duration picker (explicit-confirm required, matches the "Call Chris for 10 minutes" phrasing exactly), active call (Calling/Ringing → live countdown → post-call summary, all one continuous screen), incoming call (in-app banner standing in for CallKit until Phase 5), history, settings, onboarding, add-connection. A `CallCoordinator` centralizes all call-state handling per spec section 14, driven by `VoiceService.events` and never storing remaining time itself — always recomputed fresh from `CallTimer`.
- ✅ `GotTimeUITests` — walks the full canonical flow (pick Chris → 5 min → explicit confirm → ringing → auto-connect → countdown → automatic ending → history gains exactly one new entry). Uses a `GOTTIME_DEV_TIME_SCALE` launch-environment override for test speed, separate from the gentler default a human manually testing the app gets.

**Attempted to get a GitHub repo self-served via `gh auth login`'s device-code flow** (installs the GitHub CLI without ever needing the owner's password) — both the standard and `--scope user` install attempts stalled, most likely on a UAC consent dialog with no one able to click it in this non-interactive environment. Abandoned after a reasonable attempt rather than continuing to poll a possibly-permanently-stuck process; falling back to the owner providing repo access directly (see chat).

**None of this Swift code has been compiled yet** — there is no Swift toolchain on this dev machine (see ARCHITECTURE.md/KNOWN_LIMITATIONS.md). Every one of the 56 Swift files has been manually reviewed multiple times (import boundaries checked, brace/paren balance checked file-by-file, every test's expected values hand-traced against the implementation, a real design bug in `VoiceEvent` caught and fixed mid-build by re-reading my own code critically), but real compiler verification is still pending the GitHub repo. Phase 1 is code-complete; the acceptance bar for calling it *done* is a green `ios-ci.yml` run, not just this local review.

## Phase 2 — Authentication
⬜ Not started. 🚧 Will need: Supabase project + credentials; Apple Developer Sign-in-with-Apple Services ID (owner already enrolled in Apple Developer Program).

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
1. ~~GitHub account~~ — already had one (empty repo creation still pending)
2. ~~Apple Developer Program enrollment~~ — already enrolled

## Owner gates still ahead
See the table in the approved build plan / SETUP.md for the full list and what each requires.
