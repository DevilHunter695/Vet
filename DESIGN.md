# The visual and interaction system

Written down because a design system that only exists in the person who built
it gets diluted by the third contributor. Every rule here has a reason next to
it; if the reason stops applying, change the rule.

## Materials

The app has one material — `LiquidGlass` — at three weights, and nothing else
draws its own card background.

| Level | Where | Face | Why |
|---|---|---|---|
| `.chrome` | Tab bar, floating buttons, pinned action bars | 4% white | Floats over content, always topmost, must let what is beneath it read through |
| `.surface` | Cards in the content flow | 7% white | Text sits directly on it and nothing floats above it |
| `.featured` | The one headline card on a screen | 9% + brand wash | Still glass, not a filled panel |

**Apple's `glassEffect` is not used.** It needs iOS 26 and an Xcode 26 SDK;
this project targets iOS 17 on Xcode 16. The hand-rolled version also allows
the transparency this design wants, which the system material does not expose.

What makes it read as glass rather than a blurred rectangle is the **edge**.
Real glass refracts at its rim, so the highlight is brightest at top-leading
and gone by bottom-trailing. One light source, placed consistently, is what
stops a screenful of glass elements looking like unrelated stickers.

**Never stack one glass level on another.** A translucent surface on a
translucent surface destroys legibility — this is why `GlassGroupButton` has no
material of its own and relies on the group's.

## Type

Tracking and leading are **size-specific**. A single letter-spacing value
applied everywhere is wrong somewhere, and at display sizes the wrongness is
visible. SwiftUI cannot bake tracking into a `Font`, so the scale is modifiers
that set size, weight, tracking and leading together.

| Role | Tracking | Note |
|---|---|---|
| `typeDisplay()` | −0.8 | 34pt titles. At default spacing a two-word title reads as two separate words |
| `typeTitle()` | −0.3 | Section headings |
| `typeRowTitle()` | −0.1 | The line the eye lands on in a row |
| `typeBody()` | 0, +2 leading | The only text read in sentences rather than scanned |
| `typeMeta()` | +0.05 | Supporting line under a row title |
| `typeEyebrow()` | +0.9 | Caps have no ascender variety to separate them; positive tracking is legibility, not decoration |

Put these in **shared components**, not at call sites. `SectionHeader` alone
appears on most screens — one decision there beats a hundred that drift.

### Why `brandCaption2` is the same size as `brandCaption`

Deliberate, and checked against the HIG rather than assumed.

Apple's typography specification gives iOS a **default text size of 17pt and a
minimum of 11pt**, and says to "follow the recommended default and minimum
text sizes for each platform ... to ensure your text is legible on all
devices". A true `.caption2` sits at roughly that 11pt floor at default
Dynamic Type — and below it once somebody scales text down, which is the
point at which the app stops being readable for the people most likely to
need the smaller step.

So `brandCaption2` resolves to `.caption`. The name is kept because call sites
reference it, but there is no second size.

The hierarchy those call sites want is still there — it is just carried by
colour rather than size, which is what the HIG actually prescribes: "adjust
font **weight, size, and color** as needed to emphasize important information
and help people visualize hierarchy." All sixteen `brandCaption2` call sites
pair it with `Theme.textSecondary`/`textTertiary`, or with a deliberate tint
(`TagChip`). Verified by sweeping them, not by assertion.

A reviewer noticing the two tokens are identical will read this as a bug. It
is not. Reducing the size would trade a real accessibility floor for a
difference nobody asked for.

### One typeface family

"Mixing too many different typefaces can obscure your information hierarchy
and hinder readability, in addition to making an interface feel internally
inconsistent or poorly designed." Everything in this app is
`design: .rounded`.

This is easy to break by accident: `.font(.footnote)` looks like a size
choice, but it also silently selects the *system* face. `ErrorBanner` did
exactly that, so every error message in the app — 45 call sites — rendered in
a different typeface from the screen it appeared on, at the one moment you
least want the interface to look like it has lost its composure. Reach for a
`brand*` token, or spell out `design: .rounded`.

