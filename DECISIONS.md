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

---

## 2026-08-19 — Added a `canceled` call status (spec §8 vs §14 reconciliation)

**Decision:** Added `canceled` as an eleventh `call_sessions.status` value, alongside the ten
listed in spec §14. `0004_call_sessions.sql`'s CHECK constraint updated before this schema
ever left local development (no remote existed yet), rather than layered on as a later
migration.

**Why:** Spec §8 (History) explicitly lists six required outcomes: "completed by timer, ended
early, declined, missed/no answer, canceled, failed." Spec §14 (Call State) lists ten
candidate states and never mentions `canceled`, and spec §16's reliability list separately
requires handling "caller cancels while ringing" as its own distinct case. None of the ten
§14 states fit that case correctly: `declined` means the *recipient* rejected it, `missed`
means the recipient's phone rang out unanswered, `failed` implies a technical fault — none of
these accurately describe the caller voluntarily withdrawing an outgoing call before it
connects. Rather than force one of those semantically-wrong states, this is a straightforward
ambiguity to resolve directly and record, per the spec's own instruction. `canceled` is
reachable from `outgoing` or `ringing` (the caller backing out at either point), is terminal,
and — like `declined`/`missed`/`failed` — never has a `connected_at`, so it's excluded from
`CallStatus.wasEverConnected` the same way they are.

---

## 2026-08-20 — GotTimeCore/GotTimeMocks Package.swift needs `.macOS(...)` too

**Decision:** Both packages' `platforms:` array now lists `.iOS(.v17), .macOS(.v14)`, not just
`.iOS(.v17)`.

**Why:** First real CI run (finally possible once the GitHub repo was connected) failed with
`'AsyncStream' is only available in macOS 10.15 or newer` inside GotTimeCore — a package that
only ships on iOS and has nothing to do with macOS. Root cause: `ios-ci.yml` runs `swift test`
directly against each package (a fast way to test the pure-logic packages without going
through the full Xcode project), and `swift test` executes natively on the CI runner's Mac,
not iOS. With no `.macOS` entry in `platforms:`, SwiftPM fell back to an old default macOS
deployment target that predates Swift Concurrency entirely, so `AsyncStream` (and everything
else concurrency-related) failed to compile — a failure with nothing to do with the actual
iOS deployment target, which was already correctly set to 17.0. `.v14` (not the `.v13` that
would minimally cover `AsyncStream` itself) was chosen with margin to also safely cover
`AsyncStream.makeStream()` and `Task.sleep(for:)`, whose exact availability floors weren't
worth re-deriving precisely when a generous, harmless-to-set-too-high value was available —
this setting only affects local/CI package testing, never the shipped iOS app, so there's no
real cost to it being higher than strictly necessary.

**Lesson for future packages:** any new pure-Swift package added to this repo that gets tested
via a direct `swift test` step in CI needs the same `.macOS(...)` entry from the start, not
just whatever platform it actually ships on.

---

## 2026-08-20 — fullScreenCover(item:) instead of fullScreenCover(isPresented: .constant(...))

**Decision:** ContentView presents IncomingCallView/ActiveCallView via `.fullScreenCover(item:)`
bound to real `Binding<...Presentation?>` values (see `ActiveCallPresentation`/
`IncomingCallPresentation` in CallCoordinator.swift), not `.fullScreenCover(isPresented:)` bound
to `.constant(coordinator.activeCall != nil)`, which is what this shipped as through the first
several CI iterations.

**Why:** The first real end-to-end CI run that got as far as actually executing
GotTimeUITests's canonical-flow test failed at exactly the point of confirming a call — the
active-call screen never appeared within an 8-second window, even though every isolated piece
(the coordinator's state updates, MockVoiceService's event emission) was independently correct
and tested. `.constant()` bindings have a no-op setter; SwiftUI's presentation coordinator for
`.fullScreenCover`/`.sheet` sometimes needs to write back to the binding it's given as part of
its own internal state tracking, and a no-op setter means that write silently goes nowhere,
which can desync the modifier's internal presented/dismissed state from the app's actual state
in a way that doesn't reliably self-correct. `.fullScreenCover(item:)` takes a real two-way
`Binding<Item?>`, avoiding this class of bug entirely.

While addressing this, also reordered DurationPickerView's confirm action to call `dismiss()`
first and start the call in a background Task second (previously the reverse) — not confirmed
as a distinct root cause, but removes a second plausible contributor (two presentation
transitions, a sheet dismissing and a fullScreenCover appearing, kicking off at nearly the same
instant) rather than leaving it as a live risk once the primary cause was already identified.

**Lesson for future views:** default to `.sheet(item:)`/`.fullScreenCover(item:)` with a real
binding for anything driven by observable model state; reach for `isPresented: .constant(...)`
only for content that's genuinely never dismissed programmatically from outside the view being
presented.

**Follow-up, same day:** the `.fullScreenCover(item:)` fix above did not resolve the failure —
GotTimeUITests still failed at the identical assertion on the next real run. Refined the fix:
`signedInGate` now reads `coordinator.activeCallPresentation`/`incomingCallPresentation` into
local `let`s at the top of the function, and the two Bindings' `get` closures return those
already-captured values rather than re-reading `coordinator` when invoked. Reasoning: an
`@Observable` type's dependency tracking is tied to property reads happening during a tracked
`body` evaluation; a read that only ever happens indirectly, inside a closure a framework
modifier invokes later on its own schedule (e.g. `.fullScreenCover` checking its binding's
current value outside the normal body-recomputation cycle), isn't guaranteed to register as a
dependency the same way a textually-direct read does. Also added a diagnostic checkpoint to
GotTimeUITests (checking for "Calling.../Ringing.../Time remaining" ~1.5s after confirming,
before the real 8s assertion) specifically so that *if* this still isn't the full story, the
next CI failure log says definitively whether the cover never presented at all versus presented
and then stalled — rather than re-guessing blind again.

**Follow-up #2, same day:** the diagnostic checkpoint fired — the active-call screen still never
appeared — and its `app.debugDescription` dump was the useful part: instead of the normal
`Element subtree:` dump of the live view hierarchy, it printed only `Query chain: →Find: Target
Application '...'` with nothing else. That format is what XCUITest prints when it cannot
resolve/snapshot the target at all, not what a healthy-but-unexpected UI state looks like — the
app was unresponsive to the accessibility protocol at that instant, not just showing the wrong
screen. Checked for an actual crash report in the same log; none found, and the routine
"Checking for crash reports" teardown line is boilerplate that runs on every test regardless.
Absence of a crash report plus total accessibility unresponsiveness points at a hang (something
blocking the main thread) rather than a crash.

Re-read `MockVoiceService` end-to-end for the specific failure mode that would cause this: an
`NSLock` held across an `await` suspension, or a re-entrant `lock()` call from code already
holding it. Found neither — every `lock()`/`unlock()` pair in the file is balanced within one
synchronous stretch, never straddling an `await`. `CallStateMachine.apply` (the other function
in this path) is a pure, synchronous, non-recursive function with no loop — not a plausible hang
source either. Concluded the code read doesn't reveal an obvious hang, so a third speculative
fix isn't justified yet.

Instead of another guess, added temporary `print("[GotTime DEBUG] ...")` tracing at every step
of the confirm path — `DurationPickerView.confirmCall()`, `CallCoordinator.call()`,
`CallCoordinator.handle(_:)`, and `MockVoiceService.startCall()` — so the next CI log shows
exactly which of these actually run and which never fire, replacing another round of blind
hypothesis-and-fix with direct evidence of where execution actually stops. These print
statements are temporary and should be removed once the root cause is confirmed and fixed — do
not mistake them for permanent logging (Phase 7 adds real structured logging).

**Follow-up #3, same day:** the print-tracing run revealed a different problem before it could
answer the original question: none of the four trace points ever appeared in the "Build and
test app + UI tests" step's log at all. They *did* appear — 46 times, clearly from the separate
"Test GotTimeMocks package" step's own `swift test` run (MockVoiceServiceTests calling
`startCall` directly, many times, each a few microseconds apart) — proving the prints work and
the log capture works in general. But zero copies came from the UI-test step specifically. Since
`swift test` runs as a plain foreground process (stdout trivially inherited by the CI step)
while `xcodebuild test` launches the app as a separate Simulator process whose stdout capture
depends on Xcode's own test-harness plumbing, this is most likely a genuine blind spot — app
stdout from *inside the Simulator* isn't reliably reaching this log — rather than proof
`confirmCall()` never runs. Treated as inconclusive, not as a finding.

Rather than chase the logging mechanism further, switched to a diagnostic channel already
proven end-to-end for exactly this scenario: XCUITest's own element queries, which every passing
assertion in this suite already depends on. Added a tiny always-present accessibility element
(`gtDebugState`, identifier-matched) via `.overlay` on `ContentView`'s root, showing
`CallCoordinator`'s live `activeCall`/`incomingCall`/`activeCallPresentation` state as plain
text — independent of whether any sheet or cover is presented, since it lives outside
`signedInGate`'s hierarchy. `GotTimeUITests` now reads its `.label` into the failure message.
This should give a direct answer: if `active=nil` at failure time, the bug is upstream (the tap
not registering, or something in the call chain not completing); if `active=connected` (or any
non-nil status) but the cover still isn't showing, the bug is purely in the
`.fullScreenCover(item:)` presentation mechanics, and the print statements + this reasoning about
log capture becomes a documented dead end, not wasted — it rules out an entire class of
hypothesis (async/lock hangs) with actual evidence rather than more reading-the-code guessing.

**Follow-up #4, same day:** the `gtDebugState` run came back with the element itself reported
as not found — but re-reading that same log surfaced a detail that changes the read on
*everything* since Follow-up #2: the individual `.exists` checks (for `gtDebugState`, and for
"How long do you have?" before it) resolve cleanly and quickly, false after three ~1s retries,
every time. A genuinely hung/unresponsive main thread would make *those* queries stall too, not
just the full-tree `debugDescription` dump. That the targeted checks keep resolving fine while
only the full-tree dump comes back as an unresolved "Query chain" now looks more like
`debugDescription`'s own snapshot mechanism being unreliable in this CI/Simulator environment —
a known rough edge, distinct from targeted element queries — than evidence the app is hung.
Treating the "hang" conclusion from Follow-up #2 as likely wrong, not confirmed.

That leaves one fact standing: `gtDebugState` itself was not found, via a clean check, not a
stalled one. Two readings remain open: either `CallCoordinator`'s state genuinely isn't what's
expected, or the diagnostic element itself is broken (font size collapsing its frame, overlay
placement, an identifier-matching mistake) — meaning its absence would prove nothing about the
real bug either way. Added an early sanity assertion right after the People list first appears
(before any interaction) that `gtDebugState` exists then; if *that* fails, the diagnostic itself
is broken and needs a different mechanism entirely, not another theory about CallCoordinator.
Also swapped the `.font(.system(size: 6))` for `.caption2` — 6pt is small enough that a
degenerate/zero layout frame excluding it from the accessibility tree was a real possibility,
and there's no reason to leave that variable in place while it's still unclear which side of
this the bug is on.

**Follow-up #5, same day:** the sanity check landed cleanly — `gtDebugState` exists right after
the People list first renders (proving the diagnostic element itself works), then goes missing
1.5s after confirming the call, alongside the already-known absence of both the duration
picker's and the active-call screen's text. Something makes the *entire* accessibility-visible
content disappear at that moment, foreground and background alike, without any of the expected
replacement content ever showing either. That pattern — plus "Unable to monitor animations"
appearing at that exact instant in every single run so far — reads much more like a presentation
*transition* that starts and never completes, than like a state update that silently fails.

That pointed back at something flagged as a real possibility during Follow-up #1 but never
actually tested: two `.fullScreenCover(item:)` modifiers chained on the same view (one for
incoming, one for active). Apple's docs suggest independent sheet/cover modifiers on one view
should coordinate fine, but this is a documented rough edge in practice, and — independent of
whether it's the actual cause here — modeling "at most one of {incoming, active} presented at
once" as two separately-toggleable optionals was never the most accurate representation of that
invariant anyway. Consolidated into a single `CallPresentation` enum
(`CallCoordinator.swift`, `.incoming`/`.active` cases) and a single `coordinator.presentation`
computed property, so `ContentView` now drives exactly one `.fullScreenCover(item:)` instead of
two. The dismiss handler switches on the *captured* pre-dismiss value (not the new, by-then-nil
one) to decide whether to call `declineIncomingCall()` or `dismissActiveCall()` — same pattern as
the existing local-`let`-capture fix from Follow-up #1, applied consistently.

Left every temporary diagnostic (print tracing, `gtDebugState`, the early sanity check) in place
for this push rather than cleaning up preemptively — if this doesn't fix it, the next failure
log needs them intact rather than starting the evidence-gathering over a third time.

**Follow-up #6, same day:** the consolidated single-cover fix (#5) failed identically —
`gtDebugState` still not found, same empty `debugDescription`. Three different presentation-API
shapes (`isPresented: .constant`, two chained `.fullScreenCover(item:)`, one consolidated
`.fullScreenCover(item:)`) now all fail the exact same way, which means the bug was never about
*which* presentation API or binding pattern is used — that entire line of investigation was
looking in the wrong place.

Re-examined the actual sequencing instead. `DurationPickerView.confirmCall()` calls `dismiss()`
then spawns `Task { await coordinator.call(...) }`. The intent (documented in the very comment
this replaces) was for the sheet to fully close before the call starts. But `await` only
actually suspends a Task if the callee hits a real suspension point, and
`MockVoiceService.startCall`'s body has none — it's pure synchronous code (lock/unlock, struct
construction, an `AsyncStream` yield, spawning-but-not-awaiting a child task) with no `await`
anywhere in it. So `Task { await coordinator.call(...) }` can run to completion on the very next
run-loop turn, which sets `activeCall` and flips `coordinator.presentation` to `.active(...)`
often *before* the sheet's own dismiss animation has actually finished — not just been
requested. That's a real race between the sheet's dismiss transition and the cover's present
transition, and it explains why every presentation-API variant failed identically: none of them
touched when the second transition starts relative to the first one completing.

Restructured so starting the call is decoupled from confirming the duration.
`DurationPickerView` no longer holds a `CallCoordinator` reference or calls `.call()` at all; it
takes an `onConfirm: (Int) -> Void` closure, calls it with the resolved duration, then dismisses.
`PeopleListView` (which presents `DurationPickerView` via `.sheet(item:)`) now holds the pending
`(person, durationSeconds)` in `onConfirm`, and only starts `coordinator.call(...)` from that
sheet's `onDismiss` callback — which SwiftUI guarantees fires once the dismissal has actually
completed, not merely been requested. This removes the race structurally rather than papering
over it with an arbitrary delay.

**Follow-up #7, same day:** the `onDismiss`-based sequencing fix (#6) also failed identically —
byte-for-byte the same failure text, same empty `debugDescription`. That's four structurally
different fixes (`isPresented: .constant`, two chained `.fullScreenCover(item:)`, one
consolidated cover, and now correct dismiss-then-present sequencing via `onDismiss`) all failing
the exact same way. That pattern means the bug was never in any of the things being changed —
every attempt so far adjusted *which* modal-presentation API or *when* it fires, and none of
that mattered.

Also recognized a flaw in the `gtDebugState` diagnostic itself: it lived in a `.overlay` on
`ContentView`'s root, *underneath* wherever `.fullScreenCover` presents its content — so it was
always hidden the instant *anything* was presented, cover working correctly or not. Its "not
found" result across every run was never actually informative about which side of the bug it
was on; it could only ever confirm "something is covering the screen," not distinguish a
correctly-showing cover from a stuck one. That undercuts the "stuck transition" reasoning from
Follow-up #5 more than it supports it — the evidence for a hang/stuck-transition was thinner
than it looked at the time.

Stopped adjusting the presentation mechanism's timing/shape and questioned the mechanism itself.
Replaced `.fullScreenCover(item:)` entirely with a plain `ZStack` overlay in `ContentView`:
`callOverlay(coordinator:)` switches on `coordinator.presentation` and renders `IncomingCallView`
or `ActiveCallView` directly as a top ZStack layer, with no UIKit modal presentation involved at
all — just ordinary SwiftUI view composition, which has no transition-animation-coordination
layer to race against or get stuck in. This isn't a workaround so much as removing a dependency
this app never actually needed: swipe-to-dismiss was already disabled on every call screen
(`.interactiveDismissDisabled()`, now removed as dead code along with it), so the "real modal"
semantics `.fullScreenCover` provides over a plain overlay were never being used. Both explicit
dismissal paths (`dismissActiveCall()` from the "Done"/"Call Again" buttons,
`declineIncomingCall()` from the decline button) already call `CallCoordinator` directly and
never went through the cover's dismiss-binding `set` closure, so removing it costs nothing
functionally.

Moved `gtDebugState` to be the topmost ZStack layer (with `.allowsHitTesting(false)` so it can't
intercept real taps) instead of sitting underneath the presented content — in this architecture
it now stays queryable regardless of what `callOverlay` is showing, which finally makes its
result actually diagnostic if this still doesn't fix it.

**Resolution, same day:** the ZStack rewrite fixed it. `testCanonicalFlow_...` got all the way
through confirm, ringing, connect, the live countdown, automatic termination, and "Done" for the
first time — five presentation-mechanism attempts in (`.constant`, two chained covers, one
consolidated cover, `onDismiss` sequencing, and finally no modal presentation at all), it was the
removal of UIKit modal-presentation coordination itself that mattered, not any adjustment within
it. The specific reason a plain ZStack succeeds where every `.fullScreenCover`/`.sheet` variant
failed identically was never fully isolated (Simulator/CI-specific animation handling being the
leading suspect, per how consistently "Unable to monitor animations" showed up at the exact same
moment across every failing run) — but five independent data points now agree on effect even
without a fully traced cause, and the fix is also a legitimate simplification on its own terms,
not just a workaround: this app never used real-modal semantics, and the ZStack overlay is fewer
moving parts than what it replaced.

That fix uncovered a second, unrelated, much smaller bug: the history-count assertion expected 7
rows and got 9. Root cause: `app.cells.count` is unscoped — it walks the *entire* app element
tree, not just the visible screen, and picked up `PeopleListView`'s own 2 rows (Chris, Jordan)
even while visually covered by the History sheet (2 extra = 9 - 7, an exact match). This
assertion had never been reached before today, since the test always failed earlier at the
active-call screen — it was latent, not a regression from anything today's fixes touched. Fixed
by giving History's `List` an explicit `.accessibilityIdentifier("historyList")` and scoping the
test's query to that element specifically, rather than the unscoped `app.cells`.

