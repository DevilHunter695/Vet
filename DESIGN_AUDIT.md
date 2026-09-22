# Charge — design brief audit

Every line below was re-verified against the code on 2026-09-22, not
recalled from memory. Where a claim is partial it says so and says what
is left; where something was deliberately not changed it says why,
because "not done" and "decided against" are different answers and only
one of them is work.

## Done and verified

| # | Brief item | Evidence in code |
|---|---|---|
| 1 | Native Liquid Glass tab bar | `VetCircuitApp.swift` — `TabView` + `SwiftUI.Tab`, `.tabBarMinimizeBehavior`, `.tabViewBottomAccessory` |
| 2 | "Vet en route" is a real bottom accessory | `TabBarAccessory.swift` reads `@Environment(\.tabViewBottomAccessoryPlacement)`, distinct inline/expanded forms |
| 3 | Glass in the UI layer only | `glassCard` no longer routes to `glassPanel`; the only `glassEffect` uses left are two pinned action bars and one modal overlay — all floating chrome |
| 4 | Services as grouped rows | `ServiceRow` has no `TagChip`, no `glassCard`; name / summary·duration / right-aligned price |
| 5 | Variant + pet + add-on selection | `checkmark` / `checkmark.circle.fill` in `ServiceDetailView`; `CheckboxRow` previously had **no checkbox at all** |
| 6 | Cart as native toolbar action | `CartToolbarButton` — SF Symbol + badge in a `ToolbarItem`; was already correct |
| 7 | Fewer accent colours | No `hue: 0.72` (purple) or `hue: 0.03` (coral) left in `Theme.swift` |
| 8 | Pills for states only | 16 `TagChip`s remain, each a state (verified / archived / allergies / owner / "1 spot left"); weight, species and languages un-pilled |
| 9 | Native buttons | `PillButton`, `SecondaryButton` on `.bordered` / `.borderedProminent`; `role` passed to `Button` |
| 10 | Active visit hierarchy | Names are text not capsules; "Open visit" full-width primary, "Message" a 44pt icon button |
| 11 | Upcoming visits scannable | `VisitRow` is a grouped row, day-grouped, no per-row glass |
| 12 | Contrast floor holds | `ContrastTests` **passed in CI** after the palette change — text 18.8/11.5/7.6:1, danger 5.37:1 |
| 13 | Reduce Motion | `appearAnimation` drops the stagger, keeps a cross-fade; `AppMotion` gates looping animations |
| 14 | VoiceOver on new controls | `.isSelected` traits on selection rows, decorative checkmarks hidden, icon-only Message button labelled |
| 15 | Empty states | `ContentUnavailableView`; the old one took a `systemImage` and **ignored it**, drawing a paw everywhere |

## Partial — started, deliberately incremental

| Item | State | What is left |
|---|---|---|
| Spacing scale | `Spacing.swift` defined; 28 adoptions in converted screens | Remaining literals convert as screens are touched. A blind sweep of 12 values would be unreviewable |
| Corner radius | Fixed at the definitions (`Card`, `glassCard`, `featuredGlassCard` → `Spacing.corner`) | Individual literals in untouched screens |
| Dynamic Type | OTP, wallet balance and review stars fixed | 5 absolute sizes remain, all decorative glyphs, plus the avatar initials (documented exception) |
| Copy reduction | 8 longest strings cut | More could go; the emergency copy stays long on purpose |

## Deliberately not changed

- **`.tabBarMinimizeBehavior` is `.automatic`, not `.onScrollDown`.** `.onScrollDown` is what caused the stuck-minimised bar reported from the device: a short screen minimises it and then offers no upward scroll to restore it. The brief says to choose the behaviour that fits the UX.
- **Emergency copy stays long.** "unconscious, bleeding heavily, struggling to breathe" — each clause is load-bearing for someone deciding whether to drive to a clinic.
- **Packages stay cards.** A bundle is a distinct object with contents, a price and a saving, which is the brief's own test for when a card earns its place.
- **Cancellation stays a native `confirmationDialog`.** Its anchored placement is the system's; the brief asks for native controls over imitations.

## Open

- **One UI test failing:** `testAccountAndMoneyScreensAreAllReachable`, tapping Wallet. Current explanation is a stale tap coordinate from scroll deceleration (`tapWhenSteady`, `5080eda`), pushed and unverified. Previous explanations of this failure were wrong several times over, so it is not closed until a run says so.
- **CI backlog:** the redesign commits are queued behind a contended runner. Build and unit tests have passed on the batches that have run.
