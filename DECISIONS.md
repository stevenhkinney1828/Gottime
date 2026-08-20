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