Removed all temporary diagnostics added across Follow-ups #3-#7 now that the root cause is
confirmed fixed: the `print("[GotTime DEBUG] ...")` tracing in `CallCoordinator`/
`MockVoiceService`, the `gtDebugState` accessibility element and its supporting doc comments in
`ContentView`, and the 1.5s-sleep/manual-exists-check/`debugDescription`-dump diagnostic block in
`GotTimeUITests` (restored to a plain `waitForExistence` on "Time remaining", matching the rest
of the test's style). Also removed `.interactiveDismissDisabled()` from `ActiveCallView`/
`IncomingCallView` (dead code once neither is presented modally) and corrected
`CallCoordinator.swift`'s now-inaccurate doc comment, which still described the
`.fullScreenCover(item:)` rationale after the code had moved away from it.

**Lesson for future debugging sessions:** when several structurally different fixes to the same
mechanism all fail in byte-for-byte identical ways, that repetition is itself the signal — it
means the mechanism being adjusted isn't where the bug lives, even when each individual fix is
well-reasoned. The break came from questioning whether `.fullScreenCover` should be used at all,
not from a better theory about how to use it.

## Phase 2: real Supabase wiring

**Client-safe config is committed directly, not gitignored.** `ios/Config/AppConfig.xcconfig`
holds the real `SUPABASE_PROJECT_REF` and the "publishable" (formerly "anon") key in plaintext,
checked into git. This looks wrong at first glance next to `.env`'s gitignored secrets, but the
two values here are categorically different from `SUPABASE_SERVICE_ROLE_KEY`: Supabase's own
dashboard labels the publishable key safe to share publicly, and the real security boundary is
Row Level Security on the database (every migration since Phase 0), not keeping this value
hidden — a shipped `.ipa` embeds it either way, so gitignoring it would only hide it from the
repo, not from anyone who actually has the app. The service_role/secret key never appears
anywhere under `ios/` — it stays in the root `.env` and, later, GitHub Actions secrets.

**Stored as a bare project ref, not a full `https://` URL.** xcconfig treats `//` as a comment
marker even inside a quoted value, which would silently truncate a URL value at the scheme.
`SupabaseClientFactory` builds the full URL from the ref at runtime instead of storing one
pre-built — sidesteps the escaping question entirely rather than fighting it.

**Mock by default in Debug, always-live in Release** (`GotTimeApp.swift`). The owner has no
Mac/Xcode and will only ever receive this app via TestFlight, which builds the Release
configuration — a scheme-level environment-variable override (the first design considered)
would never be reachable from a real install, silently leaving a shipped build talking to fake
data forever. Release always uses `.live()`; Debug (what `ios-ci.yml`'s Simulator job and
GotTimeUITests run) defaults to `.mock()` so the now-passing canonical-flow test and Xcode
Previews are untouched, with `GOTTIME_USE_LIVE_BACKEND=1` as a scheme opt-in for manual testing
once Xcode is available to someone.

**`AppEnvironment.live()` mixes real auth with still-mocked everything else.** Only
`authService` graduates to `SupabaseAuthAdapter` this phase; `connectionService`/`voiceService`/
`callHistoryService`/`pushService` still come from a fresh `MockEnvironment()`. Each service
graduates independently as its own phase lands (Phase 3 connections, Phase 4 voice, Phase 5
push) — `AppEnvironment`'s five-service shape means this was always the expected incremental
path, not a stopgap.

**`Supabase` umbrella SPM product, not the standalone `Auth` library.** Phase 3 needs
`PostgREST` within the next phase or two for the same client instance (querying
`connections`/`profiles` directly), and the umbrella product's single shared `SupabaseClient` is
the actually-idiomatic way to use this SDK — separate standalone clients per capability are
meant for dependency-footprint-critical consumers, which this app isn't. Pulling in the fuller
product now avoids a near-term second `project.yml` edit for the same package.

**Every Supabase Swift SDK method signature used here was checked against the actual v2.55.1
source on GitHub before writing code that calls it** (`gh api repos/supabase/supabase-swift/...`
against `Sources/Auth/`, `Sources/PostgREST/`, `Sources/Functions/`), not written from
recollection — a wrong method name or parameter label would only surface after a full CI round
trip, the same expensive feedback loop the whole debugging session above just went through for a
different reason. Confirmed: `SupabaseClient(supabaseURL:supabaseKey:)`,
`auth.signInWithIdToken(credentials: OpenIDConnectCredentials)`, `auth.authStateChanges`
(`AsyncStream<(event: AuthChangeEvent, session: Session?)>`), `from(_:).select().eq().single()
.execute().value` (PostgREST), `functions.invoke(_:)`. Also confirmed the package's own minimum
platforms (iOS 16/macOS 13, both below this project's iOS 17/macOS 14 floors) and
swift-tools-version (6.1, comfortably under the CI runner's Xcode 26.6).

**`SupabaseAuthAdapter` re-fetches the `profiles` row on every auth-state transition** rather
than trusting the name Apple/Supabase cache in session or user metadata — `profiles.first_name`
is this app's single source of truth (mutable via `updateFirstName`), and metadata would go
stale the first time that's called. Apple only ever supplies the user's given name on the very
first authorization for a given Apple ID, never again on subsequent sign-ins, so
`signInWithApple()` writes it into `profiles` immediately when present, as a more reliable path
than depending solely on `handle_new_user()`'s trigger-time read of `raw_user_meta_data` (0001)
surviving the id-token exchange.

**Account deletion needed a new Edge Function, not just an adapter method** — deleting an
`auth.users` row is admin/service-role-only, something the client's own key structurally cannot
do under RLS. Added `supabase/functions/delete-account/` following the same
dependency-injected-logic-plus-thin-HTTP-wrapper pattern as `request-call`/`call-action`
(`logic.ts` takes the acting user's *own* verified ID, never a client-supplied one, so this can
only ever delete the account making the request) — tested locally (`deno test`/`lint`/`fmt`, all
clean) the same way those were before ever depending on a live project.

**Supabase's Apple-provider "Secret Key (for OAuth)" field wants a signed JWT, not the raw
`.p8` file contents** — this only became clear from the owner's screenshot of the actual current
form, which has a single "Secret Key" field rather than the separate Team ID/Key ID/Private Key
inputs an earlier (incorrect) instruction assumed. Apple's Sign-in-with-Apple OAuth client
secret is itself a short-lived-by-design ES256 JWT (`iss` = Team ID, `sub` = the client/bundle
ID, `aud` = `https://appleid.apple.com`, `exp` ≤ 6 months from `iat`) that has to be generated,
not typed in. Rather than walking a non-technical owner through generating a JWT by hand,
reused the exact ES256-signing approach already written and tested for APNs
(`supabase/functions/_shared/apnsJwt.ts`) in a one-off local script, then handed over just the
resulting token string to paste into that one field. Verified correctness two ways before
handing it over: decoded the JWT's own payload to confirm the claims, and — after the owner
saved it — issued a real `/auth/v1/authorize?provider=apple` request against the live project
and confirmed it 302-redirects to `appleid.apple.com` with the right `client_id`, which only
happens if the App ID, the Supabase provider config, and this secret are all correctly wired
together. Set to expire 2027-02-19 (Apple's 6-month maximum) — needs regenerating before then,
the same way the APNs provider token pattern already documents needing periodic rotation.

**Verified all 3 owner setup steps directly against the real project rather than trusting the
owner's "done" at face value** — matches the same discipline used throughout Phase 0/1 (checking
CI results rather than assuming code compiles, checking `git status` rather than assuming a
commit succeeded). Confirmed the 5 tables exist, RLS is actually enforcing (not just present:
an anon-key request against `profiles` returns `[]`, not real rows or an error), and the Apple
OAuth wiring works end to end, all via direct API calls — the only thing left genuinely
unverifiable without a physical device is a real human tapping "Sign in with Apple" and
completing it, which needs Phase 4's signed build to even attempt.

## Phase 3: real Connections wiring

**Promoted invite-code generation to `GotTimeCore.InviteCodeGenerator`, out of
`MockConnectionService`.** `SupabaseConnectionAdapter` needs the exact same code-generation
logic the mock already had (a 6-character code from an alphabet that excludes visually
ambiguous characters — I/O/0/1), since the database has no server-side default for
`invite_code`; the client always supplies it. This is genuine duplication across two real,
concrete call sites, not a speculative "might need this later" abstraction, so sharing it was
the right call rather than three near-identical lines in each adapter.

**`fetchConnections()` does two round-trips (connections, then profiles), not one PostgREST
embed query.** PostgREST can embed both `user_a`/`user_b` profile relationships in one request,
but only by naming the underlying foreign-key constraints explicitly
(`connections_user_a_id_fkey`/`connections_user_b_id_fkey`), which is implicit, easy to silently
break on a future migration change, and saves one round trip for a screen that's realistically
never fetching more than a handful of rows. Two simple, robust queries over one fragile, faster
one.

**`createInvite()` retries only on an actual Postgres unique_violation (`PostgrestError.code ==
"23505"`), up to 3 attempts, and re-throws the real error explicitly on the final failure**
rather than letting it propagate past the loop implicitly (an earlier draft's `where` guard
would have let that happen accidentally instead of on purpose — same category of bug as the
`AuthChangeEvent` switch gap: verify what actually happens on every branch, not just the happy
one). A genuine `invite_code` collision is astronomically unlikely at this app's scale
(32^6 possible codes) but is a real, if rare, failure mode worth handling at this specific
system boundary; any other error (network, permissions, anything else) propagates immediately
on the first attempt, since retrying wouldn't fix it and retrying blindly would mask it.

**`ProfileRow` (originally private to `SupabaseAuthAdapter`) is now internal, shared with
`SupabaseConnectionAdapter`** — both need to decode the exact same `profiles` row shape when
resolving a connection's other participant, and duplicating a 4-field DTO across two files
would just be copy-paste risk with no offsetting benefit.

**Every new PostgREST method used here (`in(_:values:)`'s escaped-keyword name, `rpc(_:params:)`,
`insert(_:)`, the `PostgrestFilterablePhase: PostgrestTransformablePhase` conformance chain that
makes `.single()` available after `.rpc(...)`) was checked against the v2.55.1 source before
writing code against it** — same discipline as Phase 2, for the same reason: a wrong signature
here only surfaces after a full CI round trip.

**Verified the whole connection/invite security model live, via `backend/scripts/
verify-connections-rls.ts`, not just by reading the RLS policies again.** Follows the build
plan's own instruction for this phase exactly: three throwaway users created through the Admin
API (no real Apple ID needed), run through the actual flow as real authenticated HTTP requests
against the real project — Alice creates an invite, Bob redeems it, both can then see each
other's profile, a third unconnected user (Carol) can see neither profile and zero connections,
redeeming an already-redeemed code fails, and redeeming your own invite fails. All 8 checks
passed on the first real run; all three throwaway users were deleted afterward and their
removal was independently confirmed via a follow-up Admin API listing, not assumed from the
script's own exit code. Kept as a committed, re-runnable script (not a scratchpad one-off)
specifically so it can be run again after any future change to `connections`/
`connection_invites` RLS to confirm the *deployed* project — not just the migration files —
still behaves correctly; not wired into CI as an automated gate yet, since that would need
Supabase secrets added to GitHub Actions and failure-safe cleanup guarantees beyond what a
manually-invoked local script needs, which is a separate, larger decision than this phase's
sign-off required.

## Phase 4 prep: Edge Function logic built ahead of the Twilio owner gate

Real Twilio credentials, two physical iPhones, and an App Store Connect API key are all still
needed before this phase's actual voice proof can happen — but `issue-voice-token`,
`twiml-voice`, and `twilio-status-callback`'s own request-validation/response-shaping logic
doesn't need any of those to be written and unit-tested, the same way `request-call`/
`call-action` were built and tested before a real Supabase project existed (Phase 0/1). Built all
three now rather than waiting, matching the "finish everything else possible" instruction.

**Every protocol detail was checked against Twilio's current docs via WebFetch before writing
code against it** — same discipline as the Supabase SDK verification, and for the same reason:
a wrong assumption here would only surface once real devices are involved in Phase 4, a far more
expensive feedback loop than a CI round trip. This caught two real mistakes before they became
code:
- The Access Token JWT structure (header `cty: "twilio-fpa;v=1"`, `grants.identity`,
  `grants.voice.outgoing.application_sid`) matched what I'd have written from memory, but was
  worth confirming exactly rather than assuming.
- I initially conflated two different Twilio status vocabularies. The `<Client>` noun's own
  `statusCallbackEvent` (what this app actually uses, since the recipient leg is a `<Client>`
  inside `<Dial>`) only fires `initiated`/`ringing`/`answered`/`completed` — narrower than the
  general Call resource's `queued`/`ringing`/`in-progress`/`completed`/`busy`/`failed`/
  `no-answer`/`canceled` I'd originally designed `twilio-status-callback`'s logic around. Would
  have shipped a mapping function that silently never matched half its own cases.
- `<Parameter>` inside `<Client>` only reaches the Voice SDK client instance on the *receiving*
  end (`TVOCallInvite.customParameters` on iOS) — it is never delivered to a server-side
  webhook. `twilio-status-callback` therefore can't learn which `call_sessions` row a status
  event belongs to from the request body at all; the standard, Twilio-confirmed pattern is
  embedding the id in the `statusCallback` URL's own query string instead (`?call_session_id=`),
  which `twiml-voice` constructs dynamically per call. Read literally, my first mental model
  would have shipped a webhook that could never correlate its events to anything.

**`twiml-voice` verifies the caller's Twilio identity before trusting the client-supplied
`callSessionId`.** Twilio Voice SDK calls always present the caller's own identity as
`From: client:<identity>` for an app-to-app call (confirmed via the same doc check) — a fact
this webhook gets for free and checks against the session's `caller_id` before routing. Without
this, a client could supply *any* call_session_id string as its outgoing `params` and have this
webhook dial on that session's behalf; the practical blast radius is narrow (Twilio's own 1:1
call routing means this couldn't be used to eavesdrop on a call in progress), but it's a real,
cheaply-closed gap, not a hypothetical one.

**`twilio-status-callback` deliberately treats Twilio's "completed" event as a no-op for now.**
Distinguishing "a participant hung up early" from "the timer reached zero exactly on schedule"
needs the full duration-enforcement design this project has already deferred to Phase 6 (three
independent layers: client-side disconnect, backend `timeLimit` tightening, cron sweep backstop)
— a single terminal webhook event can't carry that distinction by itself, and guessing here would
risk silently mislabeling history entries later. `call-action`'s existing `endActiveCall` (client-
initiated, already built) already records `ended_early` correctly today; "completed" gets handled
properly once Phase 6 actually builds the rest of that design, not before.

**Status transitions apply via a `WHERE status IN (...)` guard, not application-side ordering
logic or timestamp `COALESCE`s.** A duplicate or late-arriving webhook (Twilio retries ones that
don't respond quickly) simply matches zero rows once the session has already moved past that
point — idempotent by construction, not by an extra check. Pushing this into the SQL update's own
WHERE clause is simpler and more robust than tracking allowed-transition state in TypeScript.

**`functionSkeletons_test.ts` updated to drop the three graduated functions**, matching the
file's own stated convention (`request-call`/`call-action` did the same in Phase 0/1) — each
function's own new test file (`issueVoiceToken_test.ts`, `twimlVoice_test.ts`,
`twilioStatusCallback_test.ts`) is now the real coverage.

## First real backend deploy: all 8 Edge Functions live, and a genuine config.toml bug found

With real Twilio credentials in hand and a Supabase personal access token (a new, distinct
credential from the project-level keys — needed because deploying code is an account-level
Management API operation, not something a project's own anon/service_role key can authorize),
ran `npx supabase functions deploy` for the first time against the real project. Confirmed
first, directly, that nothing had ever actually been deployed before this (every function
returned 404 from the real project's URL) — Phase 0-3 work had only ever been verified via
local `deno test` and the mocked/real-database-but-no-Edge-Functions paths (Phase 3's
connections work talks to PostgREST/RPC directly, never through an Edge Function; Phase 2's
`delete-account` was written and unit-tested but never actually reachable until now).

**Found and fixed a real bug in `supabase/config.toml`, unrelated to anything built this
session** — it dated back to Phase 0. Two separate problems, both only surfacing once a real
deploy was attempted for the first time:
1. `project_id` was still the literal placeholder string (`"REPLACE_WITH_REAL_PROJECT_REF"`)
   from Phase 0 scaffolding, never updated once the real project existed in Phase 2. Nothing
   Phase 2 or 3 needed a deploy, so nothing exercised this until now.
2. The `[functions]` section used a global `verify_jwt = true` — a schema the local CLI's `list`
   command tolerated silently but `deploy` (2.x) rejects; the current schema requires one
   `[functions.<name>]` sub-table per function (confirmed against Supabase's own current CLI
   config reference before changing anything, same discipline as everywhere else this session).
   Both problems produced the identical, unhelpful `"ProjectConfigParseError"` with no
   indication which section was wrong — resolved by bisecting the file section by section
   against a real `deploy` call (not just `list`, which doesn't exercise the same code path)
   until the exact culprit was isolated, rather than guessing.

**Also removed `[api]`/`[db]`/`[studio]`/`[auth]`/`[auth.external.apple]`/`[edge_runtime]`
entirely, not just fixed them.** These configure the local Docker emulator (`supabase start`),
which this project has never used and, per KNOWN_LIMITATIONS.md, deliberately doesn't (local
verification uses plain winget Postgres + `auth_shim.sql` instead). `functions deploy` sends the
*whole* config file to Supabase's hosted config parser, which is stricter than the local CLI and
rejected something in this dead configuration with the same opaque error — genuinely-unused
sections were actively breaking a real, needed capability. Deleting them fixed the immediate bug
and removed configuration nothing in this project's actual workflow ever reads.

**Verified the deployed functions directly, not just trusted the CLI's "Deployed Functions"
message** — re-ran the same 404 check from before (now returning 401 for the four
authenticated functions, correctly rejecting a service-role key used as if it were a user
session, and 501 for the two still-genuinely-unimplemented stubs) and separately confirmed
`twiml-voice`/`twilio-status-callback` with realistic form-encoded input (an initial test with
an empty body got a 500, which was the test's own fault, not a real bug — `req.formData()` on
truly empty input throws; real Twilio requests always send real form data).

## TwiML Application created; Twilio secrets set; whole voice-token pipeline verified live

Confirmed with the owner, before spending their money, that the free trial genuinely cannot
work for this app specifically: Twilio's own trial-limitations docs list `<Dial><Client>` —
the exact mechanism this app's entire app-to-app calling design depends on — as a blocked verb
combination, stripped and replaced with a spoken "not available on trial accounts" message.
Checked before advising, not assumed; a wrong guess here would have wasted real money or
real debugging time discovering it the hard way during device testing.

**`backend/scripts/twilio-setup.ts`** creates the TwiML Application via Twilio's REST API
(reusing the existing `_shared/twilioClient.ts` helper) rather than the console, and is
idempotent — it lists existing Applications first and reuses one matching by `FriendlyName`
instead of creating a duplicate on a second run, updating its Voice URL if that's changed
rather than silently leaving it stale.

**Only the four Twilio values were set as Supabase Edge Function secrets, not the whole `.env`
file** despite `supabase secrets set --env-file` being one command away. That file also holds
things with no business being exposed to Edge Function runtime code — the local Postgres URL,
the Supabase *account-level* access token (a much more powerful, differently-scoped credential
than anything a function itself should ever hold), and still-empty placeholders for later
phases. `SUPABASE_URL`/`SUPABASE_ANON_KEY`/`SUPABASE_SERVICE_ROLE_KEY` didn't need setting at
all — confirmed from the earlier 401s (not 500s) on `request-call`/etc. that Supabase already
auto-injects these into every function's environment.

**Verified the entire pipeline live, not just that each piece deployed without error**: created
one more throwaway user (same Admin API pattern as `verify-connections-rls.ts`), signed in for
a real access token, called the live `issue-voice-token` function, and got back a genuine
Twilio Voice Access Token — decodable, correctly identity-scoped to that user, carrying the
real TwiML Application SID — before cleaning the test user up. This is the same "verify against
reality, don't trust a success message" discipline applied throughout this session, just
extended one level further: past "does it deploy" to "does a real call through it produce a
correct result."

**Found and fixed a second real gap the same way, in `request-call`**, ahead of building the
Swift adapter that will actually consume its response: `CallSessionRecord`'s `.select(...)`
only ever asked for `id, call_uuid, caller_id, recipient_id, requested_duration_seconds,
status` — enough for the Phase 1 tests that only checked those specific fields, but missing
`initiated_at`/`created_at`/`updated_at`, which the Swift `CallSession` struct requires as
non-optional. Nothing before now ever decoded this response into a real `CallSession`, so
nothing caught the gap. Added the three fields to the select, the TypeScript interface, and
the test fixture; redeployed; verified live with two connected throwaway users that the real
response now includes correctly-formatted ISO 8601 timestamps for all three. (The other
lifecycle timestamps — `ringingAt`/`connectedAt`/etc. — are correctly absent from a
freshly-created session and don't need to appear in the payload at all: Swift's synthesized
`Decodable` treats a missing key for an `Optional` property as `nil` without erroring, so
there was nothing to fix there.)

## TwilioVoiceAdapter built; voiceService graduates to live

**`ios/App/Integrations/TwilioVoiceAdapter.swift`** implements `VoiceService` against the real
Twilio Voice iOS SDK (added as an SPM dependency, `https://github.com/twilio/twilio-voice-ios`
`from: 6.13.0`, product `TwilioVoice` — version and product name confirmed against the SDK's
own `Package.swift` before adding it, same discipline as every other dependency this session).
`startCall` calls `request-call` first (server-side authorization/duration validation, never
trusting its own inputs, per spec §13), then `issue-voice-token` for a fresh Access Token, then
connects through `TwilioVoiceSDK.connect`, embedding the session id as the outgoing call's
`callSessionId` param — the same id `twiml-voice` already reads to route the call. Every
`CallDelegate` callback funnels through `CallStateMachine.apply`, the same transition rules
`MockVoiceService` already uses, so there is exactly one source of truth for which state
transitions are valid regardless of which adapter is active.

`answer`/`decline` operate on a `pendingInvite`, populated by a plain `handleIncomingCallInvite`
method — not called from anywhere yet, since receiving a real `CallInvite` at all requires a
VoIP push, which needs `PushKitAdapter`/PushKit registration (Phase 5, already a distinct
protocol — confirmed by re-reading `PushService.swift` before starting this file, which is what
confirmed this adapter's scope doesn't need to expand to cover it). The adapter is structurally
complete and correct today regardless; nothing here needs to change once PushKitAdapter starts
feeding it real invites.

**Explicitly passes a custom decoder to the `request-call` `invoke()` call, rather than relying
on `FunctionsClient`'s default.** Checked `FunctionsClient.swift`'s actual source before trusting
this: unlike `PostgrestClient`, whose default decoder has a custom ISO 8601
`dateDecodingStrategy` (why every `Date` field decoded correctly in `SupabaseAuthAdapter`/
`SupabaseConnectionAdapter` without any special handling), `FunctionsClient`'s own default is a
bare, unconfigured `JSONDecoder()`. Passed as-is, `CallSessionRow`'s three `Date` fields
(`initiatedAt`/`createdAt`/`updatedAt` — the exact ones just fixed server-side in the entry
above) would have failed to decode the first time this path actually ran, on a real device, the
most expensive possible point to discover it. Confirmed the fix against the real signature
(`invoke<T: Decodable>(_:options:decoder:)`, `decoder: JSONDecoder? = nil` defaulting to
`self.decoder`) before relying on it. The custom decoder handles Postgres's timestamptz output
both with and without fractional seconds, matching what a real `request-call` response was
observed to actually contain (`"...2026-08-21T02:03:47.681663+00:00"`) rather than assuming one
specific format.

**`callDidDisconnect` distinguishes a real error/pre-connection drop (`.failed`) from a clean
hangup after connecting (`.endedEarly`)**, but deliberately does not attempt to distinguish "hung
up early" from "reached zero exactly on schedule" — same reasoning as
`twilio-status-callback`'s "completed" no-op above: that distinction needs Phase 6's full
duration-enforcement design. If this adapter's own timer already drove a session to `.timedOut`
before Twilio's disconnect callback arrives, `CallStateMachine.apply`'s existing transition
rules simply reject the late, now-invalid `.endedEarly` attempt on a terminal session — so
nothing here can accidentally overwrite a correct `.timedOut` outcome with an incorrect one.

**`AppEnvironment.live()` now constructs `TwilioVoiceAdapter(client:)` for `voiceService`**,
graduating it alongside the already-live `authService`/`connectionService`; `callHistoryService`/
`pushService` remain mocked until Phase 5 for the same PushKit-dependency reason above. Debug
still defaults to `.mock()` (GotTimeUITests' canonical-flow test is unaffected by this
graduation by design), the same Release-always-live/Debug-opt-in split established in Phase 2.

**Confirmed via a real `ios-ci.yml` run, not just the read-through above**: the new Twilio Voice
SDK SPM package (a binary XCFramework) resolves cleanly, the whole App target compiles with
`TwilioVoiceAdapter.swift` included, and GotTimeUITests' mocked canonical-flow test still passes
unchanged. The signing job's existing secret-existence guard correctly no-op'd its archive step,
exactly as designed since Phase 0 — no Apple signing credentials exist yet.

## `sign-and-upload` job implemented ahead of the App Store Connect owner gate

With `TwilioVoiceAdapter` done, the only Phase 4 work left is entirely gated on two things only
the owner can supply (two physical iPhones; an App Store Connect API key + Internal Testing
group). Rather than leave `ios-ci.yml`'s `sign-and-upload` job as the Phase 0 stub (`exit 1`)
until that gate clears, implemented it now — archive → export → upload to TestFlight, driven
entirely by an App Store Connect API key (no manually-exported `.p12` certificate, no
Keychain Access, no local Mac ever touches a signing identity, consistent with the CI-is-the-
only-Mac decision at the top of this file).

**This is a genuinely different category of "done" than everything else built this session.**
Every other piece of ahead-of-the-gate work (the Twilio Edge Functions before real Twilio
credentials existed, the whole Phase 0-3 backend) had a local or fake-credentialed way to
actually execute and test the logic before the real gate cleared. There is no equivalent for
`xcodebuild` signing flags: no fake certificate authority stands in for Apple's real one, and a
real App Store Connect API key is the only thing that can ever exercise this code path at all.
So unlike every ✅ elsewhere in BUILD_STATUS.md, this is recorded as written-and-verified-on-paper,
not verified-by-running — flagged explicitly rather than glossed over, and expected to need at
least one real iteration once the owner's credentials make a real run possible for the first time.

**What was verified, precisely, before writing it:**
- Every `xcodebuild` flag (`-authenticationKeyPath`/`-authenticationKeyID`/
  `-authenticationKeyIssuerID`, `-allowProvisioningUpdates`) against Apple's own current
  `xcodebuild` man page text directly, not a summary of it.
- The `exportOptionsPlist` schema (`destination: upload` — exports *and* uploads to TestFlight
  in one step, no separate `altool`/Transporter call needed; `signingStyle: automatic`;
  `teamID`) against multiple cross-corroborated current sources.
- A real, current conflict resolved with evidence rather than picked arbitrarily: `method` must
  be `app-store-connect`, not the older `app-store` value — confirmed via a real Flutter GitHub
  issue quoting Xcode's own deprecation warning text (`app-store` was deprecated in favor of
  `app-store-connect` around Xcode 15), not just one blog's say-so.
- The `AuthKey_<key ID>.p8` naming convention — but rather than lean on xcodebuild's own default
  search directories for that file, this passes its full path explicitly via
  `-authenticationKeyPath`, sidestepping any question of whether this job's environment matches
  an assumed default search order.
- **Caught and fixed a real mistake in my own first draft, with a parser, not just a re-read**:
  an initial pass "fixed" the exported plist's heredoc to be flush-left (worried indentation
  before `<?xml` might upset a strict parser), which actually breaks the *YAML*, since a block
  scalar's (`run: |`) content must stay indented at or above its first line's level or the
  scalar terminates early — a lesser indentation ends the block right there, silently producing
  a malformed workflow file. Loaded the file with a real YAML library (`js-yaml`, via Deno) and
  confirmed YAML block scalars already strip the *common* leading indentation before the string
  ever becomes shell-script content — so the original, consistently-indented version was correct
  all along, and writes a properly flush-left `<?xml` line to disk with no fix needed. Also ran
  `actionlint` (which embeds `shellcheck`) against every workflow file in the repo — zero
  findings — as one more real check beyond eyeballing the YAML a second time.
- `CODE_SIGN_STYLE`/`CODE_SIGNING_*`/`DEVELOPMENT_TEAM` are passed as `xcodebuild` command-line
  build-setting overrides, not written into `project.yml` itself — the checked-in project
  deliberately disables signing at the project level so the always-running Simulator job never
  needs a signing identity (see the Xcode-project-defined-by-XcodeGen entry above); this job
  overrides those settings for its own archive step only, exactly as that entry's original
  reasoning already anticipated it would need to.

**Also added `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: NO`** to `project.yml` while in
there — declares the standard-HTTPS-only export-compliance exemption up front (accurate: every
network dependency here — Supabase, Twilio, APNs — is system `URLSession`/TLS, nothing custom),
so App Store Connect never interrupts a future build with the "does your app use encryption"
prompt. Small, harmless to set now regardless of when the signing gate clears, and removes a
recurring per-build friction point before it can ever happen.

**Dropped the `IOS_BUNDLE_ID` secret the original Phase 0 stub comment guessed would be
needed.** The bundle identifier is already fully specified in `project.yml`
(`PRODUCT_BUNDLE_IDENTIFIER: com.stevenkinney.gottime`) — a project file already checked into
git is the single source of truth for it, and a redundant CI secret duplicating an
already-known, non-secret value would be pure surface area for the two to drift apart.

**SETUP.md recommends the API key's "App Manager" role, not "Developer."** Checked this
specifically rather than picking the obviously-narrower-sounding option: Developer can create
builds but explicitly cannot manage TestFlight testers or submit for external review, both of
which Phase 9's beta rollout will need. App Manager covers both from the start, avoiding a
second key-creation walkthrough later just to widen its permissions.

**Caught a real, necessary sequencing step before writing the owner instructions**: an App
Store Connect *app record* (Apps → + → New App, choosing the already-registered bundle ID) has
to be created manually, once, before any CI upload can succeed — confirmed via multiple
independent reports of the exact failure ("no suitable application records were found")
CI would hit otherwise. This isn't optional or automatable from a headless pipeline the way
everything else in this job is; SETUP.md's walkthrough sequences it explicitly as Part B,
before the API key secrets are used for a real run, specifically so the first real attempt
doesn't fail on an undocumented prerequisite.

**Confirmed the current GitHub token can't manage or read repository secrets at all**
(`gh secret list` returns a 403, distinct from the Contents-scoped fine-grained PAT set up in
Phase 0) before writing instructions that assumed otherwise. Rather than asking the owner to
widen that token's permissions just to route Apple's private signing key through this session,
SETUP.md has the owner paste all four values directly into GitHub's own secret-entry UI —
strictly fewer hops for a sensitive credential, and it costs nothing since the next CI run's own
log already shows whether the secrets were found, without needing read access to them at all.

**SETUP.md recommends "Full Access," not "Limited Access," for the new app record's "User
Access" setting** — this owner question came up directly, and checked rather than guessed
before answering (the first draft had hedged with "leave as-is"). Limited Access restricts an
app's visibility to specifically-chosen team members, useful for a multi-person team managing
several apps; it has no benefit for a one-person account, and choosing it risks the CI signing
key needing a separate, explicit per-app access grant just to see the app — the same category
of avoidable first-run failure as the app-record-creation-order issue above.

**The app's real display name collided with an existing App Store listing** ("GotTime?" was
already taken globally — Apple enforces this across the entire store, not per-account). Fixed
by using "GotTime? Calling" for App Store Connect's own "Name" field specifically — this field
is distinct from `INFOPLIST_KEY_CFBundleDisplayName` (already "GotTime?", untouched, and the
only thing anyone actually sees on a home screen or inside TestFlight before the app is ever
publicly released), so nothing built earlier needed to change.

## First real `sign-and-upload` run: found a genuine, previously-unverifiable bug

With all four secrets saved and the app record created, triggered the first real run (via a
small, honestly-motivated doc commit — the current GitHub token can dispatch neither
`workflow_dispatch` runs, confirmed via a 403, nor read secrets, so a real push is the only
trigger mechanism available). Exactly as flagged when this job was written: the **Archive**
step failed on its first real attempt, since there was never any way to test this ahead of a
real key existing.

**Root cause, from the actual error text** (`CryptoKit.CryptoKitASN1Error.invalidPEMDocument`,
from `xcodebuild`'s own `-authenticationKeyPath` validation): the `.p8` file's content, as saved
in the `APP_STORE_CONNECT_API_KEY_P8` secret, doesn't parse as a valid PEM document. This is a
local parsing failure that happens before any network call to Apple, which rules out a wrong
Key ID/Issuer ID/Team ID (those would surface as a rejected authentication *request*, not a
malformed-credential error caught locally) — it isolates the problem specifically to how the
`.p8` file's contents made it into that one secret. The most likely cause is exactly the kind of
thing manual copy-paste through Notepad is prone to: a missed line, extra whitespace, or an
altered line break silently breaking PEM's strict line-structure requirements.

**Fix given to the owner deliberately avoids manual visual copy-paste a second time**, rather
than just asking them to redo the same fallible steps: drag the `.p8` file directly into a
PowerShell window after typing `Get-Content ` (auto-fills the exact quoted path, no typing a
filename required) and pipe it through `-Raw | Set-Clipboard` — this reproduces the file's exact
bytes onto the clipboard with no manual selection step for anything to go wrong in, then update
(not recreate) just the one secret. Deliberately kept this entirely an owner-executed local
operation rather than piping the key's contents through this session at all, even transiently —
consistent with the earlier reasoning that the fewer hops a private signing key passes through,
the better.

## Second and third real findings: Development-only profile, then wrong API key role

The PEM fix worked — confirmed directly (the retry's Archive step got measurably further:
package resolution, dependency checkout, actual compilation, versus failing in under 15 seconds
last time on local credential parsing). It then failed at the same **Archive** step with a
different, real error: `error: Communication with Apple failed: Your team has no devices from
which to generate a provisioning profile` / `No profiles for 'com.stevenkinney.gottime' were
found: ... iOS App Development provisioning profiles`. Automatic signing on a brand-new bundle
ID with zero existing profiles was defaulting to *Development*-style signing, which structurally
requires at least one registered device UDID — this project has none yet (by design; see the
TestFlight-only distribution decision above) and won't until the two-iPhone gate clears
separately. Fixed by adding `CODE_SIGN_IDENTITY=-` (literal hyphen — lets automatic signing pick
the identity type itself rather than a manually-forced one, which would otherwise conflict with
`CODE_SIGN_STYLE=Automatic`) and `AD_HOC_CODE_SIGNING_ALLOWED=YES` (broadens automatic signing to
consider distribution-style profiles, which need no registered devices) to the Archive step's
build settings. Cross-checked against two independently-phrased sources converging on the exact
same combination before applying it, rather than trusting one.

**That fix worked too** — Archive succeeded outright on the next retry, one step further than
ever before, failing instead at **Export & upload to TestFlight** with: `error: exportArchive
Cloud signing permission error` / `error: exportArchive No signing certificate "iOS Distribution"
found`. Researched this exact phrase directly rather than guess at another build-setting
tweak, and found a precise, specific answer: **distribution signing via cloud signing through
`xcodebuild -exportArchive` requires an App Store Connect API key with Admin-level access —
Developer or App Manager keys fail with exactly this error.** This directly overturns this
file's own earlier "App Manager, not Developer" reasoning above: that check was correct about
what App Manager *can* do (manage TestFlight/testers/submissions) but incomplete about what this
specific pipeline *needs* (cloud-managed certificate creation, which is Admin-only). SETUP.md
now recommends Admin outright — it's a strict superset of App Manager's capabilities for this
project's purposes, so there's no remaining reason to prefer the narrower role. Fix requires the
owner to generate a new Team API key with Admin access (API key roles aren't editable after
creation) and update just `APP_STORE_CONNECT_API_KEY_ID`/`APP_STORE_CONNECT_API_KEY_P8` — Issuer
ID and Team ID are account-wide, not per-key, so those two secrets don't need to change.

**Pattern worth naming**: three real, previously-unverifiable issues in a row, each one only
reachable after fixing the last (a credential parsing error blocks ever seeing the profile-type
error, which blocks ever seeing the permission error) — exactly what "no fake credential stands
in for Apple's real signing authority" (stated when this job was first written) predicted, just
playing out over several rounds instead of one. Each root-caused from the real error text plus
external verification before applying a fix, not from repeated guessing.

## Fourth finding: no app icon at all, and an iPad-multitasking orientation rejection

The Admin-role key fix worked completely — "Cloud signing permission error" is gone, and the
build got far enough to actually reach Apple's server-side validation (`The server's response
was: ...`), a fundamentally different, much more mundane category of problem than the three
infrastructure/credential issues above. Real errors: missing 152×152 and 120×120 app icons,
missing `CFBundleIconName`, and a rejected Portrait-only orientation declaration ("you need to
include all... orientations to support iPad multitasking").

**Root cause of the icon errors: this project never had an app icon at all.**
`ios/App/Resources/` was completely empty — nothing before a real App Store Connect submission
would ever catch this, since Simulator builds and tests never validate icon completeness.
Generated a real, functional placeholder rather than leaving this blocked on Phase 8's visual
design pass (App Store Connect rejects *any* upload without one, even for Internal Testing —
this genuinely couldn't wait): a simple stopwatch glyph in `gtAccent`
(`Color+GotTime.swift`'s exact light-mode value, `#B86B52`), rendered via `sharp` (installed
into a scratch directory, not the repo) from an inline SVG to a single 1024×1024 PNG, using the
modern single-size `AppIcon.appiconset` format (Xcode derives every smaller size itself — no
need to hand-generate a dozen exact pixel sizes). Explicitly flattened to remove the alpha
channel (`hasAlpha: false` confirmed before use) — the 1024×1024 marketing icon specifically
must have none; a visually-opaque-but-technically-RGBA file still fails validation. Wired in via
`ASSETCATALOG_COMPILER_APPICON_NAME`/`INFOPLIST_KEY_CFBundleIconName` on the `GotTime` target
(not project-wide — `GotTimeUITests` has no reason to need one). This is a functional
placeholder, not a design decision — flagged here so Phase 8 doesn't mistake it for a real
branding choice already made.

**Orientation fix carries a real, deliberately-accepted trade-off, not just a validator
formality.** The straightforward fix — also declaring all 4 orientations on the base
(non-suffixed) `INFOPLIST_KEY_UISupportedInterfaceOrientations` key, not just the `~ipad`-
suffixed one already present — genuinely changes iPhone runtime behavior: it actually allows
the app to rotate to landscape/upside-down on a real phone, which the original Portrait-only
declaration didn't. Checked before accepting this: no `GeometryReader` or fixed-size
absolute-positioning layouts anywhere under `App/Features/` that would visually break in
landscape — every `.frame(width:...)` hit is a small decorative element (avatar circles, icon
buttons), not a screen-dependent layout. Accepted the trade-off rather than chase a more
surgical fix (e.g., confirming whether XcodeGen's `INFOPLIST_KEY_*~ipad` idiom-suffix synthesis
was even taking effect at all) given the actual stakes: this is a placeholder build for internal
family testing of core calling functionality, Phase 8 already exists to revisit exactly this
kind of polish, and every further guess costs a real CI round-trip. **Revisit in Phase 8**: lock
back to portrait-only on iPhone once the real reason the `~ipad`-only key wasn't sufficient on
its own is understood, rather than carrying this broader-than-intended declaration forward
by default.

## Sign-and-upload pipeline fully verified: a real signed build reached TestFlight

The icon/orientation fix worked — the next run's `Sign & upload to TestFlight` job succeeded
completely, every step, for the first time. **A real, signed GotTime build now exists on
TestFlight.** Five real attempts, four distinct root causes, each only discoverable by actually
hitting real Apple infrastructure (invalid PEM → wrong profile type → wrong API key role →
missing icon/orientation) — exactly what was anticipated when this job was first written
("there is no local or fake way to test xcodebuild signing flags at all"), just taking several
rounds instead of the "at least one" originally guessed. Every round was root-caused from the
actual CI error text plus external verification before applying a fix — never a repeated guess
at the same problem, and each fix stuck on the first real retry once correctly diagnosed.

This closes out the last piece of Phase 4 that was ever code-shaped. What remains — the
two-iPhone device test itself, and creating an Internal Testing group so those phones can
install the build already sitting in TestFlight — is pure device/UI action with no remaining
engineering uncertainty in the pipeline underneath it.

## First real launch crash: untested xcconfig-to-Info.plist wiring never actually worked

The owner's own first real launch — tapping Sign in with Apple on a real iPhone — crashed
immediately. Got the real crash report (`.crash` file + `feedback.json`, both pulled directly
from App Store Connect's TestFlight → Crashes section) rather than guess from the symptom
description alone, and the stack trace told a precise, different story than the reported
timing suggested: the trap wasn't in the sign-in code at all, it was `SupabaseClientFactory.
makeClient()`'s own deliberate `fatalError` (`SupabaseClientFactory.swift:19`), called from
`AppEnvironment.live()` at app-launch time, before the sign-in screen is even meaningfully
interactive — the "as soon as I tapped it" timing was the owner's honest best read of a
launch-time crash, not literally caused by the tap.

**Root cause, once traced precisely**: `INFOPLIST_KEY_GTSupabaseProjectRef`/
`INFOPLIST_KEY_GTSupabaseAnonKey` were the *only* `INFOPLIST_KEY_*` settings in `project.yml`
using `$(GT_SUPABASE_PROJECT_REF)`-style xcconfig variable substitution rather than a plain
literal value — every other one (`CFBundleDisplayName`, `CFBundleIconName`,
`UISupportedInterfaceOrientations`, `ITSAppUsesNonExemptEncryption`) is a literal, and all of
those are confirmed working (the display name and icon both show correctly). That substitution
path had never been exercised even once before this exact launch: Debug/Simulator builds
always use `.mock()` (never calling `SupabaseClientFactory.makeClient()` at all), so nothing in
Phases 0-3, and none of the several CI rounds earlier in Phase 4, ever actually read these two
values back out of a real compiled Info.plist — only this first real device launch did.

Rather than keep guessing at exactly why the substitution didn't reach the compiled binary
(researched this specifically — confirmed `INFOPLIST_KEY_*` synthesis does support arbitrary
custom keys generally, not just Apple-defined ones, so that wasn't it; couldn't get fully
conclusive evidence on the `$(...)`-substitution-specifically question without another real
device round-trip, which is expensive here unlike a CI retry), fixed it by eliminating the
untested mechanism entirely: both settings now hold the literal value directly, matching the
exact pattern every already-proven-working `INFOPLIST_KEY_*` setting in this file already
uses. **`Config/AppConfig.xcconfig` still holds the values too** (for its own documented
"why these are safe to commit" purpose) — now explicitly duplicated and cross-referenced in
both files' comments rather than silently drifting, since nothing prevents them going out of
sync without a reminder.

**`CURRENT_PROJECT_VERSION` bumped 1 → 2** alongside this fix — Apple rejects re-uploading an
identical build number, and per Apple's own review-scoping rules a later build of the same
*version* (0.1.0 unchanged) shouldn't need a fresh Beta App Review, only a new version's first
build does. Expect this fix to reach TestFlight without another review cycle.

## Same crash survived the literal-value fix — added on-screen diagnostics instead of guessing again

Build 2 (with the literal-value fix above) reached the owner's phone via Internal Testing's
automatic distribution — confirmed he was actually running build 2 (not a stale build 1) before
treating this as a real finding, matching the same discipline as every crash report this
session. It crashed identically: same exact stack trace, same exact line
(`SupabaseClientFactory.swift:19`), confirmed byte-for-byte against the new `.crash` file. The
literal-vs-`$(...)`-substitution theory was wrong, or at least incomplete.

**Rather than guess a third time, restructured the app to show the real problem on screen
instead of crashing opaquely.** `SupabaseClientFactory.diagnoseConfig()` (new, non-crashing)
checks the same two Info.plist keys `makeClient()` already does, and on failure returns a
detailed, copyable dump: both keys' actual values (or `MISSING`), the bundle identifier, and
every key that *did* make it into `Bundle.main.infoDictionary` — enough to distinguish "these
two specific keys didn't synthesize" from "the whole `INFOPLIST_KEY_*` mechanism silently
isn't working at all" from something else entirely. `GotTimeApp.swift` restructured (`RootView`,
a new small view) so Release builds check this before ever constructing a real
`AppEnvironment`, showing `ConfigDiagnosticView` (new) instead of `ContentView` when the check
fails — text is `.textSelection(.enabled)` specifically so the owner can copy-paste the exact
diagnostic text directly off the phone screen rather than transcribe a screenshot. `makeClient()`
itself is untouched, kept as a last-resort safety net that should now never actually fire.

**Both pieces are explicitly TEMPORARY**, called out as such in their own doc comments —
matching exactly how the Phase 1 ZStack debugging session's print-tracing and `gtDebugState`
diagnostics were treated: build what's needed to see the real answer, remove it once the root
cause is confirmed and actually fixed, don't leave debugging scaffolding mistaken for permanent
infrastructure.

Could not compile-check this locally (no Mac, as always) — reviewed carefully against a pattern
already proven working elsewhere in this exact codebase (`ContentView.callOverlay`'s
`switch`-with-heterogeneous-view-cases), and the Simulator CI job exercises this same `RootView`
code path in Debug/mocked mode, so a real compile problem should surface there, fast, before the
much slower archive-and-upload cycle even starts.

## Root cause found, definitively: custom INFOPLIST_KEY_* settings never synthesize here at all

Build 3 (the on-screen diagnostics) reached the owner's phone and answered the question
outright. The dump of `Bundle.main.infoDictionary` showed 31 real keys — every standard,
Apple-defined `INFOPLIST_KEY_*` setting in this project *is* present and correct
(`CFBundleDisplayName`, `UISupportedInterfaceOrientations`, `ITSAppUsesNonExemptEncryption`,
etc.) — but **neither `GTSupabaseProjectRef` nor `GTSupabaseAnonKey` appears anywhere in the
list at all.** Not empty, not wrong — completely absent from the compiled Info.plist. This
directly contradicts general web research done earlier ("`INFOPLIST_KEY_*` synthesis supports
arbitrary custom keys, not just Apple-defined ones") — that research was wrong, or described a
different mechanism/Xcode version than what this project's actual toolchain does. Direct,
empirical evidence from the real compiled binary overrides it: in this project,
`GENERATE_INFOPLIST_FILE`'s synthesis only recognizes real, Apple-defined Info.plist keys.
Custom keys were never going to work here, which is exactly why literal-vs-`$(...)`-substitution
made no difference between build 1 and build 2 — the problem was never about the *value*, it was
that the *key* itself was silently dropped either way.

**Fix: stopped routing these two values through Info.plist at all.** Added
`SupabaseConfig.swift` — a plain `enum` with the two values as compiled-in Swift `static let`
constants, matching them exactly to what `AppConfig.xcconfig` held. A compiled-in constant has
no indirection layer left to trust; it either compiles (and is then always present, by
construction) or the build fails outright, closing off the entire class of "silently missing at
runtime" failure this whole multi-round debugging session was chasing. `SupabaseClientFactory.
makeClient()` simplified back down to just building the URL and constructing the client — no
more Bundle/Info.plist reads, no more guard chain, no more possibility of the fatalError firing
for this reason ever again.

**Removed, not left around, once no longer needed**: `Config/AppConfig.xcconfig` (deleted
entirely — its sole purpose was feeding these two values into Info.plist, which never worked;
keeping it would leave dead, misleading configuration behind), the `configFiles:` block in
`project.yml` that referenced it, the two `INFOPLIST_KEY_GTSupabase*` settings, and — since the
failure mode they detected can no longer occur — `ConfigDiagnosticView.swift` and
`SupabaseClientFactory.diagnoseConfig()` from the previous entry, restoring `GotTimeApp.swift`
to its original, simpler structure. Matches this session's own stated discipline for temporary
diagnostics: built to find the real answer, removed the moment that answer was in hand, not
left around as dead code mistaken for permanent infrastructure.

**Lesson for future custom Info.plist values in this project**: don't use
`INFOPLIST_KEY_<CustomName>` build settings for anything not in Apple's own known key set — it
silently does nothing here, with no build warning or error. A plain Swift constant (or, if a
real per-build/per-environment value is ever needed, an actual authored `Info.plist` file
merged via `INFOPLIST_FILE` rather than relying on synthesis) is the reliable path for this
toolchain.

## Onboarding's Continue button did nothing: a real bug, caught on the first real account ever

With sign-in finally working, the owner reached onboarding ("What should we call you?") for
the first time on a real device — and tapping Continue appeared to do nothing at all.

Read `OnboardingView`/`SupabaseAuthAdapter`/`MockAuthService` side by side rather than guess,
and the gap was immediate: `SupabaseAuthAdapter.updateFirstName()` did a raw PostgREST
`UPDATE` on the `profiles` table and stopped there. `ContentView` only ever leaves
`OnboardingView` when a *new* `authState` value arrives via `authStateStream` (`profile.
hasCompletedOnboarding` flips true once `firstName` is set) — and that stream is fed from
Supabase's own `authStateChanges`, which is strictly about auth *session* events (sign in/out,
token refresh). A plain table write was never going to fire it. The name genuinely saved to the
database every time; the screen just had no way to find out.

**Never caught by any mocked or UI test because `MockAuthService`'s own `updateFirstName` does
the right thing** — it calls `setState(.signedIn(profile))` after updating, correctly
re-emitting state. The mock's correctness masked the real adapter's gap for the entire project,
since nothing before this exact moment had ever run the real `SupabaseAuthAdapter` through a
fresh account with no name from Sign in with Apple (the only way to reach onboarding at all).

**Fix**: after the update succeeds, re-fetch the profile (reusing the adapter's existing
`fetchProfile(userId:)` helper — not constructing a `Profile` locally) and yield it as a new
`.signedIn(profile)` state, matching this adapter's own already-stated philosophy of treating
the `profiles` table, not cached client-side state, as the single source of truth. Wrapped in
`try?`, matching the same risk tolerance already used elsewhere in this file for a
should-be-transient re-fetch after a write that already succeeded — worst case on failure, the
user stays on `OnboardingView`, exactly today's behavior, not a new regression.

Third real, previously-latent bug found this way in a row (after the two Info.plist rounds) —
each one only reachable by an actual account doing an actual first-time thing on an actual
device, the exact class of bug this whole phase's manual two-person test exists to surface.

## Invite redemption failing both directions: best-effort fix plus better diagnostics, honestly labeled as such

With onboarding fixed, the next real step — redeeming a connection invite between two real
accounts — failed both directions (owner→brother and brother→owner), each showing only the
view's own generic `"That code didn't work — check it and try again."`.

**Unlike the previous two bugs, static reading alone didn't turn up a single, confident root
cause this time.** Read `AddConnectionView`, `SupabaseConnectionAdapter.redeemInvite`, and the
`redeem_connection_invite()` SQL function (0006_rls_policies.sql) end to end: the RPC parameter
name (`p_invite_code`) matches exactly, the invite alphabet is already uppercase-only (ruling
out a case mismatch against the text field's `.textInputAutocapitalization(.characters)`), and
this exact SQL function already passed a real, live 8-check verification run in Phase 3
(`verify-connections-rls.ts`) — strong evidence the *logic* itself is sound. What's never been
exercised before is the real Swift client's own `.rpc(...)` call path on a real device, the
same category every bug so far this session has come from.

Rather than guess at a specific cause with no strong evidence for it, fixed the one thing that
was unambiguously wrong regardless — the generic catch-all error message discards
`PostgrestError`'s own `message` (it conforms to `LocalizedError`, so `redeem_connection_invite`'s
own exception text — `"Invalid invite code"`, `"Invite has expired"`, `"Cannot redeem your own
invite"`, `"Already connected"` — was always one `error.localizedDescription` away and just
never being shown) — and applied one genuinely safe, no-downside defensive fix alongside it:
trimming the entered code before sending, since a code is retyped by eye off another screen,
not pasted, and a stray keyboard-inserted space would fail the server's exact-match lookup with
no visible sign anything was wrong.

**Recorded honestly as a best-effort attempt, not a confirmed fix** — unlike the two previous
entries, which named an exact, verified root cause before calling it done. If the trim doesn't
turn out to be the actual cause, the improved error message will show the *real* Postgres
exception text on the very next attempt, which should make whatever's actually wrong obvious
immediately rather than needing a fourth guess.

## Fourth bug found, this time via direct database investigation, not another build round-trip

Two new real-device reports arrived close together: a call to the newly-connected brother
returned "Call failed," and — after the owner deleted and recreated both accounts to
troubleshoot — a fresh connection attempt seemed to hit the exact same "didn't work" error
again. Rather than ship another guess, queried the live database directly (service-role
credentials, already held for exactly this kind of verification) instead of waiting on another
TestFlight round-trip.

**The data told a different story than the reports suggested.** `connection_invites` and
`connections` showed a real, active connection between the owner's new account and the
brother's — created via a genuinely successful `redeem_connection_invite()` call. A second
invite, created afterward between the same now-already-connected pair, sat unredeemed. Put
together with `redeem_connection_invite()`'s own logic (`on conflict ... do nothing` +
`raise exception 'Already connected'` when a pair tries to connect twice), the real sequence
was clear: the first connection attempt actually succeeded; the app never showed it; the owner
tried again, reasonably assuming failure; the *second* attempt was correctly rejected as
"Already connected" — the exact same generic-looking error text as before, now technically
accurate but deeply confusing without context.

