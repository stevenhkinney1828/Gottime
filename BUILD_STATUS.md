# Build Status

Last updated: 2026-08-19

**Current phase: Phase 0 — Foundation (in progress)**

Legend: ✅ done · 🔄 in progress · ⬜ not started · 🚧 blocked on owner gate

## Phase 0 — Foundation
- ✅ Git repository initialized
- ✅ Repository folder structure created
- ✅ Root documentation (README, SETUP, ARCHITECTURE, DESIGN_SYSTEM, DECISIONS, KNOWN_LIMITATIONS, BUILD_STATUS, BETA_FEEDBACK, .env.example)
- 🔄 Local tooling install (Deno done; PostgreSQL install running unusually slowly in the background — Windows Defender appears to be scanning pgAdmin's large bundled Python environment file-by-file during unpacking. Not stuck, just slow. Not blocking anything else, so the rest of Phase 0 proceeded without waiting on it.)
- ✅ `ios/project.yml` + empty App target + GotTimeCore/GotTimeMocks packages with placeholder tests
- ✅ `supabase/migrations` 0001-0006 (five tables + RLS policies) + `auth_shim.sql` + `seed.sql` — hand-verified by careful manual review twice; local Postgres dry-run and the `sql-lint.yml` CI check both still pending (see above and the GitHub gate below)
- ✅ `supabase/functions/` skeletons — `_shared/` helpers fully implemented (cors, logger, supabaseAdmin, twilioClient, apnsJwt) and unit-tested; the 7 feature functions are thin, tested stubs pending their real phase (noted in each file)
- ✅ CI workflows (`ios-ci.yml`, `backend-ci.yml`, `sql-lint.yml`) — written, cannot execute for real until a GitHub remote exists (see gate below)
- ✅ First local verification pass: `deno test`/`deno lint`/`deno fmt --check` all pass (10/10 tests) — caught and fixed two real bugs (a TypeScript BufferSource typing issue in the APNs JWT signer, and a transaction-scoping bug in the auth_shim test helpers) before they could cause silent failures later
- 🚧 **Owner gate #1 (remaining piece): an empty GitHub repository.** Owner already has a GitHub account. Once a repo exists and is connected, CI can run for real (Simulator build/test, SQL/RLS check) instead of relying on manual review alone.

## Phase 1 — Mocked UX
⬜ Not started. Full SwiftUI flow against mocks; exhaustive tests for CallStateMachine/DurationPolicy/CallTimer; backend handler logic unit-tested with fake clients.

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
