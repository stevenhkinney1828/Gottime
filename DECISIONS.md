# Decisions

A running log of implementation choices made autonomously during the build, per the master
spec's instruction to choose the simplest reliable option under normal ambiguity, record it
here, and continue rather than stopping to ask. Newest entries at the bottom. Entries are
amended in place (not deleted) if reality later contradicts the original reasoning — see the
note on empirical amendments below.

---

## 2026-08-19 — Development environment strategy: CI is the only Mac we use

**Decision:** All Swift/SwiftUI/CallKit/PushKit compilation and testing happens exclusively
on GitHub Actions `macos-latest` runners. No local Mac is used at any point in this project,
including for final signing and distribution (App Store Connect API key + TestFlight Internal
Testing, driven entirely from CI).

**Why:** The development machine is Windows 11 with no Xcode/macOS/Swift toolchain available.
The owner's only other machine (a 2010 MacBook Pro, El Capitan) was evaluated and confirmed
unusable — El Capitan's Xcode ceiling (8.2.1) predates SwiftUI by three years, and the 2010
GPU predates Metal, closing off legacy-OS-patching routes to a newer Xcode too. A cloud CI Mac
with App Store Connect API key signing avoids needing a Mac at any stage, including physical-
device distribution.

**Alternatives considered:** Local Swift toolchain for Windows (rejected — see next entry).
Asking the owner to acquire a Mac (rejected — unnecessary given the CI-based path works fully).

---

## 2026-08-19 — No local Swift toolchain on Windows

**Decision:** Do not install the Swift.org Windows toolchain locally. Rely on CI for all Swift
compilation and test execution, including for `GotTimeCore`.

**Why:** Installing it requires the multi-gigabyte Visual Studio C++/Windows SDK workload
first, and the Windows Swift/XCTest path is meaningfully less-traveled (Foundation API parity
gaps, less mature SwiftPM dependency resolution on Windows) — real risk of losing hours to
toolchain fragility that says nothing about actual device behavior. `GotTimeCore` is kept
small and dependency-free specifically so its full test suite runs in 1-3 minutes per CI push,
which makes the local-feedback-loop argument for the Windows toolchain weak at this project's
scale.

---

## 2026-08-19 — Local PostgreSQL installed for migration/RLS dry-runs

**Decision:** Install PostgreSQL locally via `winget install PostgreSQL.PostgreSQL.17` (no
Docker required) and use a hand-written `supabase/seed/auth_shim.sql` that stubs
`auth.uid()`/`auth.jwt()`/`auth.role()` to dry-run migrations and probe RLS policies as
different simulated users, before any Supabase project exists.

**Why:** Migrations and RLS policies are plain SQL with no Apple or Docker dependency, so
there's no reason to defer all verification until Supabase credentials arrive. This is
explicitly an approximation, not a substitute for a final check against the real Supabase
project — logged in [KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md) so it's never mistaken for
equivalent.

---

## 2026-08-19 — Backend hosting: Supabase Edge Functions, not a standalone service

**Decision:** All backend logic (`issue-voice-token`, `request-call`, `twiml-voice`,
`twilio-status-callback`, `call-action`, `register-device`, `expire-call-sweep`) is built as
Supabase Edge Functions (Deno/TypeScript) living in `supabase/functions/`, not as a
standalone Node/Express service.

**Why:** Every backend responsibility in the spec is a short-lived, stateless request/response
operation — nothing needs a persistent process or in-memory state, since Twilio's Voice SDK
handles media/signaling directly with Twilio's infrastructure. That workload shape is Edge
Functions' design center, and it avoids a second hosting owner-gate entirely (no Render/Fly/
Railway account, billing, or TLS to manage), directly serving the spec's "design for 100
users, optimize for 2" principle. It also co-locates secrets and gets Supabase-JWT
verification for free instead of hand-rolled auth middleware. The one requirement that needs
something to run on a schedule (duration-enforcement backstop) is solved with `pg_cron` +
`pg_net`, already part of the same Postgres instance, rather than a second server.

**Alternatives considered:** Standalone Node/TypeScript service (rejected — Node v24 is
available locally so local-testability wasn't the deciding factor, but a permanent hosting
bill/uptime concern and an extra owner-gate account isn't justified for this workload).

---

## 2026-08-19 — Xcode project defined by XcodeGen `project.yml`, never a committed `.xcodeproj`

**Decision:** `ios/project.yml` is the only checked-in project definition. CI installs
XcodeGen and runs `xcodegen generate` on every run. The generated `.xcodeproj` is gitignored
and never hand-edited.

**Why:** A hand-authored/hand-edited `.pbxproj` is fragile, prone to merge conflicts, and
can't be sanity-checked without Xcode. A declarative YAML spec is diffable, reviewable, and
regenerable — and since compilation is CI-only anyway (see above), there's no cost to
generating it fresh every run instead of committing a binary-ish project file this machine
can't validate.

---

## 2026-08-19 — Twilio product: Voice SDK + TwiML App + `<Dial><Client>`

**Decision:** App-to-app audio uses the Twilio Voice iOS SDK, backed by a TwiML Application
that responds to `twiml-voice` webhook requests with `<Dial><Client>` routing to the
recipient's Twilio Voice identity.

**Why:** This is the standard, well-documented Twilio pattern for app-to-app (not PSTN)
calling, matching the spec's "V1 is app-to-app VoIP only" requirement directly. Twilio
Conversations Relay was considered and rejected — it's built for AI/media-agent use cases, the
wrong fit here. PSTN `<Dial><Number>` is explicitly out of scope per the spec.

---

## 2026-08-19 — APNs VoIP push delivered directly, not via Twilio Notify

**Decision:** The backend calls Apple's APNs HTTP/2 provider API directly (ES256 JWT signed
with a `.p8` Auth Key) to deliver VoIP push notifications, rather than routing through Twilio
Notify.

