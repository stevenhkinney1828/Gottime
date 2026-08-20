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
**Status: you already had the account — the empty repository is the one thing still needed.**
This is where the code lives and where the "cloud Mac" builds run from. To create it:

1. Go to github.com and sign in.
2. Click the **+** in the top-right corner → **New repository**.
3. Name it anything (e.g. `gottime`). Leave it **empty** — don't check "Add a README" or
   "Add .gitignore," since there's already a project ready to fill it.
4. Click **Create repository**.
5. Tell Claude Code the repository's URL (it'll look like `https://github.com/yourname/gottime`).

Claude Code will also need a way to actually push code there. The simplest way: create a
**fine-grained personal access token** scoped to just that one repository —

1. On GitHub: click your profile picture → **Settings** → scroll down to **Developer
   settings** → **Personal access tokens** → **Fine-grained tokens** → **Generate new token**.
2. Give it a name, set **Repository access** to "Only select repositories" and pick the one
   you just made, and under **Permissions → Repository permissions**, set **Contents** to
   **Read and write**. Leave everything else as-is.
3. Generate it, copy the token (starts with `github_pat_...`), and paste it to Claude Code.

This token can only touch that one repository, only to read/write files — not your account,
not your other repos. You can revoke it anytime from that same Settings page. If you'd rather
not create a token at all, that's fine too — just let Claude Code know when a batch of work is
ready, and push it yourself with the two git commands it'll give you.

### 2. A Supabase project **(coming up next)**
Supabase is the free service that stores user accounts and app data (who's connected to
whom, call history) securely.

1. Go to supabase.com and sign up (or sign in).
2. Click **New project**. Pick any organization/name (e.g. "gottime"), set a database
   password (Supabase generates one for you if you'd rather not choose — either way, save it
   somewhere, but you won't need to type it day-to-day), and pick a region close to you.
3. Wait a minute or two for it to finish setting up.
4. Go to **Project Settings** (gear icon) → **API**. You'll see a **Project URL** and two
   keys: **anon / public** and **service_role**.
5. Share all three (URL, anon key, service_role key) with Claude Code.

The service_role key is powerful — it can read/write everything in the database, bypassing
the normal security rules. It never goes in the iPhone app itself, only into Supabase's own
secure server-side config. Treat it like a password: share it with Claude Code once, don't
post it anywhere public.

### 3. Apple Developer Program enrollment
**Status: done — you already have this.**
This is what allows apps to be installed on real iPhones and eventually distributed via
TestFlight.

For Sign in with Apple specifically, two more things happen inside your existing account
(not a new enrollment) once we reach that step:
1. **Certificates, Identifiers & Profiles → Identifiers** — the app's own identifier (its
   "bundle ID") needs the **Sign in with Apple** capability turned on. Claude Code will tell
   you the exact identifier to find once it's registered one.
2. **Certificates, Identifiers & Profiles → Keys** — a new key with **Sign in with Apple**
   enabled, which produces a one-time-downloadable `.p8` file. Apple only lets you download
   this once, so save it somewhere safe immediately (Claude Code will tell you exactly where
   to put it). You'll also note down the **Key ID** and your **Team ID** (visible on the same
   page/your account's Membership details) — both get shared with Claude Code alongside the
   key file.

These exact steps are common but occasionally Apple tweaks their portal's layout — if
anything looks different from this description when we get there, just describe what you see
and Claude Code will help you find the right button.

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
