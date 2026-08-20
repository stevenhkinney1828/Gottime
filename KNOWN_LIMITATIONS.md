# Known Limitations

Honest gaps and approximations, kept current as the build progresses. Not a bug tracker —
see BETA_FEEDBACK.md (Phase 9+) for that.

## Local development environment

- **No local Swift compilation.** The development machine is Windows with no Xcode/macOS/
  Swift toolchain. All iOS code is verified via GitHub Actions' `macos-latest` runner, never
  locally. This means a compile error in iOS code is only discovered after a push, not
  before — mitigated by keeping `GotTimeCore` (the highest-risk logic) small, dependency-free,
  and exhaustively tested so CI runs stay fast (target: 1-3 minutes).
- **Local Postgres is an approximation of Supabase, not a replacement.** `supabase/seed/auth_shim.sql`
  stubs `auth.uid()`/`auth.jwt()`/`auth.role()` well enough to dry-run migrations and probe RLS
  policies as different simulated users, but it does not replicate Supabase's real GoTrue
  claim structure or connection-pooling role setup exactly. As of Phase 0, every migration and
  every RLS policy has been exercised against a real local Postgres 17 instance using this
  shim (unconnected-user denial, connected-participant access, invite redemption, duplicate-
  connection prevention, and duration bounds all verified working) — a good sign, but every
  policy still gets a final verification pass against the real Supabase project once one
  exists (Phase 2+), since the shim is still an approximation of GoTrue, not GoTrue itself.
- **No Simulator access.** Without Xcode, there is no way to visually run the app locally —
  not even in a simulator. Visual verification happens via CI screenshot/XCUITest output and,
  from Phase 4 onward, real devices via TestFlight.

## Tracked, non-blocking compiler warnings

- **GotTimeMocks' `NSLock`-based services warn under Swift 6 language mode.** All five mock
  services (MockAuthService, MockConnectionService, MockCallHistoryService, MockVoiceService)
  call `NSLock.lock()`/`.unlock()` from inside `async` functions to guard their in-memory
  state. This compiles and runs correctly today (the project deliberately targets Swift 5
  language mode — see DECISIONS.md — specifically to avoid Swift 6's stricter concurrency
  checking), but the compiler already warns that this becomes a hard error under Swift 6 mode:
  "instance method 'lock' is unavailable from asynchronous contexts." Not an active bug — lock
  hold times in these mocks are all short and never span an `await`, so there's no realistic
  thread-pool-starvation risk in practice — but a real Swift 6 migration would need these
  reworked (most naturally, converting the mocks to `actor`s instead of classes with manual
  `NSLock`). Deferred rather than fixed now, since it doesn't block anything and isn't on the
  current roadmap.

## Platform behavior pending real-device confirmation

- **CallKit incoming-call presentation** (composing `"Name • N min"` into
  `localizedCallerName`) is a reasonable, spec-consistent choice, but CallKit's exact
  pre-unlock rendering (truncation, font size, whether a second line is ever shown) can only
  be confirmed on a real locked iPhone — planned for Phase 5.
- **Twilio server-side `timeLimit` semantics on a live, already-connected call** — whether
  updating it via the REST API mid-call measures from call start or from the update moment —
  is assumed conservatively for now and will be empirically confirmed during Phase 4, with
  [DECISIONS.md](DECISIONS.md) updated to match observed reality.

_This file is updated whenever a limitation is discovered or resolved — not just at the end
of a phase._