**Root cause, once that pointed the right direction**: `PeopleListView`'s `.sheet(isPresented:
$showingAddConnection)` had no `onDismiss` handler at all, unlike the adjacent
`.sheet(item: $selectedPerson, onDismiss: ...)` right above it in the same file. The connected-
people list only ever loads once, on first appearance (`.task`), or on a manual pull-to-refresh
(`.refreshable`) — nothing re-fetched it after `AddConnectionView` dismissed, successful
connection or not. The exact same shape of bug as the onboarding one three entries back: a
write that genuinely succeeded server-side, with nothing telling the relevant screen to notice.
Fixed by adding the missing `onDismiss`, re-fetching unconditionally (simpler and equally
correct whether the sheet closed via success or a plain Close tap).

**A real methodology correction, made honestly rather than glossed over**: mid-investigation, an
empty `call_sessions` table was initially read as proof `request-call` had never even been
reached for the original failed call attempt. That conclusion didn't hold up — by the time that
query ran, the owner had already deleted his original account to troubleshoot, and
`call_sessions` cascade-deletes with its owning user (a deliberate Phase 2 design choice, see
the "Account deletion cascades" entry above). An empty table after a deletion proves nothing
about what existed *before* it; the investigation had unknowingly contaminated its own evidence.
Caught this before shipping a fix based on the wrong conclusion, not after — the connection-
refresh bug above was found and fixed on its own, independently-confirmed merits instead.

**The original "Call failed" report is still genuinely open.** Whatever caused it may or may not
be related to this same stale-list confusion (a first-time flow error is very plausible when the
UI you're looking at doesn't match reality); it hasn't been independently confirmed either way.
Next step once this build confirms the connection now displays correctly: retry the call fresh,
and if it fails again, check `call_sessions` and Twilio's own logs *immediately*, before any
further account changes could contaminate the evidence a second time.

## The real "Call failed" cause: a genuine Phase-5-into-Phase-4 dependency, found from Twilio's own call logs

With the People-list bug fixed and both real connections confirmed, the owner retried calling
in both directions — owner → wife and wife → owner — and both failed identically. This time,
investigated with direct API access before shipping anything: Supabase's own `edge_logs`
proved unreliable for this (querying `function_edge_logs` for Edge Function invocation records
returned zero rows even for calls known to have succeeded — logging retention/availability for
this project's plan tier, not a code problem, and not worth chasing further), but `call_sessions`
itself told a clear story — `request-call` had created a session every time (`status: "created"`),
proving authorization and session creation both work — with `ringing_at`/`provider_call_sid`
staying null on every attempt, meaning the call never progressed past the very first step.

**Twilio's own Calls API gave the definitive answer directly**, no guessing required: the
caller's own leg into Twilio's infrastructure succeeded every time (`status: completed`), and
the resulting `<Dial><Client>` leg correctly targeted the right recipient identity — but ended
in **`status: "no-answer"`**. Cross-checked against Twilio's own Voice iOS SDK documentation
before concluding anything: receiving *any* call through `<Dial><Client>` requires the
recipient's device to have called `TwilioVoiceSDK.register(accessToken:deviceToken:completion:)`
with a real PushKit VoIP device token first — a hard SDK requirement, not an optional
enhancement. Grepped `TwilioVoiceAdapter.swift` for `register` and found zero matches — this
call had simply never been made, anywhere in the codebase.

**This reveals a real gap in how the original build plan drew its phase boundary.** Phase 4
("Voice proof... exit: foreground, unlocked, two-way audio") and Phase 5 ("CallKit/PushKit...
register tokens") were scoped as sequential, but Phase 4's own exit criterion turns out to be
structurally impossible without at least the registration slice of Phase 5 — there is no way
for `<Dial><Client>` to reach a real device at all without it, foreground or not. This wasn't
knowable from reading the spec or the SDK's outgoing-call API alone; it only became visible by
actually testing a real call between two real devices, which is exactly what this phase's own
two-iPhone requirement existed to surface.

**Scope decision: pull forward only the minimum slice that's a hard prerequisite, not all of
Phase 5.** Built `PushKitAdapter` (new) to register for VoIP push and route incoming invites to
`TwilioVoiceAdapter`, reusing Twilio's own push delivery mechanism directly
(`TwilioVoiceSDK.register`) rather than building the `register-device`/`device_registrations`
Edge-Function-and-table path `PushService`'s original doc comment envisioned (GotTime's own
backend sending a custom, richer APNs push, per the earlier "APNs VoIP push delivered directly,
not via Twilio Notify" decision) — confirmed directly from Twilio's own official SwiftUI
quickstart sample (`PushKitManager.swift`/`CallManager.swift`, read from GitHub before writing
any code against it) that `TwilioVoiceSDK.register` alone, with no custom push involved, is
sufficient for `<Dial><Client>` to work at all. The richer custom-payload path stays available
as a genuine later enhancement, not a rewrite. Full native CallKit UI (lock-screen incoming
calls, `CXProvider` reporting) is *also* deliberately deferred — the existing in-app
`IncomingCallView` (built in Phase 1 explicitly as "a banner standing in for CallKit until
Phase 5") is enough to prove real two-way audio works at all, which is this phase's actual bar.

**Every new SDK/API surface was verified against real, primary sources before writing code
against it, not assumed**, given the cost of guessing wrong here (another real device
round-trip) was high and nothing about this exact integration had been built before:
- `TwilioVoiceSDK.register`/`.handleNotification`, `PKPushRegistryDelegate`, and
  `NotificationDelegate`'s exact method signatures (`callInviteReceived(callInvite:)`,
  `cancelledCallInviteReceived(cancelledCallInvite:error:)`) — all confirmed directly from
  Twilio's official quickstart source, not recalled from memory.
- `CallInvite.customParameters` (`[String: String]?`) for reading the embedded
  `callSessionId` on the receiving end, matching what `startCall` already embeds on the
  sending end — confirmed via Twilio's own docs.
- `CancelledCallInvite` doesn't expose a local call UUID directly, only `callSid` — matching
  the quickstart's own matching strategy (compare against the still-held `CallInvite`'s own
  `callSid`, which does carry the UUID) rather than assuming a more convenient API existed.
- `call_sessions`' RLS policy (`call_sessions_select_participant`) already correctly allows a
  recipient to read their own incoming session — checked, not assumed, before relying on it
  for the caller-profile/session lookup on an incoming push.
- The required entitlement/Info.plist keys (`aps-environment`, `UIBackgroundModes` including
  `voip`/`audio`) — read directly from Twilio's own quickstart's `.entitlements`/`Info.plist`,
  with `aps-environment` deliberately set to `production` (not the quickstart's own
  `development`) since every real build here ships via TestFlight with Distribution-style
  signing, never a local Xcode Development-signed run.
- `INFOPLIST_KEY_UIBackgroundModes`' array-value syntax — no external documentation gave a
  confident answer, so this leaned on direct, already-verified precedent from this exact
  project instead: `INFOPLIST_KEY_UISupportedInterfaceOrientations` (also array-typed) is
  already confirmed synthesizing correctly via a space-separated string, per the on-screen
  Info.plist dump from the earlier crash investigation.

**Also added `NSMicrophoneUsageDescription` proactively**, not reactively — every real call
attempt so far has failed before ever reaching "connected," so a missing microphone permission
key has never had a chance to surface yet, but it unconditionally would the moment one does
(iOS refuses microphone access outright without this key, for any app). Fixing it now avoids
turning it into a fifth separate failed round-trip once incoming calls start working.

**Known, deliberately-accepted gap, recorded rather than silently left**: a cancelled incoming
invite (caller gives up before the recipient answers) clears `TwilioVoiceAdapter`'s own
`pendingInvite` state correctly, but `CallCoordinator`'s `.callEnded` handling only reacts once
`activeCall` is set — an incoming call that's never answered doesn't reach that state, so the
in-app incoming-call banner could keep showing after the caller has actually hung up. Spec
section 16 edge-case territory, not a blocker for proving the core mechanism works; worth a
proper look once real two-way audio is confirmed.

## VoIP Services Certificate + Twilio Push Credential: the piece PushKitAdapter needed to actually receive anything

Build 8 (PushKitAdapter, previous entry) shipped `TwilioVoiceSDK.register()` but that call is
only half the mechanism — Twilio also needs an Apple-issued certificate on file so it can
actually deliver the VoIP push once a device registers. Confirmed the CI job that produced
build 8 completed successfully (both Simulator and Sign & upload jobs green) before doing
anything else with this.

**Owner gate cleared: VoIP Services Certificate, not the originally-planned APNs .p8 key** —
consistent with the earlier architecture decision (Twilio delivers pushes directly, no custom
`register-device` backend path). Generated the CSR and private key locally via `openssl req`
(no Mac/Keychain Access needed — see the earlier CSR-generation entry), sent only the CSR to
the owner, kept the private key local. Owner enabled the Push Notifications capability on the
`com.stevenkinney.gottime` App ID, created a VoIP Services Certificate from the CSR in the
Apple Developer Portal, and sent back the resulting `voip_services.cer`.

**Verified, not assumed, before using it for anything:**
- Converted DER→PEM via `openssl x509 -inform DER ... -outform PEM` and read the subject back:
  `UID=com.stevenkinney.gottime.voip, CN=VoIP Services: com.stevenkinney.gottime,
  OU=TDMZW5R7BC, O=Steven Kinney, C=US` — confirms it's issued for the right app and the
  right Apple Developer team, not just "a certificate that opened without erroring."
- Confirmed the certificate and the locally-held private key are actually a matched pair via
  `openssl x509 -noout -modulus | openssl md5` vs. `openssl rsa -noout -modulus | openssl md5`
  on each — identical hashes. Skipping this check would have meant not finding out the two
  didn't match until a real push silently failed to decrypt on Apple's side, a much harder
  failure to diagnose than a `#!/bin/sh` string comparison.