**Why:** Direct APNs calls give full control over the CallKit-required push payload fields,
require one fewer third-party product, and keep push credentials in one secret store instead
of two.

---

## 2026-08-19 — Duration enforcement: three independent layers

**Decision:** Per spec §7's explicit instruction, no single layer is trusted alone to end a
call at zero:
1. **Primary (felt by the user):** each client computes its own expiry from the Twilio
   "connected" timestamp it observed, and calls `disconnect()` + reports CallKit end at
   exactly zero.
2. **Backend confirmation:** on receiving the status callback that marks the call in-progress,
   the backend records `connected_at` and issues a Twilio REST `Call` update tightening
   `timeLimit`.
3. **Backstop:** a `pg_cron`/`pg_net` sweep (5-10s interval) force-completes any
   `call_sessions` row past its computed expiry that Twilio hasn't already closed.

**Status: layer 2's exact semantics are provisional.** Whether updating `timeLimit` via the
REST API on an already-connected call measures the limit from the original call start or from
the moment of the update needs to be confirmed against real Twilio behavior — planned for the
Phase 4 voice-proof milestone. This entry will be amended with the observed answer once
confirmed; until then, layer 2 is implemented conservatively (assume "from call start" unless
observed otherwise) precisely because layers 1 and 3 don't depend on getting this exactly
right.

---

## 2026-08-19 — CallKit identity + duration presentation

**Decision:** Compose `CXCallUpdate.localizedCallerName` as `"Chris • 10 min"` rather than
relying on a separate subtitle field.

**Why:** CallKit doesn't reliably expose a distinct pre-unlock subtitle field across iOS
versions/lock states, so folding the duration into the single field CallKit is guaranteed to
show is the more robust choice. **Provisional — to be re-verified against real, locked
devices in Phase 5**; if truncation is observed, this entry will be amended with a shorter
fallback format.

---

## 2026-08-19 — Physical-device delivery: TestFlight Internal Testing only

**Decision:** No ad-hoc IPA/UDID provisioning at any point — every build that reaches a real
iPhone does so through TestFlight (Internal Testing during development, External once the
Phase 9 beta begins).

**Why:** It's the only distribution path fully compatible with CI-only signing (no local Mac
ever touches a build) and it's also just the right long-term mechanism for the spec's beta
rollout plan.

---

## 2026-08-19 — Twilio account tier: pay-as-you-go before first real-call test

**Decision:** Upgrade the Twilio account from trial to pay-as-you-go with a small prepaid
balance before Phase 4's first real-call test, rather than debugging against a trial account.

**Why:** Trial accounts carry audio/behavior restrictions (e.g., mandatory verification
messages, capped destinations) that would confound first-real-call debugging with noise
unrelated to the app itself. Ongoing cost at friends-and-family scale is trivial.

---

## 2026-08-19 — Git commit identity set locally, not globally

**Decision:** `git config user.email` was set at the repo level (not `--global`) to
`stevenhkinney@gmail.com`, since no email was configured anywhere on this machine and commits
require one. `user.name` ("Steven") was already set globally and was left untouched.

**Why:** Minimal, reversible, scoped only to this repository — doesn't alter the owner's
global git configuration.

---

## 2026-08-19 — Connection-invite redemption via a SECURITY DEFINER function, not table RLS

**Decision:** Redeeming a connection invite (turning an invite code into an active
`connections` row) happens through a single Postgres function,
`public.redeem_connection_invite(invite_code)`, called via Supabase RPC and running as
`SECURITY DEFINER`. There is no RLS `SELECT` policy that lets one user query another user's
`connection_invites` row directly.

**Why:** A `SELECT` policy permissive enough to let a redeemer look up an invite by its code
would, by construction, also let any authenticated user enumerate other users' invites —
directly contradicting spec §12's "do not allow arbitrary user enumeration" and "pairing/
invite codes are discovery mechanisms, not authentication." A `SECURITY DEFINER` function
scoped to exactly one safe operation (look up by exact code, validate status/expiry, create
the connection, mark the invite redeemed — all inside one transaction) avoids that trade-off
entirely while still keeping the operation itself tightly constrained.

---

## 2026-08-19 — Account deletion cascades to shared rows (connections, call history)

**Decision:** `profiles.id` references `auth.users.id` with `on delete cascade`, and every
table that references `profiles.id` (`connections`, `call_sessions`, `connection_invites`,
`device_registrations`) also cascades. Deleting a user's account therefore also removes
connections and call-history rows that the *other* participant would otherwise still see.

**Why:** The alternative — anonymizing shared rows instead of deleting them (e.g. replacing a
deleted user's id with a placeholder "deleted user" profile) — adds real schema complexity
(a synthetic profile row, nullable-FK handling throughout) for a friends-and-family-scale V1.
Simplicity wins here per the spec's stated priority order (reliability → simplicity →
polish...). Worth knowing if it's ever surprising in practice: if Steve's brother deletes his
account, Steve's call history with him disappears too, not just the brother's side of it.
