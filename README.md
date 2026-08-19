# GotTime?

A native iPhone app for two (eventually a small circle of) connected people to place a
voice call with an agreed time limit, agreed *before* the recipient answers, that
automatically ends when the time is up.

"GotTime?" is a working name only — see [DESIGN_SYSTEM.md](DESIGN_SYSTEM.md) for how
product naming is kept swappable.

## What this is, in one paragraph

You pick a connected person, pick a duration (5–30 minutes, or a custom 1–60), and confirm.
They see who's calling and how long you're asking for *before* they answer — even if their
phone is locked. Once they answer, a countdown starts. When it hits zero, the call ends
automatically, for both people, no confirmation needed. That's the entire product. Everything
else in this repo exists to make that one moment work reliably.

## Where things stand right now

See [BUILD_STATUS.md](BUILD_STATUS.md) for the current phase and what's done vs. pending.

## If you're the owner and not an iOS developer

Start with [SETUP.md](SETUP.md) — it explains, in plain language, what you need to do at
each stage (accounts, one-time approvals, testing with a real iPhone), what you never need
to touch, and how to check on progress or logs.

## Repository layout

```
ios/        Native SwiftUI app (Swift, no other platform)
backend/    Notes + one-time setup scripts; the actual backend lives in supabase/functions/
supabase/   Database migrations, Row Level Security policies, Edge Functions (backend logic)
docs/       Supporting documentation
.github/    Automated build/test pipelines (see ARCHITECTURE.md — this project is built on a
            Windows machine with no Mac, so these pipelines are how the iOS app actually gets
            compiled and tested)
```

## Key documents

- [ARCHITECTURE.md](ARCHITECTURE.md) — how the pieces fit together and why
- [DECISIONS.md](DECISIONS.md) — every non-obvious implementation choice, and why it was made
- [DESIGN_SYSTEM.md](DESIGN_SYSTEM.md) — visual language, tone, and how to change copy/branding safely
- [KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md) — honest gaps and approximations
- [BUILD_STATUS.md](BUILD_STATUS.md) — phase-by-phase progress tracker
- [BETA_FEEDBACK.md](BETA_FEEDBACK.md) — friends & family beta feedback log (Phase 9+)

## Explicitly out of scope for this version

Android, group calls, video, public profiles/search, a social feed, normal phone-number
calling, contact-book import, calendar integration, AI summaries, call recording,
messaging, voicemail, scheduled calls, payments, Apple Watch, CarPlay, and gamification.
None of these should show up here without a deliberate, separate decision to expand scope.
