# Setup Guide (for the owner, not an iOS developer)

This explains what you'll need to do, when, and why — in plain language. You do not need
Xcode, a Mac, or any iOS development experience. Sections for stages we haven't reached yet
are marked **(not yet needed)** and will be filled in with exact click-by-click steps when
that stage actually arrives — no need to read ahead or prepare early.

## How this project gets built without a Mac

Normally, iPhone apps are built on a Mac using a program called Xcode. This project is being
built on a Windows PC, so instead: every time code is pushed to GitHub, a temporary Mac in
the cloud (provided free by GitHub) automatically compiles it and runs its tests. Once app
signing is set up (see the Apple Developer stage below), that same cloud Mac also uploads
finished builds straight to **TestFlight** — Apple's official way of installing test versions
of an app. You install and test the app through the TestFlight app on your iPhone, the same
way you'd install anything from the App Store. You never need to open Xcode yourself.

## What you'll be asked for, in order

Each item below only gets asked for once the project actually reaches that stage — not
before. If you see a request that isn't on this list, or is out of order, ask about it.

### 1. A GitHub account and one empty repository
**Status: done — you already had a GitHub account.**
This is where the code lives and where the "cloud Mac" builds run from.

### 2. A Supabase project **(not yet needed)**
Supabase is the free service that stores user accounts and app data (who's connected to
whom, call history) securely. You'll create a free project and share three values with
Claude Code (a URL and two keys). Takes about 10 minutes.

### 3. Apple Developer Program enrollment
**Status: done — you already have this.**
This is what allows apps to be installed on real iPhones and eventually distributed via
TestFlight. When we reach the authentication stage, you'll do a few clicks inside your
existing account to set up "Sign in with Apple" — not a new enrollment.

### 4. A Twilio account **(not yet needed)**
Twilio is the service that actually carries the voice call audio between the two phones.
You'll create an account and add a small starting balance (about $20). Real cost per call is
a small fraction of a cent per minute, so for a handful of friends/family this should run to
a few dollars a month at most.

### 5. Two physical iPhones **(not yet needed)**
For the real end-to-end call test — one phone is you, one is whoever you're testing with
(e.g., your brother). Simulators can't test real phone calls, microphones, or lock-screen
behavior, so this step is unavoidable and happens more than once as features are added.

### 6. An App Store Connect API key + Internal Testing group **(not yet needed)**
This is what lets the cloud Mac sign and upload builds automatically, and lets your two
test iPhones install them via TestFlight before anyone else is invited.

### 7. An APNs "VoIP" push key **(not yet needed)**
A one-time download from Apple's developer site that lets your phone show the native
incoming-call screen the instant someone calls you, even if the app isn't open.

### 8. External TestFlight testers + a one-time Apple review **(not yet needed)**
When it's time to invite 5–15 friends/family, you'll type in their emails inside App Store
Connect and submit for a quick, automatic Apple review (usually same-day) before they can
install it.

## How to check on progress

- [BUILD_STATUS.md](BUILD_STATUS.md) — what phase we're in and what's done.
- [DECISIONS.md](DECISIONS.md) — a running log of implementation choices made along the way and why, so nothing important happens silently.
- Ask Claude Code directly at any time — "what's the current status?" or "what's next?" both work.

## Safe ways to change copy or design later

Don't edit Swift files directly unless you're comfortable with that. Instead, just describe
the change in plain language (e.g., "make the countdown number bigger" or "I don't like the
phrase 'Time's up', can we say something else?") and ask Claude Code to make it — copy and
visual styling are deliberately centralized (see [DESIGN_SYSTEM.md](DESIGN_SYSTEM.md)) so
these changes stay small and low-risk.

## Logs

Structured logs exist for authentication, push notifications, incoming call handling, the
voice connection, the timer, and backend requests — with secrets/tokens deliberately never
logged. Once the app is running on a device, ask Claude Code to walk you through pulling logs
for a specific problem rather than digging through Xcode/Console.app yourself.
