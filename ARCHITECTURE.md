# Architecture

## System overview

```
┌─────────────────────┐         ┌──────────────────────────────┐        ┌─────────────────┐
│   iOS app (Swift)    │         │   Supabase project            │        │   Twilio          │
│                      │  HTTPS  │                                │        │                  │
│  SwiftUI views       │────────▶│  Postgres + Row Level Security│        │  Voice (app-to-  │
│  GotTimeCore (logic) │         │  Auth (Sign in with Apple)    │        │  app calling)    │
│  CallKit / PushKit   │         │  Edge Functions (backend)     │───────▶│  TwiML App       │
│  Twilio Voice SDK    │◀────────│                                │◀───────│  Status callbacks│
└──────────┬───────────┘  VoIP   └───────────────┬────────────────┘        └─────────────────┘
           │              call audio (P2P via     │
           │              Twilio infra, never      │ APNs HTTP/2 (VoIP push)
           │              touches our backend)     ▼
           │                              ┌──────────────────┐
           └─────────────────────────────▶│  APNs             │
                                           │  (incoming-call    │
                                           │   wake-up)         │
                                           └──────────────────┘
```

Nothing in this system records, stores, or analyzes call audio. Audio flows directly between
the two iPhones and Twilio's infrastructure; our backend only ever sees metadata (who, when,
how long, what state).

## Why there's no Mac anywhere in this system

The development machine is Windows, with no Xcode and no macOS available, ever. Rather than
work around that with a lesser process, the project treats a **GitHub Actions `macos-latest`
runner as the one and only Mac it needs**:

- Every push triggers `ios-ci.yml`, which installs XcodeGen, generates the Xcode project from
  the checked-in `ios/project.yml`, and runs `xcodebuild build`/`test` against an iOS
  Simulator destination. No signing, no Apple account, works from day one.
- Once Apple Developer credentials exist (Phase 4+), a second CI job signs the build with an
  App Store Connect API key and uploads it straight to TestFlight. The owner installs it on
  their iPhone through the TestFlight app — never through Xcode, never through a cable to a
  Mac.

This means "build success" for the iOS app is only ever verified in CI, never locally — see
[KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md) for what that trade-off costs and how it's
mitigated.

## The iOS app: three tiers, deliberately separated

```
Packages/GotTimeCore/     Pure Swift. Zero imports of SwiftUI, UIKit, CallKit, PushKit,
                            AVFoundation, or anything Apple-UI-specific.
                            - CallStateMachine: the 10-state lifecycle + valid transitions
                            - DurationPolicy: 1-60 minute validation, the 5 preset options
                            - CallTimer: connected-timestamp-anchored countdown math
                            - Models/: CallSession, Connection, Profile, CallStatus
                            - ServiceProtocols/: AuthService, ConnectionService, VoiceService,
                              CallHistoryService, PushService — interfaces only

Packages/GotTimeMocks/    Depends only on GotTimeCore. Implements every service protocol with
                            simulated behavior (fake ringing, fake answer, accelerated dev
                            timer) so the entire UX is testable with zero live credentials.

App/                      SwiftUI views (thin — logic lives in Core) + Integrations/, which
                            implement the same service protocols for real: CallKitAdapter,
                            PushKitAdapter, TwilioVoiceAdapter, AudioSessionManager,
                            SupabaseAuthAdapter.
```

The point of this split: `GotTimeCore` — the code where a bug means the timer lies, a
duration validates wrong, or the state machine allows an impossible transition — is small,
has no Apple-framework dependency, and gets exhaustive `XCTest` coverage that runs in a
minute or two on every single CI push. The code that *can't* be verified without a real
device (CallKit's actual on-screen behavior, PushKit registration, real audio routing) is
isolated in `Integrations/`, so it's obvious, when something breaks, whether it's a logic bug
(Core — should have been caught by a test) or a platform-integration bug (Integrations —
expected to need real-device iteration).

## Backend: Supabase Edge Functions, not a separate server

Every backend responsibility — issue a short-lived Twilio token, authorize a call (validate
caller/recipient/connection/duration server-side, never trusting the client), track a call's
state through its lifecycle, receive Twilio status callbacks, register a push token — is a
small, stateless request/response operation. That shape maps directly onto Supabase Edge
Functions (`supabase/functions/`, Deno/TypeScript), which avoids standing up and paying for a
separate hosting provider, and gets Supabase-JWT auth verification and secret storage for
free. See [DECISIONS.md](DECISIONS.md) #5 for the full reasoning.

```
supabase/functions/
  issue-voice-token/       Mints a short-lived Twilio Voice access token for the caller.
  request-call/            Validates caller/recipient/connection/duration, creates the
                            call_sessions row, generates the call UUID.
  twiml-voice/             Twilio webhook: returns <Dial><Client> TwiML routing the call to
                            the recipient's Twilio Voice identity, with a duration limit.
  twilio-status-callback/  Records ringing_at/connected_at/ended_at as Twilio reports them;
                            this is what makes "timer starts on connection" authoritative.
  call-action/             Decline / cancel / end-early, ownership-checked.
  register-device/         Upserts device_registrations for VoIP push delivery.
  expire-call-sweep/       Cron-invoked backstop: force-completes any call_sessions row past
                            its expiry that Twilio hasn't already closed out.
```

## The call lifecycle, end to end

1. Caller picks a person + duration in the app, taps an explicit confirm ("Call Chris for 10
   minutes"). The duration picker alone never starts a call.
2. App calls `request-call`. Backend validates the connection is real and active, the
   duration is 1-60 whole minutes, and the caller isn't already on a call — then creates a
   `call_sessions` row (`status: created` → `outgoing`) with a stable `call_uuid`.
3. Backend sends a VoIP push (via APNs, using the recipient's registered device token) to the
   recipient's phone. Their app reports the call to CallKit immediately, composing the
   caller's name and requested duration into the system incoming-call UI — visible before
   unlocking.
4. Recipient answers (native CallKit action) or declines. Either way, `call-action` and/or the
   Twilio status callback updates `call_sessions.status`.
5. On answer, Twilio connects the audio and fires a status callback marking the call
   in-progress. **This is the only moment `connected_at` gets set** — ringing time is never
   counted. The app's countdown starts from its own observed connection event, anchored to
   `connected_at`, not from a naive per-second UI timer (see `CallTimer` — this is what
   survives backgrounding/locking without drifting).
6. At the agreed duration, three independent layers converge on ending the call (see
   [DECISIONS.md](DECISIONS.md) #3): the client disconnects locally at its own computed zero;
   the backend has already tightened Twilio's server-side `timeLimit`; and a cron sweep force-
   completes anything that slips through both. `status` becomes `timed_out` → `completed`.
7. If either side hangs up before zero, `status` becomes `ended_early` instead, with the
   actual connected duration recorded separately from the requested duration.

## Data model

See `supabase/migrations/` for the authoritative schema. Five tables: `profiles`,
`connection_invites`, `connections`, `call_sessions`, `device_registrations` — matching the
spec's suggested model. Every table has Row Level Security enabled from its first migration;
there is no window where data exists without RLS applied.

## Product naming stays swappable

"GotTime?" appears only in `ios/App/Resources/Localizable.strings` and app-display-name
config. It is never used in table names, Swift type names, or Edge Function names — those use
neutral terms (`profiles`, `connections`, `call_sessions`, `CallSession`, `TimedCall`-style
naming) precisely so the product can be renamed later without touching architecture.