**Created the Twilio "Push Credential" via Twilio's REST API directly** (same "owner doesn't
need to touch Twilio's console for API-reachable setup" pattern as
`backend/scripts/twilio-setup.ts`), using the existing `.env` `TWILIO_ACCOUNT_SID`/
`TWILIO_AUTH_TOKEN`. **First attempt used the wrong API surface** —
`https://api.twilio.com/2010-04-01/Accounts/{sid}/Credentials/Push/APN.json` (by analogy with
the core Calls/Messages REST resources already used elsewhere in this project) returned a
genuine 404, not a permissions or formatting error. Push Credentials are actually a Notify API
resource: `POST https://notify.twilio.com/v1/Credentials` (`Type=apn`, `Certificate`,
`PrivateKey`, `Sandbox=false`) — corrected immediately once the 404 proved the first guess
wrong, rather than retrying the same URL. Returned `sid: CR2f6cc884e93f0d76452233b2ba386853`,
`sandbox: false` — `Sandbox=false` deliberately, matching `aps-environment: production`
already set in `project.yml`'s entitlements (a sandbox credential would silently fail against a
production-signed TestFlight build).

**Wired the credential into the token-minting path**, not left as an orphaned Twilio-side
resource: Twilio's Voice Access Token format supports an optional `push_credential_sid` field
inside the `voice` grant specifically so `TwilioVoiceSDK.register()` knows which certificate to
push through — without it, Twilio has no way to resolve "this device token" to "this app's
APNs identity" even though a Push Credential exists on the account. Added `pushCredentialSid`
as an optional field to `buildVoiceAccessToken`'s params (optional, not required, so existing
tests needed zero changes — confirmed all 44 `deno test` cases still pass unmodified) and
`index.ts` now reads `TWILIO_PUSH_CREDENTIAL_SID` and passes it through. Deliberately *not*
folded into the existing four-variable `503`-if-missing check: a token minted without it still
works fine for outgoing calls, it just can't receive a push — a real incoming-call bug, not a
"voice calling isn't configured at all" state, so it shouldn't 503 the whole endpoint.

