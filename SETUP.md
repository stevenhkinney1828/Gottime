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

### 4. A Twilio account
**Status: done.** Account created, billing turned on with a starting balance, and all the
credentials Claude Code needed are stored. This is the service that carries the actual voice
call audio between the two phones.

### 5. Two physical iPhones **(this is the current blocker, along with #6 below)**
For the real end-to-end call test — one phone is you, one is whoever you're testing with
(e.g., your brother). Simulators can't test real phone calls, microphones, or lock-screen
behavior, so this step is unavoidable and happens more than once as features are added. Nothing
to click here — just have both phones on hand and charged when you're ready to test.

### 6. An App Store Connect API key + Internal Testing group **(this is the current blocker)**
This is what lets the cloud Mac sign builds and upload them to TestFlight automatically — the
last thing needed before a real build can land on your two iPhones. Three parts, done in order:

**Part A — the API key** (do this on a computer, in a browser, at appstoreconnect.apple.com):

1. Go to **appstoreconnect.apple.com** and sign in with your Apple Developer account.
2. Click **Users and Access** (in the sidebar or top navigation).
3. Click the **Integrations** tab.
   - If you see a **Request Access** button instead of key options, click it, check the
     agreement box, and click **Submit** — this is a one-time approval Apple grants
     automatically, usually within a few minutes. Come back to this page once it's through.
4. Click the **Team Keys** tab (not "Individual Keys" — Team Keys work no matter who's signed
   in, which is what an automated cloud process needs).
5. Click **Generate API Key** (or the **+** button).
6. Under **Name**, type anything you'll recognize later, e.g. `GotTime CI`. This is just a
   label — it's not part of the key itself.
7. Under **Access**, choose **Admin**. (An earlier version of this guide said "App Manager" —
   that turned out to be wrong: uploading a signed build this way needs a capability called
   "cloud signing," which specifically requires Admin-level access. Non-Admin keys fail with a
   "Cloud signing permission error" — found out directly from a real failed attempt, not
   anticipated ahead of time. Admin covers everything App Manager would have anyway.)
8. Click **Generate**.
9. You'll now see three things on the page:
   - **Key ID** — a short code.
   - **Issuer ID** — shown near the top of the Integrations page, above the key list.
   - **Download API Key** — click this to download a file ending in `.p8`. **Apple only lets
     you download this once — if you lose it, you can't re-download it, only revoke it and
     make a new one.** Save the download somewhere you won't lose it.
10. One more thing, from a different page: go to your name/account in the top right →
    **Membership**. Copy the **Team ID** (a 10-character code).

You now have four things: **Key ID**, **Issuer ID**, the downloaded **.p8 file**, and your
**Team ID**. These go straight into GitHub yourself, not through Claude Code — this is Apple's
private signing key, and the fewer places it passes through, the better. Here's where each one
goes (github.com → your repository → **Settings** tab → **Secrets and variables** → **Actions**
→ **New repository secret**, repeated four times):

| Secret name (type exactly this) | Value |
|---|---|
| `APP_STORE_CONNECT_API_KEY_ID` | the Key ID |
| `APP_STORE_CONNECT_ISSUER_ID` | the Issuer ID |
| `APP_STORE_CONNECT_API_KEY_P8` | open the `.p8` file in a text editor (like Notepad) and paste its entire contents, including the `-----BEGIN PRIVATE KEY-----`/`-----END PRIVATE KEY-----` lines |
| `APPLE_TEAM_ID` | the Team ID |

Once all four are saved, tell Claude Code. The GitHub access it has doesn't extend to reading
repository secrets at all (not even just their names), so it can't directly confirm they're
saved correctly — but the next push will show it clearly either way: the "Sign & upload to
TestFlight" job's first step checks for exactly these names and will visibly report whether
it found them, right there in the same Actions log Claude Code already checks after every push.

**Part B — register the app itself in App Store Connect** (a real, necessary step —
unlike everything above, this one Apple genuinely requires done manually, first, before the
cloud Mac's very first upload attempt can succeed at all):

1. In App Store Connect, go to **Apps** → click the **+** → **New App**.
2. **Platform:** iOS.
3. **Name:** `GotTime?` — but this exact name is very likely already taken. Apple requires this
   field to be unique across every app in the *entire* App Store, not just your own account, so
   this has nothing to do with anything being wrong on your end. If it's rejected, just add a
   word — `GotTime? Calling` works well. **This is a different field from the name that
   actually shows on your phone's home screen** (that's already set in the app's code and is
   completely unaffected by whatever you type here) — and it can be changed again later in App
   Store Connect any time before the app is ever submitted for real App Store review (Phase 9),
   so there's no need to deliberate over it now.
4. **Primary Language:** English (or your preference).
5. **Bundle ID:** choose `com.stevenkinney.gottime` from the dropdown — it's already there from
   the Sign in with Apple setup back in an earlier step, nothing new to register.
6. **SKU:** any internal label only you ever see, e.g. `gottime001`.
7. **User Access:** choose **Full Access**, not "Limited Access." Limited Access exists for
   teams who want to hide an app from some of their own members — it has no benefit for a
   one-person account, and choosing it risks the CI signing key needing a separate, extra
   access grant just to see the app at all. (Some solo accounts don't even get a real choice
   here — this may already show as locked to Full Access, which is fine.)
8. Click **Create**.

Do this, and save the four secrets in Part A, before telling Claude Code you're ready — the
signing/upload code is already written and pushed, so Claude Code can trigger a fresh run
directly rather than needing any new code change first. The very first real attempt will fail
with a confusing error if this app record doesn't exist yet, so this step needs to come first.

**Part C — the Internal Testing group** (do this once a real signed build has actually landed
in App Store Connect — Claude Code will let you know once a push succeeds):

1. In App Store Connect, go to **Apps** and click into GotTime (the app record from Part B).
2. Click the **TestFlight** tab.
3. Under **Internal Testing**, click the **+** next to it (or "Create Group" if that's what
   you see).
4. Name the group anything, e.g. `Family Testers`.
5. Check the box for yourself (and anyone else on your Apple Developer account team you want
   testing early) as a tester in that group.
6. Look for a toggle or setting like **"Automatically distribute builds"** and make sure it's
   turned on — that way every new build Claude Code's pipeline uploads shows up on your phone
   automatically, without you having to come back here and approve each one by hand.
7. Install the **TestFlight** app from the real App Store on your iPhone (if you don't have it
   already) — that's where the actual GotTime builds will show up once uploaded.

Apple's own screens occasionally shift button placement between updates — if anything here
looks different from what you see, just describe it or send a screenshot and Claude Code will
help you find the right button.

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
