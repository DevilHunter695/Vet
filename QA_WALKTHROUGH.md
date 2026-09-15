# Feature walkthrough — VetCircuit

A tap-by-tap route to every feature on the checklist, so validating it takes
minutes rather than hunting through the app. Run in Xcode (`xcodegen generate`
then ⌘R). The app runs entirely on mock data, so every path below works with
no backend.

**Read this first — the four things most likely to be wrong**, because they
were broken until this pass and are the ones worth checking hardest:

| Check | Where | What "working" looks like |
|---|---|---|
| Taps register first time | Everywhere | No double/triple tapping. This was the headline bug — three separate causes fixed. |
| Address pin follows the map | Profile → Addresses → + | Drag the map; the saved coordinates must change. Previously the pin ate the gesture and **every address saved the same default coordinates**. |
| Coupon discount is 20%, not 23.6% | Cart → enter `FIRSTVISIT` | On a ₹1,000 cart the discount line must read ₹200. |
| Cancel an assigned visit | Visits → a confirmed/assigned visit → Cancel | Must be possible and must quote a refund. Previously "can no longer be cancelled" with no refund. |

---

## Account & Profile
- **A5 Edit profile** — Profile → Edit profile. Name/email/photo.
- **A6 Delete account** — Profile → Privacy & consent → delete.
- **A7 Export data** — Profile → Privacy & consent → export (JSON share sheet).
- **A8 Addresses + geofence** — Profile → Addresses. An address outside a served cluster should offer the waitlist, not silently succeed.
- **A9 Household** — Profile → Household. Invite by phone; shared pets and bookings appear.
- **A10 Face ID lock** — Profile → Preferences → "Require Face ID". Background and reopen.
- **A11 Blocked account** — not reachable in the UI; server-set state.

## Pets & Records
- **B1/B2** — Profile → Your pets → tap a pet card. Add via the inline composer.
- **B3 Weight chart** — Pet detail → weight section (shimmer while loading, then chart).
- **B4 Vaccinations** — Pet detail → vaccinations. Overdue shows a "Book vaccination visit" CTA — it must show an error if no service exists, not silently do nothing.
- **B5 Prescriptions / B6 Documents / B7 Health summary PDF** — all on Pet detail.
- **B8 Archive** — Pet detail → archive (deceased/rehomed). Pet stays visible, greyed.

## Discovery
- **C1 Address-first** — Book tab → address picker in the nav bar.
- **C2 Circuit list** — Book tab. Each row must show **next slot, "from" price, rating, verified seal**.
- **C3 Filters / C4 Sort** — Book tab toolbar.
- **C5 Vet detail** — Book → tap a circuit → tap the vet card. "Next 7 days" availability must be populated.
- **C6 Service detail** — Book → Services → a service.
- **C7 Coverage map** — Book tab toolbar → map icon.
- **C8 Search** — Book tab pull-down search. Try a vet name and a service name.
- **C9 Recently viewed / rebook** — Book tab, after viewing a circuit.
- **C10 Waitlist** — Profile → Addresses → an unserved address.
- **C11 Emergency** — Book tab → red banner at top.

## Catalog
- **D1/D2/D3** — Book → Services. Rows show duration, option count, add-on availability.
- **D3 add-on eligibility** — add a dog-only add-on to a cat's booking: must be **rejected**.
- **D4 Packages** — Book → Services → Packages (toolbar).
- **D6 Multi-pet** — Service detail → select two pets.

## Cart & Checkout
- **E1/E2** — add to cart, leave, return. Lines persist.
- **E3 Price breakdown** — Cart. Total is live; it must NOT require pressing a "Get price" button.
- **E4 Coupons / E5 Wallet & loyalty** — Cart.
- **E7 Slot hold** — Booking screen shows a counting-down hold once a slot is picked.
- **E8 Pay now vs pay after visit** — Cart and Booking.
- **E9 Saved cards** — Profile → Payment methods. "Make default" must be a visible button, not swipe-only.
- **E11 Tip** — Visit detail (completed visit) → Tip. Buttons must disable while submitting.

## Scheduling
- **F1/F2 Slot picker** — Booking screen. Slots grouped by day as chips, with "N left" when scarce.
- **F3 Reschedule / F4 Cancel policy** — Visits → a visit. Cancel states the refund in money.
- **F8/F9** — buffer and blackout filtering; visible only as slots that don't appear.

## Payments
- **G1/G2** — hosted checkout sheet; confirmation via webhook.
- **G3 Retry** — Visit detail after a failed payment.
- **G4 Refunds** — issued automatically on cancel.
- **G5 GST invoice** — Visit detail → Invoice. Total must **include** GST and itemise it.
- **G6 Wallet ledger** — Profile → Wallet.

## Subscriptions
- **H1 Plans** — Profile → membership card → View plans.
- **H3 Manage** — Profile → Manage membership.
- **H7 Corporate seats** — Plans → Corporate/RWA. Tapping a seat row must NOT unassign it; only the × should, with confirmation.

## Live visit
- **I1 Happening now** — Visits tab, top card, with progress bar and actions.
- **I2 Timeline** — Visit detail → View full timeline.
- **I4 Live map + ETA** — Visit detail → track (full-bleed map, ETA floats over it).
- **I5 OTP** — Visit detail when the vet has arrived.
- **I6 Waiver** — first booking. A failure must show an error, not silently continue.
- **I7 Checklist** — Visit detail → checklist.

## Communication
- **J1/J2/J3** — Visit detail → Message. Send and photo buttons must be easy to hit.
- **J5 Auto-close** — chat closes 48h after a terminal visit, cancelled ones included.
- **J7 Notifications** — Profile → Notification preferences / centre.

## Post-visit
- **K1 Visit record / K2 Prescription PDF / K4 Certificate PDF** — Visit detail and Pet detail.
- **K3 Medication reminders** — Pet detail → reminders.
- **K5 Follow-up** — Visit detail → "Book free follow-up". Must show an error if it can't resolve, not nothing.
- **K6 Lab tests / K7 Review / K8 Dispute** — Visit detail.

## Trust, support, growth, settings
- **L3 Verified badge** — circuit rows and vet detail.
- **L4 SOS** — live tracking screen, with confirmation.
- **L8 Disclaimer** — Book tab, under the emergency banner.
- **M1/M2/M4/M5** — Profile → Support & legal. Call support is gated to 9am–9pm IST.
- **N1 Referral** — Profile → Invite friends.
- **N4 Loyalty** — Profile → Rewards, with points to next tier.
- **N7 Deep links** — `xcrun simctl openurl booted "vetcircuit://household"`.
- **O1/O3/O5** — Profile → Preferences and Privacy & consent. O3 switches light/dark; check the aurora in both.
- **O7/O8** — force-upgrade and maintenance gates; server-driven.

---

## Known gaps — not bugs to report

- Runs on **mock data only**. Supabase repositories exist but aren't wired (needs credentials).
- **Sign-in, accessibility and translation** were explicitly out of scope this pass.
- **Coupon usage limits** (`usageLimit`, `perUserLimit`) are not enforced client-side — has to be server-side.
- **Platform no-show**: if no vet is ever assigned, the visit is auto-cancelled, the customer is charged 100%, and it is labelled "Cancelled by you". Awaiting a product decision on the refund; the label is wrong either way.
- CI's test step is `continue-on-error: true`, so a real test failure still reports the job green.