Set `TWILIO_PUSH_CREDENTIAL_SID` as a Supabase Edge Function secret (`npx supabase secrets
set`, one named variable, same pattern as the original four Twilio secrets — not the whole
`.env` file) and deployed `issue-voice-token` (`npx supabase functions deploy
issue-voice-token`). Also recorded the SID in `.env` itself, replacing the stale
`APNS_AUTH_KEY_P8`/`APNS_KEY_ID`/`APNS_TEAM_ID` placeholders left over from the
original (superseded) direct-APNs architecture plan — those three were never going to be filled
in under the Twilio-push-credential design, so keeping them around as empty placeholders was
misleading rather than aspirational.

**Not yet verified**: whether an actual incoming call now reaches a locked/foreground real
device end to end. This entry documents the pipeline being *correctly assembled and deployed*,
confirmed via each step's own direct evidence (matched modulus, successful 201 from Twilio,
passing tests, successful deploy) — not a claim that a real call has been tested yet. That's
the next real-device round-trip, not a foregone conclusion.

## Real retest still failed identically — added real remote diagnostics instead of guessing a third time

The owner retested in both directions (5 min and 10 min) immediately after the certificate
pipeline above was confirmed deployed. Both failed identically to every prior attempt. Checked
Twilio's own evidence first, same discipline as the original "no-answer" investigation:
`call_sessions` showed both attempts reached `request-call` fine (`status: "created"`) but never
progressed to `ringing_at`; Twilio's Calls API showed the same `<Dial><Client>` → `"no-answer"`
pattern as every attempt before the certificate work. Went further this time, since a
plausible-but-wrong theory had already been shipped once for this exact bug (see the earlier
"real Call failed cause" entry) — checked Twilio's own Debugger (`GET
https://monitor.twilio.com/v1/Alerts`) and the specific failed calls' own Notifications
subresource for any push-delivery error. **Both came back completely empty** — not "push
attempted and rejected," but no record of a push attempt at all.

**That absence is itself the evidence.** If Twilio had tried to push through the new certificate
and failed (expired cert, wrong environment, malformed payload), that would show up as an Alert
or a call Notification — Twilio's push infrastructure does log delivery failures. Getting
nothing back points further upstream: Twilio likely never considered either identity
"registered" to receive a call at all, meaning the failure is on the client side of
`TwilioVoiceSDK.register`, not the certificate/credential just wired up.

**Re-reading `PushKitAdapter.swift` with that specific question found a real, previously-unnoticed
blind spot**: `pushRegistry(_:didUpdate:for:)` calls `voiceAdapter.registerDeviceToken(...)`
wrapped in `try?` — any failure (expired/mismatched credential, malformed token, network error,
anything at all) is silently discarded, and nothing before that point confirms `PKPushRegistry`
even handed out a token in the first place. This build (build 8) has never been exercised on a
real device before this test, so this blind spot has been present the entire time and nothing
about the certificate work could have surfaced it — the certificate pipeline is necessary but
evidently not sufficient, and there was no way to tell which side of that boundary the remaining
failure was on without adding real visibility.

