# Design System

## Qualities this app must feel like

Quiet, warm, premium, intentional, human, trustworthy, simple. It should read as a real,
polished consumer iPhone utility — never as a SaaS dashboard, a gamified app, or an
AI-generated coding demo. When in doubt, remove something rather than add it.

Explicitly avoided: loud gradients, gamification, excessive card chrome, dashboard-style
metrics, generic "AI product" visual clichés, and any settings screen item that isn't in the
spec's Settings list (profile basics, connections/invites, notification status, sign out,
delete account, app version, a short "how it works" explainer — nothing else).

## Product naming stays swappable

"GotTime?" lives in exactly one place: `ios/App/Resources/Localizable.strings` (key
`app_display_name`) plus the `PRODUCT_NAME`/`DISPLAY_NAME` build setting in
`ios/Config/*.xcconfig`. No Swift type, table name, Edge Function, or API model may reference
the product name — those all use neutral terms (`Profile`, `Connection`, `CallSession`,
`TimedCall`). Renaming the product later should touch only strings/config, never logic.

## Color

Semantic tokens, not hard-coded colors, defined once in `DesignSystem/Color+GotTime.swift`
and used everywhere else. Every token has a Light and Dark value; both meet WCAG AA contrast
against their paired background.

| Token | Purpose | Light | Dark |
|---|---|---|---|
| `background` | Screen background | near-white, warm-tinted | near-black, warm-tinted |
| `surface` | Cards/grouped rows | white | elevated dark gray |
| `textPrimary` | Primary content | near-black | near-white |
| `textSecondary` | Supporting text | warm gray | warm light gray |
| `accent` | Primary actions, selection | muted warm terracotta | muted warm terracotta (lightened) |
| `timerCalm` | Countdown, >60s remaining | `textPrimary` | `textPrimary` |
| `timerWarning` | Countdown, final 60s | warm amber | warm amber (lightened) |
| `timerFinal` | Countdown, final 10s | warm amber, heavier weight | warm amber (lightened), heavier weight |
| `destructive` | Decline / end call / delete account | muted red | muted red (lightened) |

**The timer never relies on color alone** (spec §9 is explicit on this): the 60-second and
final-10-second states pair their color shift with a weight/size change in the countdown
digits and a haptic — someone who can't distinguish the color still gets the signal.

No pure black, no pure white, no saturated/loud hues anywhere. Restraint over vibrancy.

## Typography

System font (SF Pro) throughout, via Dynamic Type text styles — never fixed point sizes for
body content, so accessibility text-size settings work everywhere.

| Element | Style |
|---|---|
| Countdown (Active Call hero) | Large, rounded-width numeral style, monospaced digits (so it doesn't visually jitter as digits change), scales with Dynamic Type up to a capped maximum to preserve layout |
| Screen titles | `.largeTitle` / `.title2`, semibold |
| Person names, primary labels | `.body`, semibold |
| Secondary/meta text (timestamps, status) | `.footnote`, regular, `textSecondary` |
| Button labels | `.headline` |

## Spacing & layout

8pt base grid (8/16/24/32/40). Generous whitespace over dense layouts. Minimum tap target
44×44pt on every interactive element, including duration chips and history rows. Safe-area
respecting layouts; no content crammed edge-to-edge.

## Motion & haptics

Restrained. Standard easing, short durations (150-250ms) for state transitions (e.g.,
duration selection, call connecting → active). No bouncy/playful physics, no confetti, no
celebratory animation on call completion — completion is calm, not a reward moment.

Haptics: light impact on duration selection; a single gentle notification haptic at the
60-second warning; a slightly firmer one at zero. Never a haptic barrage.

## Core reusable components

Centralized in `ios/App/DesignSystem/`, used by every feature screen rather than one-off
styling per view:

- `PersonRow` — connected-person list item (name, optional last-call meta, fast-tap target)
- `DurationChip` — the 5/10/15/20/30-minute + custom selectable pill
- `PrimaryButton` / `DestructiveButton` — the two button styles in the whole app
- `CountdownView` — the large timer digits + calm/warning/final states, color- and
  shape-redundant
- `CallStatusBadge` — history row status (completed/ended early/declined/missed/canceled/
  failed), icon + text, never color-only
- `SectionHeader`, `EmptyState` — shared layout primitives

## Tone & copy

Never imply the other person is a burden. Banned phrasing: "escape the call," "don't get
trapped," "time waster," "protect yourself," or anything with that undertone.

Preferred phrasing, matching the spec directly:
- "How long do you have?"
- "Call Chris for 10 minutes"
- "1 minute left"
- "Time's up"
- "Want to keep talking? Start another call."

The product is about making it easier to say yes to a call, not about escaping people —
every copy decision gets checked against that framing.

## Accessibility commitments

- Dynamic Type supported on all text.
- VoiceOver labels on every primary control (duration chips announce the duration, the call
  button announces person + duration, mute/speaker/end-call are unambiguous, countdown
  announces remaining time at sensible intervals rather than every second).
- Light Mode and Dark Mode both fully supported, not an afterthought.
- Color is never the only signal for timer state (see Color section above).
