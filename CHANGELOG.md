# Changelog

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