Sources: [Typography](https://developer.apple.com/design/human-interface-guidelines/typography),
[Layout](https://developer.apple.com/design/human-interface-guidelines/layout).


## Colour and contrast

Every pairing the app uses is computed against WCAG 2.1 in `ContrastTests`, and
the suite fails the build if one drops below the floor. Two rules that are easy
to get wrong:

- **A fill and a foreground have opposite requirements.** `Theme.primary` is
  bright enough to clear 4.5:1 *as text* on the near-black ground, which makes
  it far too light to put white text *on*. That is why `fillBlue`/`fillGreen`
  exist separately. Do not collapse them back into one pair.
- **Composite before measuring.** 78% white over near-black is not white, and
  measuring it as white overstates the result.

## Motion

Springs, not durations — a spring can be interrupted and redirected, a
keyframe animation cannot.

- **Default: critically damped** (`dampingFraction: 1.0`). No overshoot.
- **Bounce only when the gesture carried momentum** (`~0.8`). Overshoot on a
  menu that faded in feels wrong; on a card you flicked it feels right.
- **Respond on press, not on release.** Every button style here scales or
  highlights on `isPressed`.
- **Enter and exit along the same path.** Booking steps slide in from the
  direction of travel and leave the way they came. The tab bar drops downward
  because that is where it went.

Never animate a property that moves hit-test geometry while somebody is
reaching for it. That is the whole reason `appearAnimation` is opacity-only and
`SelectableCardStyle` does not scale — it was the original "I had to tap it
three times" bug.

## Flow: what to ask, and when

One rule: **ask the most constraining question first, and never ask a question
whose answer you already have.**

Booking is the worked example. It used to be one screen asking which vet, which
pet, which slot, whether to repeat it, how to pay, what it costs, and a
liability waiver — all visible before a single decision. Now:

1. **When.** The slot is the scarce, time-sensitive resource and the thing
   somebody else can take while you deliberate. Asking first also lets the hold
   start early rather than after three other answers.
2. **Who for.** Skipped entirely on a one-pet account. A question with one
   possible answer is not a question.
3. **Confirm.** Price, payment, recurrence and waiver together, at the one
   moment the total is knowable.

Corollaries applied elsewhere:

- **Progress is segments, not "2 of 3".** This flow's length legitimately
  depends on how many pets the account has, and a total that changes is worse
  than none.
- **Show the price only where it is real.** Earlier it is a placeholder or a
  number moving under somebody while they pick.
- **Button labels say what the tap does** at *this* step — "Continue" while
  choosing, "Confirm booking" only when that is what happens next.
- **Hints name what is actually missing**, per step, rather than one generic
  line that is wrong on two screens out of three.
- **Composers rest small.** The add-pet field is one field until it has a name;
  the species picker and button have nothing to act on before that.

## Floating chrome

The tab bar floats and is mostly transparent. Consequences, all of which are
load-bearing:

- Scroll views use **`contentMargins`, not `safeAreaInset`**. An inset
  *reserves* the strip, which is the opaque-bar behaviour the floating bar
  exists to avoid. Content margins pad the content while the scroll view stays
  full-bleed, so rows travel under the glass and only the last is clear of it.
- It **collapses on scroll down, returns on scroll up**, with 12pt of
  hysteresis or it flickers while somebody holds still, and always returns near
  the top of a list.
- Screens with their own pinned action bar call **`hidesFloatingTabBar()`** —
  two floating bars is one too many, and the tab bar takes the position that
  belongs to the commit button. The hide is a **count, not a flag**: two such
  screens overlap during a push, and with a boolean the one leaving switches
  the bar back on over the one that just asked for it gone.

## Lists

Put the **date in the structure, not in every row**. A column of rows each
repeating "Thu 18 Sep, 2:00 PM" makes the reader parse the same string twenty
times to answer "what is happening this week"; a day header answers it once.
Rows then carry only what differs.

Say **Today** and **Tomorrow**. That is how people hold near-future dates; past
that horizon absolute dates are clearer than "in 4 days".

**Assemble meta lines from what is known**, rather than filling a fixed
template with em dashes. A visit with no vet assigned yet should say what it
does know, not display a placeholder that tells the reader only that the app
expected something it does not have.
