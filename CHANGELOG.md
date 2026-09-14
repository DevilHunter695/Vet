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

**Fluid motion — remaining teleporting state (found via
`find-animation-opportunities`)**
- `BookingView`'s pet and time-slot rows appeared with no entrance at all,
  unlike every other list in the app (`CircuitsListView`, `VisitHistoryView`)
  which already stagger in. Added the same `appearAnimation` + stagger.
- Adding/removing a pet in Profile, cancelling a visit (which moves it out
  of "Happening now" and swaps its badge), and a new referral landing in
  the invites list all mutated their arrays with no `withAnimation` —
  rows snapped in/out/around instead of settling. Wrapped each mutation.
- Left `VisitHistoryView`'s row scroll effect alone on purpose: unlike the
  browsing-style vet cards in `CircuitsListView`, this list is dense
  information (dates, statuses) the user is reading, not browsing — a
  blur/scale scroll transition there would hinder legibility for the sake
  of motion, so it's a rejected candidate, not a missed one.

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

## UI/UX overhaul — aurora visual system, tap reliability, build fix

### Build
- **The branch did not compile.** `PetDetailView` and `EditProfileView` each
  read a main-actor view model from inside a `PhotosPicker` label closure,
  which is `Sendable`-checked under Swift 6 strict concurrency. The label text
  is now computed before the closure.

### Tap reliability
Three separate causes of "I had to tap three or four times":
- A `simultaneousGesture(TapGesture())` on the circuit-list `NavigationLink`s
  competed with the link's own recogniser; whichever lost swallowed the tap.
  Recently-viewed is now recorded when the destination appears.
- `appearAnimation` scaled every entering view from 0.92. Inside a
  `LazyVStack` that window reopened every time a row re-entered the viewport,
  so hit-test geometry was in motion whenever the user reached for it. It is
  opacity-only now — an entrance flourish is not worth a dropped tap.
- `scrollTransition` scaled and blurred rows for the same reason, and
  `SelectableCardStyle` grew the selected card, shifting every row below it.
  Both are now opacity/shadow only.

Supporting changes: haptic generators are retained and pre-warmed rather than
constructed per tap; decorative layers (glows, badges, shimmer, pulsing dots)
are explicitly `allowsHitTesting(false)`; every control in the shared library
is at least 44pt with a `contentShape` covering its whole visual bounds, and
padding/frames live on button *labels* rather than outside the `Button`.

### Visual system
The palette is an "aurora": ocean blue into emerald green, falling away to
near-black, with two slow-drifting radial lights over it. `AuroraBackground`
is tuned separately for light (a faint wash) and dark (the full gradient), and
`auroraScreenBackground()` replaces the flat `Color(.systemGroupedBackground)`
on all 35 screens that had one.

New shared components: `SecondaryButton`, `PillButton`, `SectionHeader`,
`StatTile`, `InfoRow`, `TagChip`, `CalloutNote`, `featuredGlassCard`, plus a
typography scale with eyebrow and monospaced-digit helpers.

### Screens
- **Profile** — was a flat `List` of twenty identical `NavigationLink`s. Now an
  identity hero, four summary figures (wallet, points, pets, visits
  completed), a next-visit card, rewards progress showing the points actually
  needed for the next tier, membership state, pets as cards, grouped settings.
- **Visits** — `I1`'s "happening now" filter matched only
  requested/confirmed/enRoute, so a vet who had *arrived* or started the visit
  dropped out of the card into plain history. `isUpcoming`/`isLive` now live on
  `VisitStatus`. The active visit is a card with the pet, the vet, a countdown,
  `I2`'s eight-state progress as a bar, and open/message/cancel actions.
  Grouped into Happening now / Upcoming / History.
- **Book** — `C2` promised slot + price + rating; rows only showed rating. They
  now show the soonest slot with capacity, the area's starting price (from the
  catalog that was already being fetched and discarded), years of experience,
  the verified seal by the name, and a scarcity tag only when a slot is
  genuinely nearly full.
- **Booking** — `E3` promised a transparent breakdown, but the first number the
  customer saw was inside the checkout sheet, after committing. The signed
  quote is now previewed as soon as pet and slot are chosen. `F1`'s slot picker
  is grouped by day with wrapping time chips instead of a twenty-row wall. The
  confirm action is pinned with the running total.
- **Cart** — the total only appeared after pressing "Get price", and every
  change blanked it again. It prices on load and re-prices on every change,
  with total and commit action pinned. Checkout is still gated on a real
  server-signed quote.
- **Sign-in** and **Plans** moved onto the new system.