**Chose remote diagnostics over guessing a fix blind, deliberately** — this project has no
device console access (no local Mac/Xcode), so a `print()` statement would be invisible; two
previous guessed fixes for the *other* crash earlier in this project both failed identically
before on-screen diagnostics gave a real answer, and that's the same discipline applied here.
Added three columns to `profiles` (migration `0007_push_registration_diagnostics.sql`):
`push_registration_status` (`requested`/`registered`/`failed`), `push_registration_detail`, and
`push_registration_updated_at`. Applied directly via the Supabase Management API's `POST
/v1/projects/{ref}/database/query` endpoint rather than `supabase db push` — the CLI's `db push`
failed twice for unrelated reasons (`.env`'s `SUPABASE_DB_PASSWORD` was genuinely empty, a stale
placeholder never filled in since Phase 0; and separately, `supabase link` hit a real CLI bug on
Windows — `AlreadyExists: FileSystem.makeDirectory` on `supabase/.temp`, reproducible even after
deleting that directory first) — the Management API path sidesteps both and needed only the
access token already in hand.

No new RLS policy needed — `profiles_update_self` (0006) already permits a user to update their
own row's arbitrary columns, the same policy `updateFirstName` already relies on. `PushKitAdapter`
now writes `"requested"` the moment `registerForVoIPPushes()` runs (so a row stuck there forever
distinguishes "PushKit itself never handed out a token" — an entitlements/provisioning question —
from a token arriving but registration failing), then `"registered"` or `"failed"` (with the
real error text, truncated to 500 chars) once `TwilioVoiceSDK.register`'s completion actually
resolves. Deliberately a best-effort write (`try?` at the write itself, not the registration
call it's reporting on) — a diagnostic failing to log itself must never compound the failure
it exists to observe.

**Genuinely not yet known**: which of the three states either phone will land in. That's the
next thing to check, directly via the real `profiles` table, once build 9 is on both phones and
a fresh call is attempted — not assumed here.

## Build 9's real result: stuck at "requested" on both phones — narrowed to PushKit itself, not Twilio

Retested for real. Both accounts (`Sk` and `gabrielle`) show `push_registration_status:
"requested"`, `push_registration_updated_at` timestamped right around the retest, and no
`"registered"`/`"failed"` follow-up from either. This is itself the answer, not an ambiguous
result: `registerForVoIPPushes()` ran fully (the code path only reaches the `"requested"` write
after `registry.desiredPushTypes = [.voIP]` is set), but iOS's `PKPushRegistry` never called
`pushRegistry(_:didUpdate:for:)` back with a token on either real device — the failure is
upstream of `TwilioVoiceSDK.register` entirely, confirming the certificate/credential work
earlier was never the problem. (The timestamps also independently confirm both phones were
actually running build 9, not a stale build 8 — build 8 had no diagnostic-writing code at all,
so any row change had to come from build 9.)

**Checked what I could check myself before guessing a fix**: no local App Store Connect API
credentials exist outside GitHub Actions' own secrets (by design — see the earlier entry on
why only the four Twilio values, not everything, live in `.env`), so I can't independently
query whether the App ID's Push Notifications capability is really saved. Reasoned about it
indirectly instead: Apple's own certificate-creation flow (used to get `voip_services.cer`)
would have refused to create a VoIP Services Certificate for an App ID without that capability
already enabled — so its presence is already about as verified as it can be without direct API
access. Both build 8 and build 9's Archive steps also succeeded outright with the
`aps-environment` entitlement requested via `-allowProvisioningUpdates` automatic signing —
if the provisioning profile couldn't satisfy that entitlement, Xcode fails the archive with an
explicit error (this project has hit and diagnosed exactly that class of error before, for a
different capability, during the original sign-and-upload work). A silent, successful archive
on both builds is real (if indirect) evidence the profile/capability side is fine.

**The one remaining load-bearing assumption that was never independently verified**: whether
`INFOPLIST_KEY_UIBackgroundModes: "voip audio"` (a space-separated string, for this project's
one array-typed `INFOPLIST_KEY_*` setting other than orientations) actually lands as `["voip",
"audio"]` in the *compiled* Info.plist. The only direct confirmation this project has ever done
of that mechanism was for `UISupportedInterfaceOrientations`, via the on-screen dump during the
original launch-crash investigation — this key was set by analogy to that one working, never
checked itself. PushKit's `didUpdate` callback firing at all is documented to require the VoIP
background mode being genuinely present, so if the analogy doesn't hold for this key the way it
did for orientations, this exact "requested, then silence" symptom is exactly what you'd expect
— on both phones, identically, matching what was actually observed.

**Chose to verify this directly rather than guess a fix**, same discipline as every other real
finding this session: build 10 reads `Bundle.main.infoDictionary?["UIBackgroundModes"]` back
from the actual running app and writes it into `push_registration_detail` alongside the
existing `"requested"` status, so the next check of the real `profiles` table settles this with
direct evidence instead of another assumption. If it comes back empty or missing `"voip"`,
that's the confirmed root cause and the fix is straightforward (a different value format, or a
plain compiled Swift/native `.entitlements`-adjacent approach, matching how the earlier
Info.plist-synthesis problem was ultimately solved by leaving Info.plist out of the picture
entirely for the values that mattered). If `"voip"` is genuinely present and correct, the
search moves to the provisioning profile/capability side after all, this time with the
Info.plist explanation ruled out by direct evidence rather than assumed innocent.

## Confirmed root cause: `UIBackgroundModes=[]` on two real devices, not another guess

Build 10's real result settled it: both the owner's and the brother's phones reported
`push_registration_detail: "UIBackgroundModes=[]"` — genuinely empty, not just missing "voip."
The `INFOPLIST_KEY_UIBackgroundModes: "voip audio"` build setting was present in `project.yml`
the entire time (since build 8) and simply never synthesized into the compiled Info.plist at
all, on real hardware, confirmed directly rather than inferred from CI or documentation.

**This is a different failure mode from the earlier Supabase-config crash, not the same bug
recurring.** That one was "custom, invented keys never synthesize" — the fix there was to
abandon Info.plist entirely for those two values in favor of a plain compiled Swift file, since
nothing about the OS itself needed to read `GTSupabaseProjectRef` from Info.plist; the app's own
code was the only reader. `UIBackgroundModes` can't take that path — it's a real key the OS
itself reads directly from the compiled Info.plist to decide whether to grant PushKit
registration at all; there's no application-code workaround for an OS-level declarative
capability. The actual, narrower explanation: Xcode's `INFOPLIST_KEY_*` build-setting synthesis
only covers a specific, finite set of keys Xcode's own build system knows about (confirmed
working in this exact project for `UISupportedInterfaceOrientations`, `CFBundleDisplayName`,
`ITSAppUsesNonExemptEncryption`, `NSMicrophoneUsageDescription`, `CFBundleIconName`) —
`UIBackgroundModes` (traditionally configured through Xcode's "Background Modes" capability
checkboxes in the Signing & Capabilities UI, a different underlying mechanism from ordinary
build-setting-driven keys) simply isn't one of them, on this toolchain, for this key.

**Fix: a partial physical `Info.plist` (`ios/Config/Info.plist`, containing only
`UIBackgroundModes`), merged with the existing `INFOPLIST_KEY_*` settings** via
`INFOPLIST_FILE` on the `GotTime` target, rather than switching the *entire* project off
`GENERATE_INFOPLIST_FILE: YES` (which would mean re-deriving every other already-working key by
hand and risk breaking something that currently works). This relies on Xcode's own documented
Info.plist consolidation behavior (introduced Xcode 13): when both `GENERATE_INFOPLIST_FILE:
YES` and a target `INFOPLIST_FILE` pointing at a real (partial) plist are set, Xcode merges the
physical file's contents with the `INFOPLIST_KEY_*`-synthesized keys rather than one replacing
the other. Chosen deliberately over guessing a different `INFOPLIST_KEY_UIBackgroundModes`
value/format a third time — this project's own established discipline (two earlier guessed
fixes for the Supabase crash both failed identically) is to reach for a mechanism with real
documentation behind it once a first guess is empirically disproven, not to keep guessing syntax
variations blind.

Removed the now-confirmed-nonfunctional `INFOPLIST_KEY_UIBackgroundModes` setting from
`project.yml` entirely rather than leaving it in as harmless-but-dead — a stale setting that
looks load-bearing but silently does nothing is exactly the kind of trap that made this bug take
three real-device round-trips to find in the first place.

**Not yet reverified**: build 10's diagnostic code (reading `UIBackgroundModes` back and
reporting it) is still in place for build 11, so the very next real-device test will show
directly, with the same evidence-based method, whether this fix actually worked — not assumed
from the theory alone.

## Build 11's real retest: genuine progress, registration confirmed working, one more gap found

The owner retested build 11 for real, twice, with the app already open for a while (ruling out
the earlier registration-timing race). Both attempts still ended in "Call failed." Checked the
real evidence rather than assuming the fix failed outright:

**`profiles` confirmed the UIBackgroundModes fix genuinely worked**: both the owner's and the
brother's accounts show `push_registration_status: "registered"` with
`push_registration_detail: "UIBackgroundModes=[\"voip\", \"audio\"]"` — the array is no longer
empty, `TwilioVoiceSDK.register()` completed with no error, on real hardware. The build 10/11
fix is confirmed, not just theorized.

**Twilio's own call Events (`GET .../Calls/{sid}/Events.json`) showed something genuinely new**:
for both attempts where the recipient was already registered before the call started, the
outbound-dial leg reached `call_status: "ringing"` and stayed there for 10-11 real seconds before
ending in `no-answer` with `sip_response_code: "487"` (SIP "Request Terminated" — the standard
response to an explicit CANCEL, consistent with the owner's own description of watching it sit
on the calling screen and hitting Cancel himself). This is categorically different from every
attempt before build 10: every single prior attempt's outbound-dial leg showed instant,
`duration: 0` `no-answer` with no `"ringing"` event at all. The one remaining attempt in this
same test round that recipient (the owner, not yet finished registering until 2 minutes later)
never reached `"ringing"` either — cleanly consistent with the already-established
registration-timing explanation for that specific attempt, not a new mystery.

**Correctly resisted reading "ringing for 10s + SIP 487" as full confirmation the push was
delivered** — `"ringing"` is Twilio's own call-progress status for the Dial attempt itself and
doesn't, on its own, prove a VoIP push actually reached the device; a SIP 487 is exactly what an
impatient caller hitting Cancel after ~10 seconds produces regardless of whether the recipient's
phone ever showed anything. What's genuinely new and worth acting on is that Twilio is now
*attempting* delivery for a real, non-trivial window, where before it gave up instantly — meaning
the registration/certificate/credential chain is very likely no longer the blocker. What still
isn't known: whether the recipient's device ever received the push at all, and if it did,
which specific step of receiving/parsing/handling it broke down.

**Added the same kind of diagnostics to the incoming side that solved the outgoing side**,
rather than guess a fourth time: `PushKitAdapter`'s entire incoming-push path
(`didReceiveIncomingPushWith` → `callInviteReceived`'s parsing guard → `fetchIncomingCallContext`
→ `voiceAdapter.handleIncomingCallInvite`) had never reported anything, on either success or
failure — an identical blind spot to the one `try?` on `TwilioVoiceSDK.register` created for the
outgoing side (see the earlier "added real remote diagnostics" entry). Added
`last_incoming_push_status`/`detail`/`updated_at` to `profiles` (migration
`0008_incoming_push_diagnostics.sql`, applied the same way as 0007, via the Management API's
`database/query` endpoint) with five states: `push_received` (PushKit's delegate fired at all —
if this never appears, the push either never arrived or PushKit's delegate wasn't live to catch
it), `invite_unparseable`/`invite_parsed` (the identity/session-id parsing guard, with the raw
`From`/custom parameters recorded on failure so a real malformed-invite bug would be
diagnosable too, not just assumed), `context_fetched`/`context_fetch_failed` (the
profile+session lookup, with the real error on failure), and `delivered_to_coordinator`
(`TwilioVoiceAdapter` was actually told about the invite, meaning the UI *should* have had
everything it needed to show `IncomingCallView`).

**Deliberately did not yet restructure `PKPushRegistry` setup to happen at true app-launch time**
(e.g. via a `UIApplicationDelegateAdaptor`, which is Apple's documented best practice for VoIP
apps specifically so a *terminated* app can still be woken by an incoming push) — this project
currently creates the registry lazily inside `ContentView`'s `.task`, tied to a signed-in,
onboarded auth state. Both failed retests happened with the app already open in the foreground
the whole time, so a terminated-app-launch timing gap is very unlikely to be what broke *this*
specific test, and restructuring app-launch lifecycle is a meaningfully bigger, riskier change
to make without a real device available to verify it on. Reconsider this directly if the next
test's diagnostics show `push_received` never firing at all despite the app being open — that
specific result would point at the registry/delegate wiring itself rather than app-launch timing,
and is the point where this restructuring would become the evidence-supported next step, not a
speculative one.

**Owner is offline for the next several hours** — this build (12) is ready and pushed
autonomously; the next real-device retest, and reading whatever `last_incoming_push_status`
comes back, is queued for whenever testing resumes.

## Build 12 never actually shipped: a real compile error, caught by CI, not by review

Build 12's CI failed outright at "Build and test app + UI tests" — never reached signing, so
nothing changed on TestFlight. Real error text, not guessed: `payload.dictionaryPayload.keys.sorted()`
in the new `didReceiveIncomingPushWith` diagnostic doesn't type-check, because `PKPushPayload`'s
`dictionaryPayload` is `[AnyHashable: Any]` and `AnyHashable` isn't `Comparable` — `.sorted()`
(and the `.joined()` after it, cascading from the same root cause) has no valid overload for it.

This is exactly the failure mode this project's whole CI-as-the-only-Mac approach exists to
catch (see `ARCHITECTURE.md`/the top of `ios-ci.yml`) — there's no local Swift toolchain to
compile-check anything before pushing, so an error like this is only ever findable by an actual
build. Fixed by mapping each key to `String` before sorting
(`payload.dictionaryPayload.keys.map { "\($0)" }.sorted().joined(...)`) — `AnyHashable`'s
`CustomStringConvertible`-via-interpolation conversion sidesteps the `Comparable` requirement
entirely, same pattern already used elsewhere in this codebase for turning loosely-typed
values into inspectable strings.

Build 13 is this fix, nothing else changed from build 12's intent — still carries the same
incoming-push diagnostics, just now actually compiling.

## The real root cause, finally: a never-implemented state transition, on both ends, since day one

Build 13's real retest was the best result yet: both accounts hit `last_incoming_push_status:
"delivered_to_coordinator"` — full confirmation the entire incoming-push pipeline (push received
→ invite parsed → caller/session context fetched → handed to `TwilioVoiceAdapter`) now works
end to end. The owner could see and answer a real incoming call for the first time. But: "it
just sat in the calling mode and never connected," on the CALLER's screen, whether the recipient
answered *or* explicitly declined — a stuck-forever symptom regardless of outcome.

**Root-caused by reading, not guessing, once the incoming-push mystery was solved and the
remaining symptom pointed at local call-state handling instead of push delivery.**
`CallStateMachine.allowedTransitions` (`GotTimeCore`) defines the intended lifecycle as
`created -> outgoing -> ringing -> connected -> ...`, and `apply()` throws on any transition not
in that table. `TwilioVoiceAdapter.applyAndEmit` — the single choke point every `CallDelegate`
callback funnels through — wraps that `apply()` call in `try?`, so an invalid transition doesn't
crash, it just **silently does nothing**: no state update, no `.statusChanged` event, nothing.

Grepped the whole codebase for anywhere that actually performs the `created -> outgoing`
transition. **Nowhere does.** `request-call/index.ts` explicitly inserts new rows with
`status: "created"` and nothing — not `request-call`, not `TwilioVoiceAdapter.startCall`, not
any Edge Function — ever moves a session to `"outgoing"`. This one missing transition explains
everything observed, on both ends, and has been true since this code was first written (long
before tonight's testing began):

- **Caller side**: `activeSession.status` starts at `.created` (from `request-call`'s response).
  The first real event, `callDidStartRinging` → `applyAndEmit(.ringing, ...)`, calls
  `CallStateMachine.apply(.ringing, to: session)` where `session.status == .created` —
  `.created`'s only valid next states are `.outgoing`/`.failed`, so this throws, `try?` eats it,
  and `activeSession` never changes again. Every subsequent event (`callDidConnect`,
  `callDidDisconnect`) hits the same dead end forever — exactly a permanently-stuck "Calling..."
  screen, regardless of what the recipient does, because *nothing* the recipient does can ever
  successfully update `activeSession` again after the very first failed transition.
- **Recipient side, a related but structurally separate gap**: `TwilioVoiceAdapter.answer()`
  never set `activeSession` *at all* — only `activeCall` (the raw SDK `Call` object). So
  `applyAndEmit`'s own guard (`guard var session = activeSession, ...`) would find `nil` and
  no-op every single delegate callback on the recipient's own device too, independent of the
  caller-side bug — the same root gap (a missing/incorrect local session-state transition),
  reached via a different code path. This also explains why the owner's own screen "got stuck in
  calling mode" even on the *answering* end, not just the caller's.
- **`decline` had its own, more proximate compounding bug**: `performCallAction` resolves its
  session via `currentSession(matching:)`, which only ever checked `activeSession` — never set
  for an incoming call — so declining silently skipped calling `call-action` entirely (an early
  `return` inside `performCallAction`, no error, nothing to observe) even before the
  `CallStateMachine` question was reached. This is exactly the "looks fine, does nothing"
  failure class this session's diagnostics exist to catch, just in a spot no diagnostic had
  reached yet.
- **Server-side, the identical gap independently corrupted `call_sessions`'s own persisted
  history**: `twilio-status-callback`'s ringing/connected transitions and `call-action`'s
  `cancel` are all gated on the row already being `"outgoing"`/`"ringing"` — which, given the
  same missing transition, it never was. `ringing_at`/`connected_at` have been `null` on *every*
  call this entire project, confirmed directly from `call_sessions` going back to the very first
  real call — not a new regression, a bug that's been there the whole time, just never diagnosed
  because nothing before now needed those fields to actually work.

**Fixed all three manifestations of the one real gap, not three separate patches:**
1. `request-call/index.ts` now inserts new rows with `status: "outgoing"` directly (matching a
   test file's own long-standing comment — "already covered by request-call's own 'outgoing'" —
   that turned out to describe intent, not reality). Deployed via `npx supabase functions deploy
   request-call`. No migration needed — this is an application-code default, not a schema
   default; the column's own DB-level default stays `'created'`, harmless since this is now the
   only code path that ever inserts a row.
2. `TwilioVoiceAdapter.startCall` applies the same `created -> outgoing` transition to the
   session *locally* right after `request-call` returns, independent of trusting the exact
   server value — `CallStateMachine.apply`'s own check is what actually matters for
   `applyAndEmit` to accept the real events that follow.
3. `TwilioVoiceAdapter.answer` now promotes the incoming invite's session into `activeSession`,
   pre-advanced through `outgoing -> ringing` (both applied locally, since a call being answered
   has, by definition, already been ringing — and `callDidStartRinging` is never expected to
   fire on an *accepted* invite's own `Call` object the way it does for the caller's outgoing
   side, so there's no later event to wait for instead).
4. `decline` now calls `performCallAction` *before* clearing `pendingSession`/`pendingInvite`
   (reordered — it previously cleared first), and `currentSession(matching:)` now falls back to
   `pendingSession` when `activeSession` isn't set, so a decline's `call-action` invocation
   actually fires instead of silently short-circuiting.

All 44 backend tests still pass unmodified (the status-string change is real production
behavior in an adapter class documented from the start as "thin, untested pending a live
project" — its own pure logic underneath, `requestCall`, was never testing the specific status
string in the first place).

**This is very likely the actual, complete fix for the core mechanism** — every previous fix
this session (certificate, `UIBackgroundModes`, incoming-push diagnostics) was a real, necessary
step to even reach the point where this bug could surface and be observed at all, not wasted
work. Not yet confirmed on a real device, deliberately not claimed as done until it is.

## Build 14's real retest: the caller's side genuinely works now — first time all project

Real, unambiguous progress: the owner called his brother, and **a real countdown clock started
running on the caller's own screen** — something that had never once happened before tonight,
on any build. That confirms the `created -> outgoing` fix is correct and working exactly as
intended on the caller's side.

**The recipient's own screen, however, stayed on a spinner and never connected**, despite
answering. Before reaching for a fifth guess, reasoned through what this new result actually
rules out: the caller's own successful, sustained connection is only possible if Twilio's
infrastructure genuinely bridged the call — which requires the recipient's `invite.accept()` to
have actually been called and succeeded at the SDK/Twilio level. That rules out an earlier
theory floated internally (a UUID mismatch between Twilio's own `CallInvite.uuid` and this
app's `call_uuid` causing `pendingInviteMatching` to fail and `answer()` to throw before
`accept()` is ever reached) — if that were happening, Twilio would never have bridged anything,
and the caller's own countdown would never have started either. Directly checking a theory
against the evidence already in hand — and discarding it once it didn't hold up — rather than
shipping it anyway, matters here: it would have been a plausible-sounding but wrong fix, the
exact failure mode this project has already been burned by twice before (the original Supabase-
config crash).

**What the evidence actually supports**: the recipient's own device *did* successfully accept
and bridge the call, but something in how its own `CallDelegate` events (`callDidConnect`
especially) get processed afterward isn't updating its local state/UI — the same general
*class* of bug as the `created -> outgoing` gap (a local state transition silently not applying),
but not yet pinned to a specific cause. Rather than guess which of several plausible mechanisms
is responsible, added direct instrumentation to `applyAndEmit` (`TwilioVoiceAdapter`'s single
choke point for every `CallDelegate` callback, on *both* the caller's and recipient's device) —
it now reports exactly one of four outcomes to `profiles` (migration
`0009_call_event_diagnostics.sql`, same pattern/deployment as 0007/0008): `no_active_session`
(the guard's `activeSession` was nil), `uuid_mismatch` (a session existed but its `callUUID`
didn't match the event), `invalid_transition` (`CallStateMachine.apply` itself rejected it — the
same class of bug just fixed, possibly not fully), or `applied` (it worked). This directly
answers, with real evidence rather than another guess, which specific mechanism is still broken
on the recipient's side. Build 15. All 44 backend tests unaffected (no backend changes this
round).

## Build 15's real retest: `last_call_event_status` came back completely null — earlier than expected

Retested with a *different* recipient this time (the wife, not the brother) — same exact
symptom: she saw the answer/decline UI (confirming the incoming-push pipeline still works),
tapped Answer, and her screen sat on "Calling..." forever. The owner's own side connected and
ran a real countdown again, then he ended the call from his side — nothing happened on hers.

**The new diagnostic gave a real, if initially puzzling, answer**: `last_call_event_status` was
completely `null` for her — not `no_active_session`, not `uuid_mismatch`, not
`invalid_transition`, not `applied`. None of `applyAndEmit`'s four outcomes ever fired, meaning
no `CallDelegate` callback (`callDidConnect`, `callDidDisconnect`, anything) ever ran on her
device for this call — not even when the owner explicitly ended it from his side. Checked her
other diagnostics before concluding anything: `push_registration_status`/`last_incoming_push_status`
both show fresh, successful writes seconds before and during the call — ruling out a stale
auth session as the reason the diagnostic itself went silent. The gap is real, not an artifact
of the measurement.

**This means the failure is earlier in the call chain than `applyAndEmit`** — somewhere in
`answer()` itself, before any `CallDelegate` event could even be relevant. Revisited the theory
floated (and provisionally set aside) during build 14's investigation: a UUID mismatch between
Twilio's own SDK-generated `CallInvite.uuid` and this app's own `call_uuid`, which would make
`pendingInviteMatching` fail and `answer()` throw `noPendingInvite` *before* `invite.accept()` is
ever reached — `CallCoordinator.answerIncomingCall()`'s own `try?` would swallow that silently,
while its *unconditional* `activeCall = incoming.session` line (set before calling
`voiceService.answer()` at all) means the UI transitions to a "calling" screen regardless of
whether the underlying SDK call ever actually starts. That combination — a silently-thrown
`answer()` plus an unconditionally-optimistic UI update — would look *exactly* like what's been
observed, on two different people, across two different builds.

This theory was set aside during build 14 specifically because the caller's own successful,
sustained connection seemed to require the recipient's `accept()` to have succeeded at the
Twilio/SDK level. That inference may simply have been wrong — nothing has actually verified
*why* the caller's own `callDidConnect` fires, only that it does; it's possible Twilio's own
`<Dial>` signaling reaches a "connected" state for the caller's leg independent of whatever
happens (or doesn't) on the recipient's own local SDK object. Rather than keep reasoning about
it in the abstract a second time, **instrumented the actual point of uncertainty directly**:
`pendingInviteMatching` (the single method both `answer()` and `decline()` call before doing
anything else) now reports one of two new outcomes — `invite_matched` or `invite_not_pending`
(with the actual requested and currently-pending UUIDs in the detail, so a real mismatch would
be visible verbatim, not just inferred) — added as two more values on the same
`last_call_event_status` column (migration `0010_answer_decline_diagnostics.sql`, which had to
drop and recreate that column's check constraint to extend it — confirmed the real constraint
name via `pg_constraint` first rather than guessing Postgres's default naming convention was
right). Build 16. This is the most direct possible settlement of a question that's now been
raised, reasoned about, and set aside once already — this time with real evidence, either way.

## Confirmed: the UUID mismatch is real — and it explains the dead Cancel button too

Build 16's real retest settled it definitively. The wife's `last_call_event_status` came back
`"invite_not_pending"`, with the detail carrying both UUIDs verbatim:
`requested=0A98063A-A0F4-467D-9FA0-6B4D0F3E5DDE pendingInviteUUID=07C558D4-8399-4E6B-A5F0-2C6EAB32F6B7`
— genuinely different values. Not inferred, not assumed: read directly off the device.

**Root cause, now with certainty**: `callInvite.uuid` is generated by Twilio's SDK fresh on each
device when a VoIP push is parsed — it has no relationship whatsoever to
`call_sessions.call_uuid`, which is chosen only by the *caller's* device (`ConnectOptions.uuid`
in `startCall`) and simply persisted server-side. There was never a mechanism for these two
per-device, SDK-local identifiers to line up, and nothing in the original design accounted for
that — `CallCoordinator`/`TwilioVoiceAdapter` on the recipient's side were built assuming the
DB's `call_uuid` was a valid matching key for the incoming `CallInvite`, when it never could be.

This single gap explains **both** symptoms reported after build 14 and build 16: `answer()`
throws `noPendingInvite` immediately (since `pendingInviteMatching` can never succeed),
`invite.accept()` is never reached, so `TwilioVoiceAdapter.activeCall` never gets set on the
recipient's device at all — which is *also* exactly why the owner's report that "the cancel
button doesn't do anything" on the stuck screen makes sense: `cancel()`'s
`disconnectActiveCall(matching:)` guard (`let call, call.uuid == callUUID`) fails because `call`
(`activeCall`) is `nil`, throws `noActiveCall`, and `CallCoordinator.endActiveCall()`'s own
`try?` swallows it silently. One root cause, two visible symptoms.

**Fix**: `PushKitAdapter.callInviteReceived` now constructs the `CallSession` handed to
`TwilioVoiceAdapter.handleIncomingCallInvite` with `callUUID` overridden to `callInvite.uuid`,
rather than the server's original `call_uuid`. Confirmed safe before making this change, not
assumed: grepped every use of `callUUID`/`call_uuid` across the iOS app — it's used exclusively
as a local `VoiceService` protocol matching key (`answer`/`decline`/`cancel`/`endEarly`,
`.callEnded(callUUID:)`); never sent to the server (which correlates everything via
`session.id`, the actual DB primary key — see the `callSessionId` custom parameter, unrelated to
this field) and never rendered in any UI. Overriding it purely for this device's own local
SDK-object matching has no other effect anywhere else in the app.

With this fix, the entire chain becomes internally consistent on the recipient's device:
`pendingInviteMatching` succeeds → `invite.accept()` is genuinely called for the first time →
`activeCall`/`activeSession` (pre-advanced through `outgoing -> ringing`, from build 14's fix)
get set correctly → `callDidConnect` finds a matching `activeSession` → `applyAndEmit` succeeds
→ `.statusChanged` reaches `CallCoordinator` → the countdown starts. `cancel`/`endEarly` now
also have a real `activeCall` to find, so the Cancel/End button should work on the recipient's
side too, not just the caller's.

Build 17. This is very likely the complete, final fix for two-way real-device calling — every
prior build this session was a genuine, necessary step toward being able to observe and fix
this exact bug, not wasted effort. Not yet confirmed on a real device.

## Build 17 confirmed: full two-way signaling finally works. Three new, real gaps found and fixed.

Real retest: calls now connect and hang up correctly from *either* side, in both directions —
the core mechanism this entire session has been chasing since Phase 4 began. The owner reported
three remaining issues, investigated and fixed one at a time rather than guessed at together.

**1. No audio in either direction.** Grepped the whole iOS app for any `AVAudioSession`/
microphone-permission handling beyond `TwilioVoiceSDK.audioDevice = DefaultAudioDevice()` (set
once in `TwilioVoiceAdapter.init`) and the speaker-routing override in `setSpeakerEnabled` —
nothing anywhere ever explicitly requested microphone access.
`INFOPLIST_KEY_NSMicrophoneUsageDescription` (added earlier this session) only supplies the
system prompt's *text*; it doesn't trigger the prompt itself. Without an explicit, resolved
grant before a call starts, `AVAudioSession`'s `.playAndRecord` activation (which
`DefaultAudioDevice` performs internally, with no CallKit integration to do it a different way)
can silently fail to produce a working audio route in *either* direction — consistent with the
owner's report that neither side could hear anything, not just "he can't hear me." Fixed by
calling `AVAudioApplication.requestRecordPermission` (the iOS 17+ API, matching this project's
deployment target) once, early, alongside the existing push-registration trigger in
`ContentView` — well before any call could plausibly happen, so the system prompt is already
resolved by the time one does.

**2. The two participants' countdown timers visibly desync**, worse the longer the recipient
takes to answer. Root cause: each device stamps `connectedAt` from its *own* local clock at the
exact moment its *own* `callDidConnect` fires — and the recipient's device reaches that moment
later than the caller's, by however long push delivery, invite parsing, database lookups, human
reaction time, and SDK negotiation take on their end (all real, unavoidable latency on the
receiving side). This isn't a bug in the sense of "wrong code" so much as an architectural gap:
the original design (see the very first `twilio-status-callback` entry in this file) always
intended `connected_at` to be a single, server-recorded, authoritative timestamp both devices
agree on — "not just trusted from the client's own clock" — specifically to prevent this.

**3. Investigating (2) surfaced why that server-side design had never actually been working**:
Twilio's real event name for a `<Client>` leg being answered is **`"in-progress"`**, not
`"answered"` — confirmed directly from Twilio's own call Events API on this exact successful,
hung-up call (`ringing` → `in-progress` → `completed`, POSTed verbatim to this project's
`twilio-status-callback` webhook, which responded 204 both times). `planStatusTransition`'s
`switch` had a case for `"answered"` that could simply never match anything Twilio actually
sends — a silent no-op indistinguishable from the *deliberate* `initiated`/`completed` no-ops
right next to it, which is exactly why it went unnoticed this long: `call_sessions.connected_at`
had been `null` for literally every call this entire project, even ones that genuinely
connected and were hung up normally, and nothing about that was visibly wrong until this
specific investigation went looking for it. Fixed the event name
(`ClientCallStatus`/`planStatusTransition` and their test), which — as a side effect — is also
what makes fix (2) below possible at all.

**Fix for (2), now that (3) makes it real**: `TwilioVoiceAdapter.applyAndEmit`, once a
`.connected` transition succeeds, kicks off `reconcileConnectedAt` — a short-lived, retrying
fetch (5 attempts, 400ms apart, since this is racing an independent webhook delivery with no way
to await it directly) of the real `call_sessions.connected_at` from the server, then corrects
the locally-tracked session and re-emits `.statusChanged` with the authoritative timestamp. Both
devices end up computing their countdown from the same server-recorded instant. Best-effort by
design: if the webhook is slow or never lands, the original locally-stamped time stands rather
than leaving the countdown stuck — a reasonably-close approximation, not a broken state.

**Also folded in the owner's own feature request** (asked mid-investigation, unrelated to the
bugs above): four new duration presets — 15s, 30s, 1 min, 3 min — alongside the existing 5/10/
15/20/30-minute set and Custom. 15s/30s fall below the original 60-second (1-minute) floor
entirely, so `request-call`'s `MIN_DURATION_SECONDS` and the `call_sessions` CHECK constraint
(`0011_lower_duration_minimum.sql`) were both lowered to 15 seconds — the three-layer
duration-enforcement design (client/server/DB) stays in agreement, just at a new floor.
Deliberately minimal, additive changes: `DurationPolicy.presetMinutes` (5/10/15/20/30) is
untouched, with its own test still passing unmodified; a new `presetSeconds` array (15/30/60/
180) sits alongside it, and `DurationPickerView` merges both into one seconds-denominated,
sorted list for a single grid rather than maintaining two parallel UI paths. Custom text entry
still asks for whole minutes (1-60), unchanged — the owner didn't ask to change that entry
method, only to add fixed short presets.

Build 18. All 44 backend tests pass (updated for the new duration floor and the `in-progress`
event name). Not yet confirmed on a real device — in particular, `reconcileConnectedAt`'s retry
timing and the audio permission fix are both new enough to warrant a real test before treating
either as settled.

## Build 18 retested: mic permission alone didn't fix audio, and the timer still desynced — both traced to their real causes, not guessed at again

The owner retested build 18. Both issues persisted: still no audio in either direction, even
after explicitly granting the microphone permission prompt on both phones; the caller's
countdown still started immediately, unaffected by the recipient's actual answer time.

**Audio: verified against Twilio's own documentation before touching code again**, rather than
guess a second time after the permission fix alone didn't work. Search directly confirmed the
real mechanism: *"If you are not using CallKit in your app, you must not set
ConnectOptions.uuid or AcceptOptions.uuid while making or answering a call. The Voice SDK will
enable the audio device for you when the uuid is nil."* This project has forced both of those
since Phase 4 (`builder.uuid = session.callUUID` in `startCall`, `builder.uuid = invite.uuid` in
`answer`) — originally so Twilio's own `Call`/`CallInvite` uuid would agree with this app's own
`call_uuid` for local matching purposes, with no idea this also happened to be *the exact signal
that tells the SDK "this app manages CallKit's own audio-session activation."* Since this
project has never implemented CallKit's audio-activation delegate methods (`provider(_:
didActivate:)`/`didDeactivate:`) — deliberately, CallKit integration is still deferred — the
SDK's own automatic audio-device activation was silently disabled this entire time, on both the
caller's and recipient's side, regardless of microphone permission being granted. This explains
why granting the permission didn't help: the permission was never the blocker: the audio device
itself was never being turned on at all.

**Also checked, not assumed, before changing anything**: whether the resulting accepted/
connected `Call`'s own `.uuid` is still safe to rely on once no longer forced. A Twilio SDK
migration guide confirms *"The `uuid` property of `TVOCall` is now optional"* — meaning once
`ConnectOptions.uuid`/`AcceptOptions.uuid` are left nil, `Call.uuid` may simply stay nil
indefinitely, not just briefly-nil-then-populated as the existing `guard let uuid = call.uuid
else { return }` code defensively assumed. Continuing to match `CallDelegate` callbacks against
`call.uuid` after removing the forced assignment would have meant every callback silently
no-op'ing forever (`call.uuid` nil, guard always failing) — a different but equally complete
break, not a partial one.

**Fix: stopped forcing `ConnectOptions.uuid`/`AcceptOptions.uuid` entirely, and redesigned every
local matching path in `TwilioVoiceAdapter` to never depend on Twilio's own uuid fields again:**
- `applyAndEmit` (the single choke point every `CallDelegate` callback funnels through) now
  matches by **Call object identity** (`activeCall === call`), not any UUID field — strictly
  more reliable than a field that may not even be populated, and correct given this adapter only
  ever tracks one `activeCall` at a time by design.
- `pendingInviteMatching` (used by both `answer`/`decline`) now compares against
  `pendingSession?.callUUID` — this app's own value, which `CallCoordinator` already threads
  through unchanged — instead of `pendingInvite?.uuid`. This is the exact field that caused the
  build-16 UUID-mismatch bug in the first place; comparing two values this app controls end to
  end makes the match correct by construction, not by coincidence of what Twilio happens to
  assign.
- `disconnectActiveCall` (used by `cancel`/`endEarly`) now compares against
  `activeSession?.callUUID` instead of `activeCall?.uuid`, same reasoning.
- `clearIfActive` now compares by object identity instead of `.uuid` equality.
- `handleCancelledCallInvite` still matches the *incoming* cancellation notice by `callSid`
  (Twilio's own call identifier — reliable, and a completely different field from `.uuid`,
  unaffected by any of this), but now emits `pendingSession?.callUUID` (this app's own value)
  rather than `pendingInvite?.uuid` — a real bug that would have been reintroduced by reverting
  the `PushKitAdapter` override below without also fixing this emission site to match.
- **Reverted the `PushKitAdapter.callInviteReceived` override added in build 17** (which had
  rewritten the incoming session's `callUUID` to `callInvite.uuid` specifically so it would
  match Twilio's own field). That workaround is no longer needed — nothing anywhere in
  `TwilioVoiceAdapter` reads Twilio's own uuid fields for matching anymore — and removing it
  means the recipient's local session no longer depends on a Twilio-internal field being
  reliably populated at all.

**Timer desync: confirmed via real server data exactly why the build-18 fix "didn't work."**
Checked `call_sessions` for the owner's actual failed retest: `ringing_at` to `connected_at` was
about **6 seconds** — the real time it took to answer. `reconcileConnectedAt`'s retry window was
5 attempts × 400ms = 2 seconds total, well short of that. It wasn't silently broken; it was
timing out before the webhook (correctly, per the build-18 "in-progress" fix) had even landed.
Confirmed `connected_at` genuinely IS being recorded server-side now — the mechanism works, the
window was just too short for a realistic answer delay. Widened to 60 attempts × 1s (a full
minute), comfortably covering any plausible ring/answer window.

**Known, deliberately-deferred follow-up, not silently ignored**: `setSpeakerEnabled` replaces
`DefaultAudioDevice`'s entire `block` closure with one that only calls
`overrideOutputAudioPort`, discarding whatever the SDK's own default block was doing for the
underlying `AVAudioSession` category/mode setup (Twilio's docs describe the correct pattern as
providing a block that sets `.playAndRecord`/mode/options *and* the desired output route, not
replacing wholesale). Not touched this round since it's user-triggered only (tapping the speaker
button), not the cause of the current "no audio from the start of any call" report, and fixing it
without being certain of the exact right category/mode/options values would risk exactly the
kind of guess this project has learned not to make. Worth a real look once the current fix is
confirmed and speaker toggling is specifically tested.

Build 19. All 44 backend tests still pass (no backend changes this round). Not yet confirmed on
a real device.

## Build 19 confirmed: audio works, timer syncs, calls auto-end at zero — Phase 4/6's core mechanism is real

The owner retested and confirmed all three fixes: real two-way audio, the countdown correcting
itself to the server's authoritative `connected_at` once reconciliation lands (visible as a
brief reset from the caller's own optimistic guess — expected behavior, not a bug, though worth
smoothing visually later so it doesn't read as a glitch), and the call genuinely disconnecting
once the timer reaches zero. This is the actual core deliverable this whole build has been
working toward since Phase 4 began.

**One real display bug found testing a 15-second call**: the recipient's incoming-call screen
showed "0 minutes." Root cause, found immediately: both `IncomingCallView` and `HistoryView`
computed `requestedDurationSeconds / 60` directly — integer division, so anything under 60
seconds truncates to 0. Neither the underlying timer math (`CallTimer`, already purely
second-based) nor the live countdown (`CountdownView`, already `"%d:%02d"`-formatted) had this
bug — only the two places that had never needed to display a sub-minute value before tonight's
new short presets existed.

**The owner also asked for the fuller feature this was pointing at**: real, arbitrary-duration
calls — "5 seconds," "1 minute and 12 seconds," anything — not just a fixed set of presets.
Checked what this actually required across the stack before touching anything: `request-call`'s
validation and the `call_sessions` CHECK constraint already only bound `requested_duration_seconds`
to an integer range (15-3600, from the preset-lowering work two builds ago) with no requirement
that it be a whole minute — so no backend or schema change was needed at all, only the client's
own custom-entry UI, which had never been asked to produce anything but whole minutes.

**Added to `GotTimeCore.DurationPolicy`** (additive — `validateMinutes`/`parseCustomMinutes`,
still used by their own existing tests, are untouched): `validateSeconds` (the real 15-3600s
bound), `parseCustomDuration(minutesText:secondsText:)` (parses two separate fields, either
blank meaning zero, rejecting anything non-numeric or a seconds value outside 0-59 rather than
silently reinterpreting "90 seconds in the seconds field" as 1:30), and `formatDuration(_:)` — one
shared formatter ("15 seconds", "5 minutes", "1 minute 12 seconds", omitting a zero seconds
component) now used by `IncomingCallView`, `DurationPickerView`'s confirm-button title, and
`ActiveCallView`'s post-call summary (replacing three slightly different ad hoc
implementations, one of which was the actual "0 minutes" bug). `HistoryView` keeps its own
terser "5m 12s" style formatter for visual consistency within that screen, just pointed at the
correct (`requestedDurationSeconds`) value instead of the buggy truncating one.

**`DurationPickerView`'s custom entry rebuilt as two fields** (minutes, seconds) instead of one
whole-minutes-only text field — two separate numeric-keyboard fields rather than a single
"MM:SS" text field, simpler to type into correctly on each side. Wrote `parseCustomDuration`'s
internal parsing defensively (a small `nonNegativeIntOrZero` helper) rather than a ternary
mixing `Int` and `Int?` inline — technically legal Swift (optional-promoting ternaries are a
real, supported pattern) but avoided anyway given there's no local Swift compiler to confirm it,
matching this project's established caution around exactly this class of mistake.

Build 20. GotTimeCore's own test suite extended for every new function (bounds, parsing,
formatting) rather than just trusted by inspection. Not yet confirmed on a real device.

## Build 20 confirmed working; owner asked for declined-vs-missed — found it was already designed, just never correctly wired

The owner confirmed build 20 end to end (0-minute bug gone, custom minutes+seconds entry
works), then asked for two things about the CallKit work about to start: the lock screen must
show the requested duration (already anticipated in this project's own original plan — compose
it into `CXCallUpdate.localizedCallerName`, e.g. "Thunder • 10 min", since CallKit has no
reliable separate pre-unlock subtitle field) and, separately, the ability to tell a call the
recipient explicitly declined apart from one nobody answered.

**Checked before writing anything**: `CallStatus` has had `.declined` and `.missed` as distinct
cases since Phase 1, `CallStateMachine.allowedTransitions` already treats them as distinct valid
transitions from `.ringing`, and `ActiveCallView.summaryTitle` already has distinct text for
both (`"\(name) declined"` / `"No answer"`). The entire *design* for this was already in place —
what was missing was `TwilioVoiceAdapter` ever actually producing `.missed`, or correctly
attributing `.declined`, from a real call.

**Root cause**: `callDidDisconnect`'s fallback logic only ever produced `.failed` (error) or
`.endedEarly` (was connected) — a clean disconnect that never connected always became `.failed`,
whether that was the recipient explicitly declining, the recipient simply never answering, *or*
the caller's own explicit Cancel action (which also had no distinct outcome — tapping Cancel
showed "Call failed," not "Call canceled"). None of this was reachable from the delegate
callback's own signal alone: Twilio's `Call` object just reports "disconnected," with no
built-in way to distinguish these cases.

**Fix, in two parts**:
1. **Local actions get an authoritative label immediately.** Added `pendingLocalOutcome`,
   set by `cancel()`/`endEarly()` *before* calling `disconnectActiveCall` — so when
   `callDidDisconnect` fires moments later, it already knows this exact disconnect was a
   deliberate local action, not something to infer. This also incidentally fixes "Cancel" showing
   the wrong terminal state, a real but previously-unnoticed bug.
2. **The recipient-declined case needs the server, not guessing.** The recipient's own explicit
   decline is already recorded authoritatively server-side (`call-action`'s existing `"decline"`
   handler, itself fixed a few builds ago) — but the *caller's* device has no direct signal for
   it. `callDidDisconnect` now defaults an un-explained, never-connected disconnect to `.missed`
   (only when the session had actually reached `.ringing` — `CallStateMachine` doesn't allow
   `.missed` from `.outgoing`, so a disconnect before ever ringing correctly stays `.failed`, the
   original safe behavior for that narrower case), then kicks off `reconcileFinalOutcome`: a
   short (5×500ms) check of the server's real `call_sessions.status`, correcting the emitted
   session to `.declined` if that's what actually happened. Unlike `reconcileConnectedAt`'s
   minute-long window (waiting out realistic human reaction time), a decline is either recorded
   within a second or two of the disconnect or it never was one — no equivalent delay to wait
   out here.

`reconcileFinalOutcome` runs *after* `activeCall`/`activeSession` are already cleared (the call
has genuinely ended by this point), so — unlike every earlier reconciliation this session —
it can't rely on this adapter's own state still matching anything. It works entirely from an
`originalSession` snapshot captured before clearing, and emits a freshly-constructed corrected
`CallSession` directly; `CallCoordinator` matches purely on that session's own `callUUID`, not on
anything this adapter still holds, so this is safe.

Build 21. All 44 backend tests unaffected (no backend changes this round — `call-action`'s
`"decline"` path was already correct). Not yet confirmed on a real device; genuinely hard to
test deliberately (requires timing a real decline vs. letting a real call simply ring out), so
this is one to specifically exercise both ways next time, not just retest the things already
proven working.

## Phase 5: CallKit lock-screen integration, and why it needed an AppDelegate change too

Owner confirmed build 21 fully, then set the requirement for this phase directly: "when this
pops up on the lock screen, I want you to be able to see how much time the person is requesting
and be able to answer or decline the call" — plus, separately, "we have plenty of time to
execute this... let's get it right," an explicit instruction to prioritize doing this properly
over doing it fast, which is why the AppDelegate/early-registration piece below was built now
rather than deferred as a follow-up.

**New: `CallKitAdapter`** (`ios/App/Integrations/CallKitAdapter.swift`), a `CXProvider`/
`CXProviderDelegate` wrapper, scoped deliberately to incoming calls only — the caller's own
outgoing-call side already works correctly without CallKit (confirmed on real devices in Phase
4), and routing it through CallKit too is a real, separate follow-up nobody has asked for yet.
`reportIncomingCall(_:)` reports a placeholder to CallKit synchronously the moment a VoIP push
arrives (Apple can terminate an app that doesn't honor this timing); `updateReportedCall(...)`
corrects it once the caller's real name and the session's requested duration are known from an
async database lookup, composing both into one `localizedCallerName` — e.g. "Thunder • 10 min"
— since CallKit has no reliable separate subtitle field shown before the phone unlocks (this
exact design was anticipated in the project's original build plan, not improvised here).
`CXAnswerCallAction`/`CXEndCallAction` route straight into `TwilioVoiceAdapter.answer`/
`.decline`/`.endEarly`; `CXEndCallAction` tries `decline` first and falls back to `endEarly`
since one action covers both "decline before answering" and "hang up a connected call," and
`TwilioVoiceAdapter`'s own tracked state already knows which is valid without this adapter
duplicating that logic.

**Audio activation had to move from the SDK to CallKit for this path.** Every integration detail
here was checked against Twilio's own official quickstart source before writing it, not assumed
from the build-18/19 fix (see that entry above) — that fix's own reasoning still holds
(`ConnectOptions.uuid`/`AcceptOptions.uuid` tells the SDK "this app manages audio activation,"
disabling the SDK's automatic activation), but this time there *is* a `CXProviderDelegate` to
manage it correctly. `AcceptOptions.uuid` is reintroduced in `TwilioVoiceAdapter.answer` — safe
now, paired with `CallKitAdapter.provider(_:didActivate:)`/`didDeactivate:` toggling
`DefaultAudioDevice.isEnabled`, unlike the build-18 regression where the same setting was forced
with nothing to pair it with. Outgoing calls are untouched and still rely on the SDK's own
automatic activation, which already works.

**This does not reintroduce the build-16/17 uuid-matching bug.** Nothing in `TwilioVoiceAdapter`
reads `Call.uuid`/`CallInvite.uuid` for matching purposes — `applyAndEmit` still matches by Call
object identity, and `pendingInviteMatching`/`disconnectActiveCall` still match against this
app's own `call_uuid`. `CallKitAdapter` is the *one* place CallKit's own uuid space (keyed by
`CallInvite.uuid`, since that's what `reportNewIncomingCall` is given) is bridged to this app's
own `call_uuid`, via a small `pendingAppCallUUIDs` dictionary filled in once the async
caller/session lookup completes.

**New: `GotTimeAppDelegate`** (`ios/App/GotTimeAppDelegate.swift`), replacing `GotTimeApp`'s
previous plain `.environment()` construction via `@UIApplicationDelegateAdaptor`. Moves VoIP
push registration from `ContentView`'s `.task` (gated on sign-in, which needs a view to have
rendered) to `application(_:didFinishLaunchingWithOptions:)` — true app-launch time. This matters
specifically for the scenario CallKit exists for: a fully *terminated* app woken solely by an
incoming VoIP push has no rendered `ContentView` yet, so a `.task`-based registration can never
run in time, but `PKPushRegistry` needs to already be set up for the push to be delivered at all.
Safe to call unconditionally before sign-in — only the later Twilio-side device-token
registration needs auth, and that's already deferred correctly inside its own delegate callback.
`TwilioVoiceAdapter.events`' `AsyncStream` defaults to unbounded buffering, so an incoming call
handled this early (reported to CallKit, possibly even answered) isn't lost before
`CallCoordinator` exists to consume it — events queue and replay in order the moment its `init`
starts consuming the stream on the same cold launch.

**`CallCoordinator.handle(_:)` made properly reactive**, fixing a real gap rather than adding a
special case for CallKit: `.statusChanged`/`.callEnded` previously only recognized a call as
"this device's own incoming call" if `answerIncomingCall()` had already optimistically promoted
it to `activeCall` — true for the in-app Answer button, never true for CallKit's native Answer
action (which calls `voiceAdapter.answer(callUUID:)` directly). Both cases now also check
`incomingCall` and promote it reactively when needed. This incidentally fixes a second,
previously-accepted gap too: a cancelled/declined incoming call that was never promoted now
correctly clears `incomingCall`, instead of leaving a stale banner/lock-screen call that never
auto-dismissed.

**Checked and confirmed no additional entitlement/Info.plist change is needed for CallKit
itself** — `UIBackgroundModes` already includes `voip` (Config/Info.plist, from Phase 4), and
CallKit's `CXProvider` needs no separate capability declaration beyond that.

Build 22. Every file was re-read in full after writing, for internal consistency, since there is
still no local Swift toolchain to compile-check any of this — CI's `macos-latest` runner remains
the only real compiler. Not yet confirmed on a real device; this build specifically needs a
deliberate locked-screen (and ideally fully force-quit) test, since that's the exact scenario it
exists for, not just a repeat of the foreground tests already proven working in Phase 4.

**Build 22 failed CI outright** — a real compile error, exactly the class of mistake manual
re-reading can't reliably catch: `GotTimeAppDelegate`'s stored property initializer,
`let environment: AppEnvironment = Self.resolvedEnvironment()`, doesn't type-check. Swift
disallows referencing the covariant `Self` type from a stored property initializer — a
restriction that applies even to a `final` class, where `Self` and the concrete type are always
identical at runtime; the type-checker rejects it anyway, since a property initializer is
evaluated before `self`'s metatype is considered fully established, regardless of finality. Fixed
by calling `GotTimeAppDelegate.resolvedEnvironment()` explicitly instead of through `Self`. No
other errors appeared in the same CI run. Build 23.

## Build 23's real device test: CallKit itself worked, but it surfaced two real, unrelated gaps

The owner tested build 23 on a real locked phone (their wife's) for the first time: **answering
from the lock screen via CallKit's native UI worked** — the actual core deliverable of Phase 5.
But the same test surfaced three separate findings, only one of which was actually about CallKit:

1. No visible countdown on the CallKit-answered side.
2. When the timer reached zero, the caller's own screen moved on to its post-call summary, but
   the *real phone call* on the recipient's side (answered via CallKit from the lock screen) kept
   running — audio never stopped.
3. History showed only placeholder-looking entries, not anything from the calls just made.

**Finding 2 was the serious one, and root-caused by grep, not guessed.** Searching this codebase
for `.timedOut` (the `CallStatus` case that represents "reached its full duration") turned up
exactly one producer: `MockVoiceService.scheduleAutoExpiry`. Nothing in `TwilioVoiceAdapter` — the
real adapter — had ever produced it. That means the "the call auto-ended at zero, so that worked
too" the owner reported back in Phase 4 testing (build 19/20) was never actually driven by any
real enforcement mechanism in this codebase; it's unclear exactly what ended that earlier test
call (most likely the caller tapping End around the same moment, or Twilio's own
`<Dial timeLimit="...">` on the dialed leg — `twiml-voice/logic.ts` does set this — happening to
line up), but this test proves conclusively that neither is a *reliable* mechanism: the caller's
device showed the summary screen, and the actual Twilio call, on the actual phone that answered
it, did not hang up.

This matters more, not less, because of CallKit: a CallKit-answered call on a locked phone has no
SwiftUI view of this app's own on screen at all (Apple's native call UI owns that surface until
the user unlocks) — so any enforcement mechanism that depended on a *view* being rendered (a
`.onChange`, a per-screen timer) could never have worked for exactly this scenario, the one Phase
5 exists for. The real fix has to live in `TwilioVoiceAdapter` itself, independent of any UI.

**Fix**: `applyAndEmit`'s existing `if status == .connected` block (which already schedules
`reconcileConnectedAt`) now also calls a new `scheduleAutoExpiry(callUUID:connectedAt:
requestedDurationSeconds:)` — computes `CallTimer(connectedAt:requestedDurationSeconds:)
.remainingSeconds(at: .now)`, sleeps that long, then calls a new `disconnectForTimeout(callUUID:)`.
This mirrors `MockVoiceService.scheduleAutoExpiry` deliberately — that function's own doc comment
already said it "mirrors the real system's primary enforcement layer," a promise this codebase
had never actually kept until now. `disconnectForTimeout` applies `.timedOut` then `.completed`
locally (via the same `applyAndEmit` choke point, in that order) *before* calling
`call.disconnect()` — so that when Twilio's own `callDidDisconnect` fires moments later,
`activeSession` is already terminal and `CallStateMachine` correctly rejects
`callDidDisconnect`'s own now-irrelevant guess at an outcome as an invalid transition, rather than
the two racing to double-report how the call ended. Because this lives in `applyAndEmit` — the
same choke point both the caller's and the recipient's own `TwilioVoiceAdapter` instance run
independently — each participant's own device now enforces its own hangup at zero, with zero
dependency on whether any view is on screen. `<Dial timeLimit>` remains in place as a genuine
secondary layer, but is no longer assumed to be sufficient on its own — see the pre-existing
three-layer design in the original build plan; this makes the client-side layer, the primary one,
actually real for the first time.

**Finding 1 (no visible countdown while locked) is a real platform constraint, not (yet) a bug to
fix**: Apple's own native CallKit call screen — the only thing visible on a locked phone until the
user unlocks — has no built-in "time remaining" display; it shows elapsed call duration, the same
as the standard Phone app, and there is no supported way to replace that with a countdown. The
`localizedCallerName` label (already composed as "Name • Duration" at ring time) *could* be
refreshed periodically post-connection via `provider.reportCall(with:updated:)` to show a live
countdown even pre-unlock, but that's a real, separate feature with its own design questions
(update cadence, whether replacing the caller's name text with a ticking number is even wanted) —
not implemented this round; left for the owner to weigh in on rather than guessed at. The in-app
countdown (`ActiveCallView`/`CountdownView`) itself needs no fix — it was already correctly wired
to `CallCoordinator.remainingSeconds`, which is computed fresh from `connectedAt` the moment that
gets set, regardless of how the call was answered.

**Finding 3 (History showing placeholder data) was a known, already-documented scoping gap, not a
new bug**: `CallHistoryService` had been the one service deliberately left on `MockEnvironment`
since Phase 1 while the much harder voice/CallKit work took priority (see
`AppEnvironment.swift`'s own doc comment, and `BUILD_STATUS.md`'s Phase 4/5 entries, both of which
already said this plainly) — so every History screen the owner has seen so far was always the
mock's seeded data, never anything from a real call. Fixed now that voice + CallKit are both
working end to end and there's real data worth showing: added `SupabaseCallHistoryAdapter`
(`ios/App/Integrations/`), reading `call_sessions` directly (RLS already scopes results to the
signed-in user, so no additional filter is applied — same reasoning as
`SupabaseConnectionAdapter`), resolving each entry's other-participant profile the same
batch-fetch way `SupabaseConnectionAdapter.fetchConnections` already does. Wired into
`AppEnvironment.live()` in place of `mockEnv.callHistoryService`, which made the `mockEnv` local
in that function unused — removed entirely rather than left as dead code.

Build 24. All 44 backend tests unaffected (no backend changes this round). Every file re-read in
full after writing, for internal consistency, per this project's own established practice with no
local compiler. Not yet confirmed on a real device — needs the same locked-phone/CallKit test as
build 23, this time specifically watching that the call actually ends (audio stops) on the
answering phone when the timer reaches zero, and checking that History now shows the real calls
just made.

## Build 24 confirmed; owner asked for a live countdown and a call topic

The owner confirmed build 24 (auto-hangup and real History both working), then asked for two
more things: "the person receiving the phone call definitely needs to be able to know how much
time is left" (a live ticking countdown, not just the static duration already shown), and a
caller-typed topic — "Steven's calling. He needs 1 minute of my time, and it's about dinner
tonight" — shown alongside name and duration.

**Researched before writing anything, since this touches a real Apple platform constraint no
amount of careful reading can substitute for.** A web search on `CXProvider.reportCall(with:
updated:)` — the only mechanism that could update the lock-screen label live — turned up multiple
long-standing Apple Developer Forum threads (e.g. "localizedCallerName is not updated in iOS
17.2," "CallKit is not get updated on iPhone 14 with Dynamic Island," and a separate report that
the same problem persists into iOS 18 on an already-*active* call, "currently being investigated"
by Apple) describing exactly this: updating a `CXCallUpdate` on a call already in progress
frequently fails to visibly refresh on real hardware, with no confirmed fix as of this writing.
This isn't a guess or an assumption carried over from memory — it's the one piece of this
project's entire CallKit integration where the *documented, current, real-world* behavior of the
platform itself is genuinely uncertain, unlike everything else in `CallKitAdapter` (all of which
was checked against Twilio's own quickstart and Apple's own API contracts and found reliable).

Separately: does answering a CallKit call bring this app's own UI to the foreground, where the
already-correct in-app countdown could be seen instead? Also researched, not assumed — the answer
is conditional: video calls generally do; for audio-only VoIP specifically, "it's not guaranteed,"
and explicitly "if the device can't be unlocked, then the call will be answered and stay in the
lock screen UI" for the whole call. This matches exactly what the owner already reported after
build 23 (answered from a locked phone, no countdown ever visible) — the phone likely never
actually unlocked, so this app's own screen never had a chance to show anything.

**Decision: build the live-updating label anyway, but document the real uncertainty rather than
presenting it as guaranteed to work.** The owner explicitly asked for it, the cost of adding a
once-per-second `reportCall(with:updated:)` call is low even if it turns out to not visibly
refresh on the phones in question, and the fallback (the in-app countdown, once/if the phone is
actually unlocked) already works correctly regardless. See `CallKitAdapter`'s own top-level
comment for the same caveat, kept next to the code it describes.

**Implementation.** `CallKitAdapter` now tracks each call with a small `TrackedCall` struct
(callerName/topic/requestedDurationSeconds) keyed by callKitUUID, plus a reverse
appCallUUID-to-callKitUUID map — needed because `VoiceEvent`s (which drive the countdown) carry
this app's own `callUUID`, never CallKit's. A new `handle(_ event: VoiceEvent)` method starts a
per-second ticking `Task` the moment a `.statusChanged` event reports `.connected`, computing
remaining time from `CallTimer` anchored to the *first* locally-observed `connectedAt` (not any
later server correction from `reconcileConnectedAt` — deliberately, so this stays consistent with
`TwilioVoiceAdapter.scheduleAutoExpiry`'s own real hangup timer, which anchors the same way for
the same reason: two independent timers racing from different anchors would be worse than one
consistent anchor used by both). The label composes name + remaining time + topic (when present)
into one string, e.g. "Thunder • 4:32 left • Dinner tonight," ticking every second until the call
ends.

**This surfaced — and fixed — a real, separate gap unrelated to the countdown itself.** For the
ticking task to know when to *stop*, and for CallKit's own native call screen to actually dismiss
promptly, `CallKitAdapter` needs to learn the instant a call ends for *any* reason, not just the
reasons it initiated itself (a user tapping the native "End" button, which already calls
`CXEndCallAction` and needs no further notification). Before this build, nothing told CallKit
when: the caller hung up remotely, or — the new, more urgent case — `TwilioVoiceAdapter`'s own
`scheduleAutoExpiry` (added in build 24) silently disconnected the call from underneath it. Without
a fix, the recipient's lock screen would have kept showing a live "in call" screen with a frozen
countdown, or worse, kept ringing, well after the real call had already ended. Fixed by giving
`TwilioVoiceAdapter` a new `onVoiceEvent: ((VoiceEvent) -> Void)?` closure property, invoked
synchronously from a new shared `emit(_:)` helper alongside every existing `continuation.yield`
call. **Deliberately a closure, not a second `for await` loop over `events`**: `AsyncStream`
delivers each element to whichever single consumer is currently awaiting `next()` — two
independent consumers (`CallCoordinator` and `CallKitAdapter`) iterating the same stream would
each receive a random subset of events, not both receiving every one, which would have been a
subtle, hard-to-reproduce bug rather than a clean fix. `AppEnvironment.live()` wires
`voiceAdapter.onVoiceEvent = { [weak callKitAdapter] event in callKitAdapter?.handle(event) }`
once both are constructed — a closure specifically to avoid the circular-construction-order
problem a stored reference in either direction would have created (`CallKitAdapter` already needs
`TwilioVoiceAdapter` to exist first).

`CallKitAdapter.endReportedCall` was made idempotent as part of this (guarded on a new
`reportedCallKitUUIDs` set, separate from the caller-info `trackedCalls` map, since a call can be
reported to CallKit — and later need ending on a lookup failure — before any of the rest of its
info is ever known) — needed because a locally-initiated `CXEndCallAction` and the resulting
`VoiceEvent` from `TwilioVoiceAdapter`'s own teardown can now both attempt to end the same
CallKit-reported call; the second one now safely no-ops rather than double-reporting.

**The topic feature**, by contrast, had no platform landmines — straightforward plumbing, all the
way through: `call_sessions.topic` (migration 0012, nullable, 140-char CHECK constraint),
`request-call`'s new `sanitizeTopic` (trims whitespace, truncates rather than rejecting an
otherwise-valid call over an overlong string, normalizes blank/missing/non-string input to null —
deliberately lenient, since a topic is a nice-to-have, not something worth failing a call request
over), a new field on `CallSession` (default `nil`, so no existing construction call site needed
touching), a new required parameter on `VoiceService.startCall`/`CallCoordinator.call` (threaded
through explicitly at both real call sites — Swift's default-parameter-value mechanism doesn't
apply through an `any VoiceService` existential, only through `CallCoordinator`'s own concrete
type, so `MockVoiceServiceTests`' seven existing call sites needed no changes at all), a plain
optional `TextField` on `DurationPickerView` ("What's this about? (optional)"), and finally
`CallKitAdapter.updateReportedCall`'s composed label and `IncomingCallView`'s in-app screen, both
showing it when present.

Build 25. All 47 backend tests (44 plus 3 new topic-sanitization tests) pass; `deno fmt`/`deno
lint` clean. Every touched file re-read in full for internal consistency, per this project's own
established practice with no local compiler. Not yet confirmed on a real device — this build
specifically needs to settle the one genuinely open question: does the lock-screen countdown
actually tick, or does it sit frozen at its first value (in which case the in-app countdown, once
the phone is unlocked, remains the reliable path) — plus the ordinary check that a typed topic
shows up correctly and a blank one doesn't show anything at all.

## Build 25 confirmed on a real device — the ticking countdown genuinely works

The owner tested build 25 on real, current hardware: the lock-screen countdown **actually
ticks**, the topic field works end to end, and the declined-vs-missed distinction (build 21) is
confirmed with real data too. This resolves the one open uncertainty flagged in `CallKitAdapter`'s
own comment — worth noting plainly, since that comment (and BUILD_STATUS.md) should no longer
read as "might not work," now that it's confirmed working on the owner's actual phones. Left the
code comments themselves as historical record of the real research that went into building it
cautiously, rather than rewriting them to sound more confident in hindsight.

Also asked about two more things, both researched (not guessed) before answering:

**A two-line lock-screen display** (name on one line, duration+topic on another) — no confirmed
API for this. `CXCallUpdate` gives a `.generic`-handle call exactly one text field
(`localizedCallerName`); the two-line "contact name / phone number" layout real Phone calls show
is tied specifically to a `.phoneNumber`-type handle, which doesn't apply here (no real phone
numbers in this system at all). Told the owner honestly rather than guess-implementing a
`remoteHandle`/`localizedCallerName` split with no evidence it would actually render as two
lines for this handle type.

**Siri support** — researched via App Intents (not old-style SiriKit custom intents, which don't
cover this shape of action well). Confirmed real and buildable: a custom `AppIntent` with
`@Parameter`s for recipient/duration/topic, an `AppEntityQuery` backing recipient resolution
against the app's own connections, and Siri's own natural-language parameter parsing. One
real, confirmed constraint: Apple requires `openAppWhenRun = true` for an intent that starts a
CallKit call — a real forum-reported error (`CXErrorCodeRequestTransactionError.invalidAction`)
fires if a VoIP call is started from a fully backgrounded App Intent, so the app must briefly
foreground itself as part of placing the call; there's no way to make it fully silent/background.

**Both deferred at the owner's own request** — noted here for continuity, not because either
needs more research: they want "Respond with Text" (see the build-24-era decision above for why
a literal CallKit hook doesn't exist for this, and the in-app-quick-reply alternative discussed
instead) and Siri built later, once everything already shipped is confirmed solid first.

## Real evidence surfaces a genuine gap: call sessions stuck forever with no way to resolve

Asked to keep troubleshooting before moving to new features, queried `call_sessions` directly
(not just trusting the app's own UI) and found something serious: dozens of rows sitting in
`created`/`outgoing`/`ringing` — some for **over a day** — with `ended_at` still null. Twilio's
own ring timeouts run well under a minute, so whatever really happened to these calls, Twilio's
side of it ended long ago; nothing ever told the *database* that. Root cause: `.missed`/`.failed`
resolution has only ever been driven by the *caller's own device* processing its own
`callDidDisconnect` (see the build-14/15/20 entries above) — exactly the layer that a killed app,
a dropped network, or (very plausibly, during this project's own rapid dev testing) simply
starting a new call attempt without ever letting the previous one resolve, can silently prevent
from ever running. This is precisely the failure mode the original build plan's third
duration-enforcement layer — "a `pg_cron`/`pg_net` sweep force-completes any session past its
expiry" — was designed to catch, and which `BUILD_STATUS.md` has correctly listed as "not yet
built" since Phase 6 began. Real data now proves it's a live gap, not a hypothetical one.

**Built the sweep for real.** `expire-call-sweep/logic.ts`: a pure `planSweep(candidates, now)`
function, branching only on whether `connectedAt` is set (not the exact current status) — a
never-connected session gets `NEVER_CONNECTED_GRACE_SECONDS` (5 minutes, generously past any
real ring duration) from `initiatedAt`, resolving to `missed` if it had at least reached
`ringing` (matches `TwilioVoiceAdapter.callDidDisconnect`'s own existing convention: reached the
recipient but never resolved reads as "never answered in time" regardless of *why*) or `failed`
otherwise; a connected session gets its own `requestedDurationSeconds` plus
`CONNECTED_GRACE_SECONDS` (2 minutes slack, covering clock skew / a delayed signal without
cutting off a real conversation) past `connectedAt`, resolving to `completed` with
`actualDurationSeconds` computed the same uncapped way `CallStateMachine.apply` computes it
client-side. `index.ts` wires this to a real `supabaseAdmin()` client (bypasses RLS
deliberately — this sweeps every user's stale sessions, not just one), guarding each update with
`.eq("status", update.fromStatus)` so a session that resolved normally between the fetch and the
update is safely skipped rather than double-reported — the same idempotent-by-construction
pattern `twilio-status-callback` already established. 8 new tests; the whole
`functionSkeletons_test.ts` stub entry retired the same way `request-call`/`call-action`/etc.
already did once they graduated.

**Scheduling required a real secret-handling decision.** The sweep needs to run periodically and
call the deployed Edge Function with real, privileged (service-role) credentials — but nothing
about *how* should ever be committed to git in a form that leaks that credential.
`0013_expire_call_sweep_cron.sql` enables `pg_cron`/`pg_net` and schedules a `net.http_post` call
every minute, authenticated with `Authorization: Bearer` read from
`vault.decrypted_secrets where name = 'expire_call_sweep_service_role_key'` — the migration file
itself never contains the actual key. The real secret was provisioned once, directly against the
live project via `vault.create_secret(...)`, run from a throwaway script (not committed) that
reads the key from the same local `.env` every other admin operation in this project already
uses, with the query itself passed through the Management API's raw-SQL endpoint (which, checked
directly, does not support bind parameters at all — confirmed by a real `42P02` error, not
assumed — so the value is interpolated into Postgres dollar-quoted SQL text instead, safe here
since a real JWT only ever contains base64url characters that can't break out of a string
regardless).

**Found and fixed a real CI gap in the same pass**: `sql-lint.yml` applies every migration file
against a plain `postgres:17` service container to verify RLS — but `pg_cron`/`pg_net` require
`shared_preload_libraries` set at server startup, a config-time flag that container was never
started with, so `create extension pg_cron` would fail there even though it works fine on the
real, preconfigured Supabase project. Fixed by having the workflow explicitly skip
`0013_expire_call_sweep_cron.sql` (every other migration still applies and still gets its RLS
assertions run normally) — documented in `KNOWN_LIMITATIONS.md` alongside the project's other
already-documented local-vs-real-project gaps, in the same spirit rather than a new pattern.

**Verified with real evidence at every layer, not just trusted that setup succeeded**: extensions
installed; the vault secret's *length* (not its value) confirmed to match the real key
character-for-character; the cron job confirmed registered and `active` in `cron.job`; two real
scheduled ticks confirmed `succeeded` in `cron.job_run_details`; the actual HTTP responses pulled
from `net._http_response` confirmed genuine `200`s, not just that pg_net queued the request. A
manual first invocation, run before scheduling, swept all 45 genuinely stale rows found earlier —
re-querying immediately after confirmed zero stuck sessions remained, and a follow-up query
confirmed each one resolved to the status `planSweep`'s own rules say it should have.

No iOS changes this round — backend and infrastructure only, so no new build number. Backend
suite: 55/55 passing (47 plus 8 new), `deno fmt`/`deno lint` clean.

## Real device timing explains "33 seconds felt long," and gets shortened on request

Testing a genuine missed call (letting it ring untouched), the owner timed it at 33 seconds and
called it out as feeling long. Checked, not guessed: `twiml-voice/logic.ts`'s `<Dial>` element
set `timeLimit` (the connected-call duration cap) but never set `timeout` (how long Twilio rings
before giving up and reporting no-answer) — Twilio's own documented default for an unset
`timeout` is 30 seconds, and the remaining ~3 seconds is real push-delivery/processing overhead.
The owner confirmed this explanation matched exactly ("30 seconds is exact") and asked for "low
20s" instead. Added an explicit `RING_TIMEOUT_SECONDS = 20` constant and set `timeout="20"` on
the `<Dial>` element. `twimlVoice_test.ts` updated to match. Deployed
(`npx supabase functions deploy twiml-voice`) and sanity-checked directly — a raw, content-type-
less POST returned a real `500` (an artifact of that specific test request being malformed, not a
regression: `req.formData()` throws when there's no parseable body at all, uncaught, matching
this function's pre-existing behavior, untouched by this change); a properly form-encoded POST
(matching how Twilio actually calls this) correctly returned `200` with the graceful
`<Reject/>` TwiML. All 55 backend tests still pass. No iOS changes.
