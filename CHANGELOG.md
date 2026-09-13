# Changelog

## 1.2 — Dark mode glass fix, haptics pass, appearance setting

**Dark mode "liquid glass" fix (`Presentation/Circuits/CircuitsListView.swift`,
`Presentation/Shared/DesignSystem.swift`)**
- `CircuitRow`'s glass card stacked `.ultraThinMaterial` under a fixed
  `Color(.systemBackground).opacity(0.4)` layer and a flat
  `.white.opacity(0.5)` border. In dark mode `.systemBackground` is
  near-black, so it muddied the material, and the flat white stroke read as
  a harsh bright ring floating on a dark card instead of glass. Replaced
  with a single `.glassCard()` modifier: one material layer, a top-to-bottom
  gradient border (bright highlight up top, fading down — like light
  actually catching an edge) that's tuned separately per color scheme, and a
  deeper shadow in dark mode where a light one barely registers.

**Haptics — more variety, wider coverage (`Presentation/Shared/Theme.swift`
and throughout)**
- Added `Haptics.rigid()` (a mechanical click for discrete steps — the
  corporate-plan seat stepper) and `Haptics.soft()` (a muted thud for
  ambient/background events — an incoming chat message) alongside the
  existing tap/selection/confirm/success/warning/error set.
- Wired haptics into places that had none: tab switching, the care-type and
  appearance pickers, the pet species picker, sign-out and delete-pet
  (warning, since both are destructive), subscribe/add-pet buttons
  (confirm), pull-to-refresh (tap), cancel-visit swipe action (warning), the
  symptom-triage result (warning/tap/success by urgency), and referral send
  success/failure.

**New: Appearance setting (`App/VetCircuitApp.swift`,
`Presentation/Profile/ProfileView.swift`)**
- A System/Light/Dark picker in Profile, backed by `.preferredColorScheme`.
  Lets someone stuck with a bad system dark theme just use light mode
  instead of fighting it, and gives a place to verify dark-mode fixes
  without leaving the app to flip the system setting.

## 1.1 — Design & motion overhaul

This release doesn't add new user-facing features; it corrects the motion
system and fixes real UX defects, using the `animate`, `apple-design`,
`emil-design-eng`, `improve-animations`, and `find-animation-opportunities`
skills (see `.claude/skills/`) as the standard to audit against rather than
guessing at "nicer."

**Motion language (`Presentation/Shared/Theme.swift`)**
- Button press feedback (`springQuick`) was under-damped, giving every tap a
  visible bounce. Apple's fluid-interfaces guidance calls for critically
  damped motion (no bounce) on anything fired many times a day — bounce is
  reserved for momentum-driven gestures. Fixed.
- Entrance animation (`springSoft`) had a 0.55s response, past the
  recommended 300–500ms band for occasional UI. Tightened to 0.4s.
- `Theme.easeIn` was actually an `easeOut` curve — a misleading name for a
  hard rule ("never ease-in on UI") the value itself already respected.
  Renamed to `crossFade`.
- List entrance stagger was uncapped (`index * 0.05`), so a 20-item list's
  last row waited an extra second to appear. Capped at 6 items' worth of
  delay via `Theme.staggerDelay(_:)`.
- Added `springMomentum` for future gesture-driven interactions, distinct
  from the critically-damped default.

**Fixed teleporting state** (found via `find-animation-opportunities`)
- Profile's Subscription section now crossfades between "subscribe" buttons
  and the active-plan view instead of snapping.
- Profile's Rewards card now enters with a bridge instead of popping in.
- The circuits list now crossfades between its loading/empty/error/loaded
  states, and when the care-type filter changes the list.

**Typography** — applied Apple's size-specific tracking guidance
(`brandDisplayText()`, tightened tracking on large display text) to the
sign-in hero title, profile name, booking-confirmed headline, and the
symptom-triage headline.

**Accessibility** — carried through unchanged from 1.0: Reduce Motion
support on the mascot's idle animation and all appear-in transitions.
