# VetCircuit — Product & Technical Master Plan
### v2.0 · September 2026 · from prototype to a deployable, defensible, hard-to-break product

> **What changed from v1.** The v1 plan described a demo: browse, book one visit, chat, pay, rate.
> That is roughly 25% of what a real marketplace needs before it can take money from strangers.
> This version specifies the whole system — catalog with real options, cart and transparent pricing,
> cancellation/refund policy as code, medical records, masked calling, disputes, payouts, ops tooling,
> the reliability engineering that keeps money and bookings correct under failure, and the security and
> Indian regulatory work (DPDP Rules 2025) that is now date-bound, not optional.
>
> It stays honest about being a two-person team: every section is ordered so the **P0 column is still
> shippable in ~10 weeks**, and everything below it is explicitly deferred with a reason.

---

## 0. How to read this document

| Tag | Meaning |
|---|---|
| **P0** | Must exist before the first rupee is taken from a stranger. Blocking for public launch. |
| **P1** | Needed within ~6 weeks of launch or the product feels broken/unsafe at small scale. |
| **P2** | Scale/differentiation. Only after P0+P1 are proven by real repeat usage. |
| ✅ | Already implemented in this repo today |
| 🔨 | Partially implemented (skeleton/mock/stub exists) |
| ⛔ | Not started |

Status tags are grounded in the current tree (see **Appendix F**). Three rules govern every decision below:

1. **The client is never the source of truth** for money, availability, or state transitions.
2. **Every irreversible action is idempotent, audited, and reversible by ops.**
3. **If a dependency is down, the app degrades to a readable, honest state — it never lies and never loses a write.**

---

## 1. Market reality check (as of 2026)

### 1.1 The landscape you are actually entering

India's pet care market is on a path from ~$3.6B (2024) toward ~$7B by 2028, and the well-funded players have
already defined what a "pet care app" means to a customer:

- **Vetic** — raised **$40M** (Bessemer-led); ~65 clinics across 11 cities, 15 round-the-clock emergency
  facilities, **vet-at-home**, e-pharmacy and supplies in one connected platform.
- **Supertails** — raised **$30M** (total ~$57M), targeting ₹500 Cr ARR; 100+ vets nationwide, clinics in
  Bengaluru, online consults, e-pharmacy, grooming, quick delivery in top 10 cities.

**Implication #1 — you cannot win on breadth.** They have clinics, pharmacy licences, warehouses and a
capital advantage of three orders of magnitude. A feature-for-feature clone loses.

**Implication #2 — they have already set the customer's baseline expectations.** Because these apps exist,
a first-time user of *your* app will assume all of the following are present, and will treat their absence
as brokenness, not as "MVP scope":

- The price, in full, *before* booking — including travel/visit fee and taxes.
- A choice of service (not just "a visit"): consult vs vaccination vs grooming vs sample pickup.
- A vet profile with credentials, real reviews, and "next available".
- Live status with an ETA once someone is on the way.
- A digital record after the visit: notes, prescription, vaccination certificate, next due date.
- The ability to cancel, reschedule, and get money back under a stated policy.
- A way to reach a human when something goes wrong.

Those are the P0 list, not the V2 list. That is the single biggest correction this document makes to v1.

### 1.2 Your actual wedge: density, not dispatch

Everyone else dispatches a vet across a city. **A circuit is a pre-committed loop through one dense
residential cluster on a fixed schedule** — the same logic that makes milk delivery and diagnostics
sample-pickup work in India.

The economics are the whole argument:

```
Random dispatch:   1 visit per 60–90 min (30–45 min travel) → travel cost ≈ ₹150–250 per visit
Circuit (dense):   3–5 visits per 2-hour block (5–10 min hops) → travel cost ≈ ₹30–60 per visit
```

That delta is the business. It funds a lower customer price *and* a higher vet hourly income at the same time.
Everything in the product should reinforce it:

- **Sell the slot, not the dispatch.** "Tue & Fri, 4–6 PM, Prestige Lakeside" is the unit of inventory.
- **Reward cluster density.** Neighbour referrals, RWA/apartment bulk plans, "3 more bookings in your block
  unlocks this circuit" — the waitlist is a demand-aggregation tool, not an empty state.
- **Subscriptions are the retention flywheel**, because a recurring visit is a *guaranteed stop* on a route
  you already planned.

### 1.3 The same engine sells three verticals

A circuit engine is vertical-agnostic: scheduled, recurring, in-home, professional-delivered service in a
dense cluster. Vet → elder care (nursing/physio check-ins) → physio/rehab. The repo already models
`Vertical`. Keep the abstraction, **but do not market more than one vertical until one is profitable.**

---

## 2. Users, surfaces, and what each one needs

| Surface | User | Tech | Why |
|---|---|---|---|
| **Customer app** | Pet owner / family member | **Native SwiftUI (iOS 17+)** | Trust-critical, notification-heavy, Live Activity for ETA, App Store distribution |
| **Partner app** | Vet / para-vet | **Responsive web (Next.js), installable PWA** P0 → React Native P2 | Vets work from a phone but need zero install friction; a work tool doesn't need App Store polish. Push via Web Push + SMS fallback. |
| **Ops console** | You two, then 1–2 ops staff | **Next.js (admin-web)** | Verification, disputes, refunds, manual overrides — *the most underrated P0 surface* |
| **Public web** | Prospects, SEO, App Store review | **Next.js static** | Privacy policy + T&C are mandatory for submission; landing page is your waitlist funnel |
| **Android** | — | **Deferred to P2** | Only after iOS proves repeat purchase |

### Jobs-to-be-done

| Persona | Job | Failure mode that kills you |
|---|---|---|
| Pet owner | "Something is wrong with my dog and I don't want to fight traffic with a scared animal in a carrier" | Uncertainty. They will cancel if they can't see status. |
| Routine owner | "Vaccination is due and I will forget" | No reminder = no repeat purchase = no business |
| Vet / para-vet | "I want a full, predictable day with no dead travel and guaranteed payout" | Unclear route, late payment, no-shows |
| Ops (you) | "A visit went wrong at 9 PM and I need to fix it now" | No tooling → you edit the production database by hand → data corruption |

---

## 3. Complete feature inventory

This is the part v1 was missing. Everything a user expects — including the mundane CRUD, the deletes, the
cart, the detail screens, and the "multiple options" — enumerated so nothing is discovered at week 9.

### A. Identity & account

| # | Capability | Pri | Status | Notes |
|---|---|---|---|---|
| A1 | Sign in with Apple | P0 | ✅ | Required by App Store if any other social login exists |
| A2 | Phone + OTP (primary in India) | P0 | 🔨 | Rate-limited, 6-digit, 5-min TTL, max 5/hr/number, 20/hr/device |
| A3 | Session persistence + silent refresh | P0 | 🔨 | Access 15 min, refresh 60 days w/ **rotation + reuse detection** |
| A4 | Sign out (single device + all devices) | P0 | 🔨 | "Sign out everywhere" revokes refresh family |
| A5 | Edit profile (name, email, photo, language) | P0 | 🔨 | |
| A6 | **Delete account + data** | **P0** | ⛔ | **App Store guideline 5.1.1(v) — a hard rejection if missing.** 30-day soft window, financial records retained per statute with justification shown to user |
| A7 | Export my data (JSON + PDF of records) | P1 | ⛔ | DPDP data-principal right |
| A8 | Multiple addresses (home/office/parents), default, geofence check | **P0** | ✅ | A circuit is *address-scoped* — this is core inventory logic, not a nicety |
| A9 | Household: invite spouse/family to same pets & bookings | P1 | ⛔ | Very common real-world need; roles: owner/member |
| A10 | Biometric lock on app (Face ID) | P1 | ⛔ | Medical records = sensitive |
| A11 | Blocked/deactivated account handling | P1 | ⛔ | Graceful screen, support path |

### B. Pets, records & documents

| # | Capability | Pri | Status | Notes |
|---|---|---|---|---|
| B1 | Multiple pets per household, add/**edit**/**delete**/archive | P0 | 🔨 | Delete = soft-delete; visit history must survive |
| B2 | Pet detail screen: photo, species, breed, DOB, sex, neutered, weight, microchip, allergies, chronic conditions | P0 | 🔨 | Currently only name/species/breed/DOB |
| B3 | Weight & vitals history (chart) | P1 | ⛔ | Strong retention hook |
| B4 | Vaccination record + **next-due reminders** | **P0** | ⛔ | This is the single best repeat-purchase driver in pet care |
| B5 | Prescription history | P1 | ⛔ | Must be vet-issued only (see §8.7) |
| B6 | Document vault (upload prior reports, insurance) | P1 | ⛔ | Private bucket, signed URLs, virus scan |
| B7 | Shareable pet health summary (PDF) | P2 | ⛔ | For boarding/travel/clinic referral |
| B8 | Deceased/rehomed pet handling | P1 | ⛔ | Stops reminders; handle with care in copy |

### C. Discovery, detail & "multiple options"

| # | Capability | Pri | Status | Notes |
|---|---|---|---|---|
| C1 | Address-first discovery: pick address → show circuits serving it | P0 | 🔨 | Replaces v1's free-text "area" |
| C2 | Circuit list with next-available slot, price-from, vet rating | P0 | ✅ | |
| C3 | **Filters**: service type, date, time-of-day, price, rating, species handled, language, gender of vet | **P0** | ⛔ | "Vet who handles cats", "Hindi-speaking" are real filters in India |
| C4 | **Sort**: soonest, cheapest, top-rated, previously-booked | P0 | ⛔ | |
| C5 | **Vet detail screen**: photo, bio, VCI reg no. (verified badge), years of experience, species, languages, services + prices, ratings histogram, reviews w/ photos, next 7 days availability | **P0** | 🔨 | Today there is no vet detail screen at all |
| C6 | **Service detail screen**: what's included, duration, what to prepare, price, add-ons, FAQs | **P0** | ⛔ | Directly your "showing details" requirement |
| C7 | Map view of cluster coverage | P1 | 🔨 | |
| C8 | Search (vet name, service, symptom) | P1 | ⛔ | Postgres FTS is enough; do not add a search cluster |
| C9 | Recently viewed / rebook last visit (1 tap) | P1 | ⛔ | Highest-converting element in repeat marketplaces |
| C10 | Waitlist for uncovered clusters + "N neighbours waiting" | P1 | ⛔ | Demand aggregation, not a dead end |
| C11 | Emergency path: "This is urgent" → nearest 24×7 clinic + triage call | **P0** | ⛔ | Safety-critical. You are not an emergency service — say so and route out. |

### D. Service catalog (the "multiple options for each thing")

The v1 model had a `Visit` with no concept of *what* was being bought. That is the largest structural gap.

```
Service (Home consultation)
 ├─ ServiceVariant   — Standard 20 min ₹599 · Extended 40 min ₹899 · Follow-up (14d) ₹0
 ├─ Add-on           — Nail trim ₹149 · Deworming ₹249 · Blood sample pickup ₹399
 ├─ Eligibility      — species, pet age, vertical, requires-Rx, vet qualification
 └─ PriceRule        — base + per-pet + cluster travel fee + peak multiplier + tax
```

| # | Capability | Pri | Status |
|---|---|---|---|
| D1 | Service catalog w/ categories (Consult, Vaccination, Grooming, Diagnostics, Deworming, Dental, Elder-care visit, Physio session) | **P0** | 🔨 |
| D2 | Variants per service (duration/tier/package) | **P0** | 🔨 |
| D3 | Add-ons attachable to a booking | P1 | ⛔ |
| D4 | Packages/bundles ("Puppy first-year: 4 visits + 3 vaccines") | P1 | ⛔ |
| D5 | Per-vet service availability & per-vet pricing overrides | P1 | ⛔ |
| D6 | Multi-pet in one visit (2nd pet at reduced fee) | **P0** | ⛔ | Extremely common; breaks the whole pricing model if bolted on later |
| D7 | Catalog managed from ops console, not hardcoded | P0 | ⛔ |

### E. Cart, pricing & checkout

| # | Capability | Pri | Status | Notes |
|---|---|---|---|---|
| E1 | **Cart**: multiple services/pets/add-ons in one booking | **P0** | ⛔ | Add / **remove** / change quantity / clear |
| E2 | Cart persistence across devices + restore on relaunch | P0 | ⛔ | Server-side cart, not local only |
| E3 | **Transparent price breakdown**: subtotal · per-pet · travel fee · peak · discount · GST · total | **P0** | ⛔ | Non-negotiable for trust |
| E4 | Coupon / promo code entry + validation + stacking rules | P1 | ⛔ | |
| E5 | Wallet credits & loyalty point redemption at checkout | P1 | 🔨 | Loyalty exists; redemption doesn't |
| E6 | **Server-authoritative quote**: `POST /quotes` returns a signed, TTL'd quote; order must reference a valid quote | **P0** | ⛔ | Prevents client price tampering entirely |
| E7 | Slot **hold** (10 min) during checkout, auto-release | **P0** | ⛔ | Prevents the "slot taken while I was paying" disaster |
| E8 | Payment method choice: UPI intent, cards, netbanking, wallets, **pay-after-visit (cash/UPI to vet)** | P0 | 🔨 | Cash-on-visit is table stakes in India |
| E9 | Saved payment methods (gateway-tokenized, never stored by you) | P1 | ⛔ | |
| E10 | Order confirmation screen + receipt email/SMS | P0 | 🔨 | |
| E11 | Tip the vet after visit | P2 | ⛔ | |

### F. Scheduling & booking lifecycle

| # | Capability | Pri | Status |
|---|---|---|---|
| F1 | Slot picker from circuit schedule (7–14 day horizon) | P0 | ✅ |
| F2 | Capacity per slot (N stops per block), not boolean availability | **P0** | ✅ |
| F3 | **Reschedule** (with policy window) | **P0** | ⛔ |
| F4 | **Cancel** with policy: free >4h, 50% <4h, 100% no-show | **P0** | 🔨 (cancel exists; no policy/refund) |
| F5 | Recurring bookings (monthly deworming, weekly physio) | P1 | ⛔ |
| F6 | Vet-initiated reschedule + customer accept/decline + auto-compensation credit | P1 | ⛔ |
| F7 | Customer no-show & vet no-show handling, both directions | P1 | ⛔ |
| F8 | Buffer/travel-time aware slot generation | P1 | ⛔ |
| F9 | Blackouts/leave/holiday handling for vets | P1 | ⛔ |

### G. Payments, billing & refunds

| # | Capability | Pri | Status | Notes |
|---|---|---|---|---|
| G1 | Hosted checkout (Razorpay), **never raw card data** | P0 | ✅ | PCI scope avoided by construction |
| G2 | **Webhook-only confirmation**, signature-verified, idempotent | P0 | ✅ | Already in `payment-webhook` — keep this discipline everywhere |
| G3 | Payment retry on failure + clear failure states | P0 | 🔨 | |
| G4 | **Refunds** (full/partial), initiated by ops, tracked to gateway | **P0** | ⛔ | You cannot launch without a refund path |
| G5 | GST-compliant invoice PDF per order | **P0** | ⛔ | Legal requirement once registered |
| G6 | Wallet + double-entry ledger | P1 | ⛔ | Credits, compensation, refund-to-wallet |
| G7 | **Vet payouts**: earnings view, weekly payout run, reconciliation | **P0 (partner)** | ⛔ | Vets quit over late/unclear pay faster than over anything else |
| G8 | Daily reconciliation job: gateway settlements vs your ledger | P1 | ⛔ | |
| G9 | Chargeback/dispute handling from gateway | P2 | ⛔ | |

### H. Subscriptions & plans

| # | Capability | Pri | Status |
|---|---|---|---|
| H1 | Plan catalog with visible inclusions & fair-use limits | P0 | 🔨 |
| H2 | Purchase via gateway **recurring mandate (UPI Autopay / e-mandate)** | P0 | 🔨 |
| H3 | Manage: upgrade, downgrade, **pause**, **cancel**, view next renewal | **P0** | ⛔ |
| H4 | Renewal reminders (T-7, T-1) + receipt | P0 | 🔨 |
| H5 | Dunning: failed renewal → retry ladder → grace → downgrade | P1 | ⛔ |
| H6 | Subscription credits consumed by bookings (entitlement engine) | P1 | ⛔ |
| H7 | Corporate/RWA seat-based plan + seat assignment | P2 | 🔨 |

### I. The live visit (your trust moment)

| # | Capability | Pri | Status | Notes |
|---|---|---|---|---|
| I1 | Persistent "what's happening now" card on Home | P0 | 🔨 | The highest-trust feature per unit of effort |
| I2 | Status timeline w/ timestamps (requested → confirmed → assigned → en route → arrived → in progress → completed) | P0 | 🔨 | Expand the 5-state enum to 8 |
| I3 | **Live Activity + Dynamic Island** for "vet en route / ETA" | P1 | ⛔ | iOS-native differentiator; huge perceived-quality win |
| I4 | Live map tracking with ETA | P1 | 🔨 | |
| I5 | **Start-of-visit OTP** (customer reads 4-digit code to vet) | **P0** | ⛔ | Anti-fraud + proof-of-service. Cheap, high value. |
| I6 | Digital consent/liability waiver accepted in-app before first visit | **P0** | ⛔ | Legal shield |
| I7 | Visit checklist completed by vet → becomes the customer's record | P0 | 🔨 | |
| I8 | Post-visit summary push + in-app detail | P0 | 🔨 | |

### J. Communication

| # | Capability | Pri | Status | Notes |
|---|---|---|---|---|
| J1 | Per-visit chat, text | P0 | ✅ | |
| J2 | Chat attachments (photo of the symptom) | **P0** | ⛔ | Pet owners send photos. Always. |
| J3 | Read receipts, typing, unread badge | P1 | 🔨 | |
| J4 | **Masked voice calling** (Exotel/Twilio proxy — real numbers never exposed) | **P0** | ⛔ | Privacy + safety + "vet can't find the gate" reality |
| J5 | Chat auto-closes 48h post-visit, with escalation to support | P1 | ⛔ | Prevents unpaid consulting over chat |
| J6 | Video consult | P2 | 🔨 (stub) | |
| J7 | Notification centre in-app + per-channel preferences | P1 | ⛔ | |
| J8 | Transactional SMS/WhatsApp fallback when push fails | P1 | ⛔ | Android-less households, push disabled |

### K. Post-visit care

| # | Capability | Pri | Status |
|---|---|---|---|
| K1 | Visit record: diagnosis notes, procedures done, meds given | P0 | 🔨 |
| K2 | Prescription (structured, vet-signed, PDF) | P1 | ⛔ |
| K3 | Medication reminders | P2 | ⛔ |
| K4 | Vaccination certificate PDF + next-due auto-scheduling | P1 | ⛔ |
| K5 | Follow-up booking in 1 tap (free follow-up window) | P1 | ⛔ |
| K6 | Lab test ordering + report delivery | P2 | ⛔ |
| K7 | Rate & review (stars + tags + optional photo) | P0 | ✅ |
| K8 | Report a problem with this visit → dispute ticket | **P0** | ⛔ |

### L. Trust, safety & emergency

| # | Capability | Pri | Status | Notes |
|---|---|---|---|---|
| L1 | Manual VCI registration verification before a vet goes live | P0 | 🔨 | Do this by hand, every time, forever |
| L2 | Document-backed onboarding: degree, VCI cert, ID, police verification, photo | P0 | ⛔ | |
| L3 | "Verified" badge + credentials visible on vet profile | P0 | ⛔ | |
| L4 | **SOS button + share-my-visit link** during an in-home visit | P1 | ⛔ | A stranger is inside a home. Take this seriously. |
| L5 | Incident reporting (both directions) + vet suspension flow | P1 | ⛔ | |
| L6 | Review moderation (profanity, PII, defamation) | P1 | ⛔ | |
| L7 | Professional indemnity / liability insurance requirement for vets | P1 | ⛔ | Commercial, not code — but blocks launch legally |
| L8 | Clear "not an emergency service" disclaimer + escalation routing | **P0** | ⛔ | |

### M. Support & disputes

| # | Capability | Pri | Status |
|---|---|---|---|
| M1 | Help centre / FAQ (remote content, not app-updated) | P0 | ⛔ |
| M2 | In-app "Contact support" → ticket with visit context attached | P0 | ⛔ |
| M3 | Ops ticket queue + SLA + canned responses | P0 | 🔨 |
| M4 | Refund/credit issuance from a ticket, with audit trail | P0 | ⛔ |
| M5 | Call support (business hours) | P1 | ⛔ |

### N. Growth & retention

| # | Capability | Pri | Status |
|---|---|---|---|
| N1 | Referral code + share sheet + attribution + fraud guard | P1 | 🔨 |
| N2 | Coupon campaigns (first-visit, win-back, cluster-launch) | P1 | ⛔ |
| N3 | Lifecycle pushes: vaccination due, renewal, dormant 60d, abandoned cart | P1 | ⛔ |
| N4 | Loyalty points & tiers | P2 | ✅ |
| N5 | In-app rating prompt (SKStoreReviewController, after a 5★ visit only) | P1 | ⛔ |
| N6 | Home Screen widget: next visit / vaccination due | P2 | ⛔ |
| N7 | Deep links + universal links for every campaign target | P1 | ⛔ |

### O. Settings, privacy & platform UX

| # | Capability | Pri | Status |
|---|---|---|---|
| O1 | Notification preferences per channel/category | P1 | ⛔ |
| O2 | Language: English + Hindi (+1 regional at launch cluster) | P1 | ⛔ |
| O3 | Appearance light/dark/system | P0 | ✅ |
| O4 | Accessibility: Dynamic Type to AX5, VoiceOver, Reduce Motion | P0 | 🔨 |
| O5 | **Consent dashboard**: what you collect, why, withdraw consent | P0 (DPDP) | ⛔ |
| O6 | Privacy policy + T&C in-app and on web | P0 | ⛔ |
| O7 | **Force-upgrade gate** (server-driven minimum version) | **P0** | ⛔ | Your only true rollback lever for a shipped binary |
| O8 | Maintenance mode screen (server flag) | P0 | ⛔ |

### P. Partner (vet) app — P0 set

Route for today (ordered stop list, one-tap navigate) · accept/decline assignment · start visit via OTP ·
visit checklist + notes + prescription · mark complete · chat/masked call · **earnings + payout statement** ·
availability & leave · document upload for verification · SOS/incident report.

### Q. Ops console — P0 set

Vet verification queue (docs side-by-side, approve/reject with reason) · circuit & slot editor · live visit
board with stuck-state alerts · manual status override (audited) · refund/credit issuance · dispute queue ·
coupon & catalog management · user lookup + impersonate-read-only (audited) · payout run · metrics dashboard ·
**feature-flag & kill-switch panel**.

> **The console is P0, not P2.** Every hour you don't have it, you are running ops with `psql` against
> production — which is how student projects lose real customer data.

### R. Platform services (invisible but P0)

Remote config + feature flags · analytics event pipeline · crash + error reporting (Sentry) · structured
logging with PII scrubbing · job scheduler · transactional outbox · notification service (APNs + SMS +
WhatsApp) · idempotency store · audit log.

---

## 4. Information architecture

```
Tab 1  Home        Active visit card · next visit · pets w/ due vaccinations · rebook · offers
Tab 2  Book        Address → service (options) → vet/circuit → slot → cart → quote → pay
Tab 3  Visits      Upcoming · Past → Visit detail (timeline, record, invoice, chat, dispute)
Tab 4  Pets        Pet list → Pet detail (profile, records, vaccinations, documents, weight)
Tab 5  Account     Profile · addresses · household · subscription · wallet · payments ·
                   notifications · language · privacy & consent · help · legal · delete account
```

**Booking flow (one decision per screen — keep this from v1, it was right):**

```
Address ▸ Service category ▸ Service + variant ▸ Pets (1..n) ▸ Add-ons ▸
Circuit/vet options ▸ Slot ▸ [HOLD 10:00] ▸ Cart review + price breakdown ▸
Coupon/credits ▸ Payment method ▸ Pay ▸ Confirmation (+ add to calendar)
```

**Visit state machine** (replaces the 5-state enum — see Appendix B for the transition table):

```
requested → confirmed → assigned → en_route → arrived → in_progress → completed
     ↘ cancelled_by_user   ↘ cancelled_by_vet   ↘ no_show_user   ↘ no_show_vet   ↘ failed
completed → disputed → resolved
```

---

## 5. Data model v2

v1 had 8 tables. A working marketplace needs ~40. Grouped, with the non-obvious ones annotated.

**Identity & household**
`profiles` · `addresses` (geo point, cluster_id, landmark, gate/access notes) · `households` ·
`household_members` (role) · `devices` (push token, app version, platform) · `consents` (purpose, version,
granted_at, withdrawn_at) · `deletion_requests`

**Pets & clinical**
`pets` (+ sex, neutered, microchip, allergies, chronic, archived_at) · `pet_weights` · `pet_documents` ·
`medical_records` · `vaccinations` (given_at, **next_due_at**, batch_no) · `prescriptions` +
`prescription_items`

**Supply side**
`vets` · `vet_credentials` (doc type, storage path, verified_by, verified_at) · `vet_availability` ·
`vet_blackouts` · `circuits` (cluster polygon/geohash, vertical) · `circuit_templates` ·
`circuit_runs` (a materialised instance of a circuit on a date) · `circuit_stops` (ordered, ETA) ·
`slots` (**capacity**, booked_count) · `slot_holds` (expires_at)

**Catalog & pricing**
`services` · `service_variants` · `addons` · `service_vet_map` · `price_rules` · `coupons` ·
`coupon_redemptions` · `quotes` (server-signed, TTL)

**Commerce**
`carts` · `cart_items` · `orders` · `order_items` · `payments` · `payment_attempts` · `refunds` ·
`invoices` · `wallets` · `wallet_ledger` (**double-entry, append-only**) · `subscriptions` ·
`subscription_entitlements` · `subscription_events`

**Fulfilment**
`visits` (→ order_item) · `visit_events` (**append-only audit of every transition**) · `visit_otps` ·
`vet_locations` · `visit_checklists`

**Interaction**
`chat_threads` · `chat_messages` · `chat_attachments` · `call_sessions` (masked-call metadata only) ·
`reviews` · `review_media` · `disputes` · `dispute_messages` · `support_tickets`

**Platform**
`notifications` · `notification_preferences` · `outbox` · `idempotency_keys` · `audit_log` ·
`feature_flags` · `app_config` (min_supported_version, maintenance) · `referrals` · `loyalty_accounts` ·
`payouts` · `vet_ledger`

### 5.1 Invariants that must be enforced in the database, not the app

| Invariant | Mechanism |
|---|---|
| A slot can never exceed capacity | `booked_count <= capacity` CHECK + `SELECT … FOR UPDATE` on the slot row inside the booking transaction |
| One active hold per (slot, user) | Partial unique index where `expires_at > now()` |
| Money never drifts | All amounts `integer` minor units; ledger entries sum to zero per transaction; nightly invariant job |
| Status can only move legally | `visits_status_transition` trigger checking an allowed-transitions table |
| History is never rewritten | `visit_events`, `wallet_ledger`, `audit_log` are INSERT-only (revoke UPDATE/DELETE even from service role) |
| Deleted user ≠ deleted invoices | Soft-delete profile, anonymise PII in place, retain financial rows with `anonymised_at` |
| No cross-tenant reads | RLS on every table, default-deny, tested in CI |

---

## 6. Architecture v2

### 6.1 Layering (keep v1's clean architecture — it was the right call — and modularise it)

```
┌──────────────────────────────────────────────────────────────┐
│ Presentation   SwiftUI views · @Observable ViewModels · Router│
├──────────────────────────────────────────────────────────────┤
│ Domain         Pure Swift: models, use cases, policies        │
│                (pricing, cancellation, eligibility) — testable│
│                with zero imports beyond Foundation            │
├──────────────────────────────────────────────────────────────┤
│ Data           Repository impls · APIClient · Realtime ·      │
│                SwiftData cache · Outbox · Keychain            │
├──────────────────────────────────────────────────────────────┤
│ Platform       Push · Analytics · FeatureFlags · Logging ·    │
│                Location · Payments · Files                    │
└──────────────────────────────────────────────────────────────┘
```

**Modularise into local SPM packages** once the app crosses ~30 screens (it will):
`VCDomain`, `VCData`, `VCDesignSystem`, `VCPlatform`, feature packages (`VCBooking`, `VCVisits`, `VCPets`,
`VCAccount`). Build-time and testability both improve; the app target becomes a thin composition root.

**Navigation**: a typed `Route` enum + `NavigationStack(path:)` per tab, driven by a `Router` in the
environment. Non-negotiable because deep links, pushes, and Live Activity taps must all land on an exact
screen — string-based navigation will not survive that.

**Offline-first** (the part v1 skipped):
- Reads: SwiftData cache with per-entity TTL; every screen renders from cache first, then revalidates.
- Writes: **mutation outbox** — user actions enqueue an idempotent command with a client-generated
  `idempotency_key`, replayed on reconnect with exponential backoff. Chat messages, cancellations, and
  profile edits must survive a lift-doors-network-dropout.
- Conflict rule: server wins for money/status; client wins for drafts.

### 6.2 Backend: Supabase + a thin trusted layer

Keep Supabase (Postgres, Auth, Realtime, Storage, RLS) — it is still the right call for two people. But v1's
"client talks to the DB directly" is only safe for *reads and personal writes*. Add **Edge Functions as a
trusted boundary** for everything the client must not be allowed to decide:

| Must go through a trusted function | Why |
|---|---|
| `POST /quotes` | Pricing is server-computed and signed; client sends only selections |
| `POST /orders` | Slot lock, capacity check, hold consumption, order+visit creation in one transaction |
| `POST /orders/:id/cancel` | Cancellation policy → refund amount is a server decision |
| `PATCH /visits/:id/status` | Role-gated state machine; customers can never set `completed` |
| `POST /payments/webhook` | Signature-verified, idempotent, the *only* writer of `payments.status = succeeded` ✅ |
| `POST /visits/:id/start` | OTP verification |
| Payouts, refunds, coupon issuance | Money creation |

Everything else (list my pets, read my visits, send a chat message) goes direct-to-Postgres under RLS. This
hybrid gives you speed where it's safe and a hard boundary where it matters.

**Database functions over app logic** for the booking transaction specifically: a single
`book_visit(p_quote_id, p_slot_id, p_idempotency_key)` PL/pgSQL function that locks, validates, inserts, and
returns — atomic by construction, impossible to half-execute.

### 6.3 Third-party services (pick once, wrap behind a protocol)

| Concern | Choice | Wrapped as |
|---|---|---|
| Payments | Razorpay (UPI Autopay, hosted checkout) | `PaymentGateway` |
| SMS/OTP | Supabase Auth + MSG91 fallback | `OTPSender` |
| WhatsApp/transactional | Gupshup/MSG91 template messages | `MessagingProvider` |
| Masked calling | Exotel | `CallBroker` |
| Maps/routing | MapKit (free) + OSRM/Google Routes for ETA only | `RoutingProvider` |
| Push | APNs direct (iOS) + Web Push (partner) | `PushService` |
| Crash/errors | Sentry | `ErrorReporter` |
| Analytics | PostHog (self-host or cloud free tier) | `AnalyticsClient` |
| Storage | Supabase Storage, private buckets + signed URLs | `FileStore` |

Every one behind a protocol in `VCPlatform`, so swapping a vendor is a one-file change and tests never touch
the network.

### 6.4 Circuit/routing engine (the thing that makes this company work)

```
CircuitTemplate (Prestige Lakeside · Tue/Fri · 16:00–18:00 · capacity 5 · vet A)
   │  nightly job materialises 14 days forward
   ▼
CircuitRun (2026-09-17 16:00, vet A, status: planned)
   │  bookings attach as stops
   ▼
CircuitStop (ordered by route optimisation at T-2h, ETA per stop)
   │  vet marks arrived/complete → downstream ETAs recompute → pushes fire
```

Rules: capacity by *service duration*, not stop count (a vaccination ≠ a 40-min consult); inter-stop travel
buffer from the cluster's typical hop time; a cancellation reopens the slot and re-optimises; no cross-cluster
stops on one run (that's dispatch, and it destroys the economics).

### 6.5 Scheduled jobs

Materialise circuit runs (nightly) · expire slot holds (1 min) · outbox dispatch (10 s) · vaccination-due
reminders (daily 9 AM) · subscription renewal + dunning (hourly) · payment reconciliation (daily) ·
stuck-visit detector (5 min: `en_route` > 2h, `in_progress` > 3h) · data-deletion executor (daily) ·
invariant checker (nightly) · review solicitation (T+2h post visit).

---

## 7. "Unbreakable": the reliability engineering

Nothing is unbreakable. What follows is the list of failures that actually happen to marketplaces, and the
specific control for each.

### 7.1 The failures and their controls

| Failure | Control |
|---|---|
| Two users book the last slot simultaneously | Row lock + capacity CHECK inside one `book_visit()` transaction; holds during checkout |
| User taps Pay twice / retries on flaky network | `idempotency_keys` table; same key ⇒ same order returned, never a second charge |
| Payment succeeds but app crashes before confirmation | Webhook is the only source of truth; order reconciles on next read; daily settlement reconciliation catches the rest |
| Webhook delivered twice / out of order | Idempotent handler keyed on gateway event id; state machine rejects illegal regressions |
| Notification service down | Transactional outbox — the domain write commits, the notification retries; never a dual-write |
| Vet's phone loses network mid-route | Partner app queues status writes offline; customer sees last-known state with an honest "updated 12 min ago" |
| Supabase degraded | App renders cached data read-only + banner; booking disabled with a clear message rather than failing silently |
| A bad release ships | Server-side **kill switches** per feature + `min_supported_version` force-upgrade gate + phased App Store release (1%→100%) |
| Bad migration | Expand/contract migrations only, never destructive in one step; PITR + a **restore drill you have actually run** |
| Money drifts | Double-entry ledger + nightly invariant job that alerts on any non-zero sum |
| Someone edits prod by hand | Ops console for every routine action; direct DB access is break-glass, logged, and reviewed |

### 7.2 Standards applied everywhere

- **Timeouts** on every network call (10 s connect, 30 s total); **retry** only idempotent ops, exponential
  backoff **with jitter**, max 3; **circuit breaker** per dependency.
- **Every mutating endpoint takes an idempotency key.** No exceptions.
- **Degradation matrix** written down: for each dependency, what the app does when it's down.
- **SLOs**: booking API p95 < 800 ms, availability 99.5%, crash-free sessions > 99.5%, push delivery < 30 s,
  webhook processing < 60 s. Alert on error budget burn, not on single errors.
- **Observability**: structured JSON logs with a request id propagated from the app (`X-Request-Id`), Sentry
  for crashes + backend errors, one dashboard with the five business golden signals (bookings/hr, payment
  success %, visits stuck, chat latency, sign-in success %).
- **Backups**: Supabase PITR on; weekly restore-to-staging drill; export of critical tables to object storage.
- **Game days** before launch: kill the gateway, kill Supabase, drop the network mid-booking. Fix what breaks.

---

## 8. Security

### 8.1 Threat model (asset → threat → control)

| Asset | Threat | Control |
|---|---|---|
| Customer home addresses | Enumeration/IDOR by another user | RLS default-deny; no sequential ids (UUIDv7); policy tests in CI |
| Medical records | Leak via unsigned storage URLs | Private buckets, short-lived signed URLs, path scoped to owner id |
| Phone numbers | Harvesting by vets / scraping | Masked calling only; never expose raw numbers in API responses |
| Money | Price tampering, replayed payments | Server-signed quotes, webhook-only confirmation, idempotency |
| Vet accounts | Takeover → fraudulent completions + payouts | OTP + device binding, payout changes require re-verification + 24h cool-off |
| OTP endpoint | SMS bombing (costs you real ₹) | Per-number/per-IP/per-device rate limits, exponential lockout, App Attest, captcha after N |
| Reviews | Fake/defamatory content | Only verified completed visits can review; moderation queue |
| Referrals/coupons | Self-referral farming | Device + phone + payment-instrument fingerprinting, reward only after a *paid completed* visit |
| The database | Service-role key leaking into a client | Service role exists **only** inside Edge Functions; CI grep fails the build if it appears in app or web bundles |

### 8.2 AuthN / AuthZ

- Sign in with Apple + phone OTP. Access token 15 min; refresh token rotated on every use with **reuse
  detection** (a replayed refresh revokes the whole family).
- Tokens in **Keychain** (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), never `UserDefaults`. ✅
- **Role matrix** enforced in RLS *and* in every Edge Function: `customer`, `vet`, `ops`, `admin`. Roles come
  from a server-set JWT claim, never from a client-writable table column.
- **Step-up auth** (Face ID / re-OTP) for: changing phone, adding a payout account, deleting the account,
  viewing full medical history.
- **RLS policy tests are CI-blocking**: a suite that authenticates as user A and asserts 0 rows for every one
  of user B's tables. This is the single highest-ROI security test you can write.

### 8.3 Data protection

TLS 1.2+ everywhere, ATS never disabled ✅ · field-level encryption (pgcrypto) for licence numbers and
clinical notes · PII scrubbing in logs (automatic redaction of phone/email/address patterns) · minimum-scope
data collection with a written justification per field · retention schedule per table · `privacySensitive()`
on medical views + blurred app-switcher snapshot · no PII in analytics events or URLs.

### 8.4 App hardening

No secrets in the bundle (config via xcconfig → Info.plist, anon key only, which is safe *because* RLS is
the real boundary) ✅ · certificate pinning at P1 with a backup pin and a remote kill switch · **App Attest**
on OTP and order endpoints · lightweight jailbreak signal used for risk-scoring, never as a hard block ·
disable pasteboard for OTP fields · no verbose logging in release builds.

### 8.5 Supply chain & AppSec program

Pin every SPM dependency to an exact version; review the dependency list monthly (target: < 8 direct deps) ·
Dependabot + `gitleaks` + CodeQL/semgrep in CI · SBOM per release · one external penetration test before
public launch (~₹60–150k; the cheapest insurance you will buy) · a `SECURITY.md` with a disclosure address ·
written incident-response runbook: detect → contain → assess → **notify the Data Protection Board and
affected users** → post-mortem.

### 8.6 Abuse & fraud

Rate limits at the edge (per IP, per user, per device) · velocity checks on bookings and cancellations ·
cash-payment fraud guard (OTP-verified start, vet-confirmed collection) · anomaly alerts for a vet completing
visits faster than physically possible · review brigading detection.

### 8.7 Compliance (India, 2026 — this is now date-bound)

**DPDP Act + DPDP Rules 2025** (notified 13 Nov 2025):
- Consent-manager provisions live **13 Nov 2026**; substantive obligations — notice, consent, security
  safeguards, breach reporting, data-principal rights — enforceable **13 May 2027**. Penalties up to ₹250 Cr.
- Build now, because retrofitting consent is brutal: itemised consent notice at signup (purpose-wise,
  withdrawable), consent dashboard (O5), data export (A7), deletion (A6), breach notification workflow,
  a named grievance officer, retention limits, and a processor agreement with every vendor.

**Sector & commerce:**
- **Veterinary practice** — only a VCI/State-Council-registered veterinarian may diagnose or prescribe.
  Para-vets are limited to assistive procedures; encode this as `vet_qualification` eligibility on services.
  No prescription-drug dispensing through the app without the applicable pharmacy licensing.
- **GST** registration + compliant invoices (G5), TDS/TCS where applicable on partner payouts.
- Clear **marketplace vs. provider** positioning in T&C, plus indemnity and professional-liability insurance.

**App Store:**
- **5.1.1(v) in-app account deletion** — the most common avoidable rejection. (A6)
- Real-world services are **outside In-App Purchase** — using Razorpay is correct and permitted; state this
  plainly in review notes.
- Accurate privacy nutrition labels; purpose strings for location, notifications, camera, photos; ATT only if
  you actually track; a **working demo account + a walkthrough video** in review notes (vet-side flows are
  invisible to a reviewer and cause rejections).

---

## 9. Design system & UX standards

**Components** (`Presentation/Shared/` — extend what exists ✅): Button (primary/secondary/destructive/loading),
Card, ListRow, StatusBadge, Timeline, PriceBreakdown, SlotPicker, PetAvatar, VetCard, ChatBubble, Toast,
Sheet, EmptyState, ErrorState, SkeletonLoader, Stepper, CouponField, RatingStars, SegmentedFilter,
BottomActionBar.

**Every screen defines five states**: loading (skeleton, never a spinner on a full screen) · empty (with a
next action) · error (cause + retry, never "Something went wrong") · offline (cached + banner) · success.

**Non-negotiable UX rules**
1. Price is always visible before commitment, itemised, with taxes in the total.
2. The active visit is reachable from anywhere in one tap.
3. Destructive actions confirm, state consequences in money and time ("Cancelling now refunds ₹450 of ₹599"),
   and are undoable for 10 seconds where possible.
4. Never a dead end: every empty/error state offers an action.
5. Latency is felt, not measured: optimistic UI for chat and cart, skeletons elsewhere.
6. Accessibility to AX5 Dynamic Type, full VoiceOver labels, `Reduce Motion` respected, 4.5:1 contrast.
7. Copy is plain and calm — people using this app are often worried about a sick animal.

---

## 10. Testing & quality

| Layer | What | Tool | Gate |
|---|---|---|---|
| Domain unit | Pricing, cancellation policy, eligibility, state machine | Swift Testing | 90% on `Domain/` ✅ (expand) |
| Property tests | Money never negative, ledger sums to zero, quote round-trips | Swift Testing | required |
| Repository contract | Mock and Supabase impls satisfy the same protocol suite | Swift Testing | required |
| **RLS policy tests** | User A can read 0 rows of user B, for every table | pgTAP / SQL in CI | **blocking** |
| DB function tests | `book_visit` under concurrent load, holds, capacity | pgTAP + `pgbench` | blocking |
| Snapshot | Design system, light+dark, AX5 type | swift-snapshot-testing | advisory |
| UI E2E | Sign in → book → pay (sandbox) → track → complete → review | XCUITest | blocking on main |
| Load | 100 concurrent bookings on one slot ⇒ exactly `capacity` succeed | k6 | pre-launch |
| Manual QA | Device matrix: SE (small), 15/16 (standard), Pro Max, iPad compat; iOS 17/18/26 | checklist | per release |
| Beta | Internal (2) → friends (10) → **pilot cluster real users (30+)** | TestFlight | per release |

---

## 11. Environments, CI/CD, release

**Three environments**: `dev` (mock repos, no backend ✅), `staging` (own Supabase project, gateway sandbox,
seeded data), `prod`. Config per-scheme via `.xcconfig` → `Info.plist` → `AppConfig` ✅ — never a compile-time
`if DEBUG` for environment selection.

**Pipeline** (extend `.github/workflows/ios.yml` ✅):
```
PR:    swiftlint · swiftformat --lint · build · unit tests · snapshot tests ·
       pgTAP RLS suite · gitleaks · CodeQL · danger (PR hygiene)
main:  above + XCUITest E2E + TestFlight upload (fastlane) + dSYM to Sentry
tag:   App Store submission build + release notes + git tag + migration apply to prod
```

Signing via App Store Connect API key in CI (never a developer's Mac as the release machine). Migrations
apply through CI with a review gate; every migration is expand/contract and reversible.

**Release discipline**: phased release (1/2/5/10/20/50/100%) · monitor crash-free + payment success during
rollout · kill switch first, hotfix second · `min_supported_version` raised only when you are prepared to
force users to update.

---

## 12. Launch checklist

**Legal/commercial**: entity + GST · bank + gateway KYC · T&C, privacy policy, refund policy live on web ·
vet contracts + indemnity insurance · grievance officer named · support phone/email live.

**Product**: A6 delete account · E3 price breakdown · F3/F4 reschedule+cancel with refunds · G4 refunds ·
G5 invoices · G7 vet payouts · I5 visit OTP · I6 consent · J2 photos in chat · J4 masked calling · C11/L8
emergency routing · M1/M2 support · O6 legal pages · O7 force-upgrade · ops console live.

**Technical**: RLS suite green · pen test findings closed · PITR + restore drill done · alerting to a phone
that is actually on · game day passed · Sentry + analytics verified in prod · App Store metadata, screenshots,
privacy labels, demo account, review-notes video.

**Operational**: 3+ verified vets per launch cluster · manual runbooks for the top 10 support scenarios ·
a WhatsApp escalation line for pilot users · one named human on call each day.

---

## 13. Ops runbooks (write these before launch, not after the first incident)

Vet no-show · customer no-show · payment taken but visit not created · refund request · medical complaint /
adverse outcome (escalate, document, never argue in chat) · vet suspension · data-deletion request ·
suspected breach · gateway outage · Supabase outage · stuck `en_route` visit · duplicate charge.

Each runbook: trigger → who acts → exact console steps → customer comms template → post-incident record.

---

## 14. Analytics & the numbers that matter

**North star**: *completed visits per active household per month* (measures repeat, not signup vanity).

**Funnel**: install → signup → address added → catalog viewed → slot selected → quote → payment started →
paid → visit completed → reviewed → **rebooked within 60 days** (the only metric that proves a business).

**Event taxonomy** (`object_action`, snake_case, no PII, versioned):
`app_opened · signup_completed · address_added · service_viewed · slot_selected · cart_updated ·
quote_created · checkout_started · payment_succeeded · payment_failed{reason} · visit_confirmed ·
visit_started · visit_completed · review_submitted · subscription_started · subscription_cancelled{reason} ·
support_ticket_created · error_shown{code}`

**Unit economics per visit** — track from day one:
```
Revenue        ₹699
− Vet payout   ₹350
− Travel       ₹45         (this is the number circuits are designed to crush)
− Gateway      ₹14   (2%)
− SMS/comms    ₹3
− Support      ₹20  (amortised)
= Contribution ₹267        target ≥ ₹200 and CAC payback < 3 visits
```

**Cohort retention** by cluster and by acquisition source — a circuit is only viable at ≥60% 90-day retention
in its cluster.

---

## 15. Honest cost model

v1's "₹10,000 to the App Store" is true only for a demo nobody uses. Real monthly run-rate:

| Item | Pre-launch | ~100 visits/mo | ~1,000 visits/mo |
|---|---|---|---|
| Apple Developer | ₹8,500/yr | ₹8,500/yr | ₹8,500/yr |
| Supabase | Free | Free–$25 | $25–100 |
| SMS/OTP + transactional | ₹0 | ₹500–1,500 | ₹5,000–12,000 |
| WhatsApp templates | ₹0 | ₹300 | ₹3,000 |
| Masked calling (Exotel) | ₹0 | ₹1,500 | ₹8,000 |
| Sentry + PostHog | Free | Free | $0–50 |
| Maps/routing | Free (MapKit) | ₹0–500 | ₹2,000–6,000 |
| Domain + web hosting | ₹800/yr | ₹800/yr | ₹800/yr |
| Payment gateway | — | ~2% of GMV | ~2% of GMV |
| Penetration test (one-off) | ₹60–150k | — | — |
| Liability insurance | ₹15–40k/yr | ₹15–40k/yr | scales |
| **Realistic monthly** | **~₹1–2k** | **~₹5–8k** | **~₹35–60k** |

Budget **₹1.5–2.5 lakh for a defensible launch** (insurance + pen test + first months), not ₹10,000. Still
small — but plan for it rather than discovering it.

---

## 16. Roadmap with exit criteria

| Phase | Weeks | Build | Exit criteria (do not pass without these) |
|---|---|---|---|
| **0 · Manual pilot** | 1–2 | No code. Run 20 real visits via WhatsApp + spreadsheet in ONE cluster. | 20 visits done; ≥8 repeat; you can state the price list and cancellation policy from memory |
| **1 · Foundations** | 3–5 | Catalog+variants, addresses, capacity slots, quote engine, cart, `book_visit()` txn, idempotency, RLS suite, ops console v1 | 100 concurrent bookings on one slot ⇒ exactly capacity succeed; RLS tests green |
| **2 · Money & lifecycle** | 6–8 | Checkout, webhook ✅, refunds, invoices, cancel/reschedule policy, subscriptions w/ mandate, payouts | A full cancel→refund→invoice cycle runs end-to-end in staging with real gateway sandbox |
| **3 · The visit** | 9–10 | 8-state machine, visit OTP, consent, checklist→record, vaccinations + reminders, chat w/ photos, masked calling, partner PWA | A real vet completes a real visit entirely in-app with zero manual intervention |
| **4 · Trust & compliance** | 11–12 | Delete account, consent dashboard, export, support/disputes, emergency routing, force-upgrade, legal pages, accessibility pass | Pen test findings closed; restore drill done; App Store pre-flight clean |
| **5 · Launch** | 13–14 | TestFlight with pilot cluster → phased App Store release | 30 pilot users; crash-free > 99.5%; payment success > 95% |
| **6 · Grow** | 15+ | Live Activity, live tracking, referrals, coupons, lifecycle pushes, 2nd cluster | 60% 90-day retention in cluster 1 **before** opening cluster 2 |
| **7 · Scale** | later | Android, elder-care vertical, packages, lab tests, widgets | Cluster 1 contribution-positive |

---

## 17. Risk register

| Risk | Impact | Mitigation |
|---|---|---|
| Supply (vets) doesn't show up | Fatal | Sign 3 vets per cluster before writing the booking flow; guarantee minimum earnings for the first month |
| Density never materialises | Fatal | Do not open cluster 2 until cluster 1 hits the retention gate |
| A medical adverse event | Existential | Insurance, consent, documented records, immediate escalation runbook, never argue in chat |
| Well-funded competitor enters your cluster | High | Own the RWA relationship; subscriptions create switching cost |
| Regulatory (prescriptions, telemedicine) | High | VCI-registered vets only; no drug dispensing until licensed |
| Two-person burnout | High | The deferral list in §18 is the real mitigation — respect it |
| Data breach | High | §8 in full; pen test; the smallest data footprint that works |

---

## 18. Explicitly NOT building (and why)

Android (until iOS repeat purchase is proven) · native partner app (PWA is enough) · in-app video consult
(phone call works; video is a product in itself) · AI triage (V3; liability and accuracy risk without a
clinician in the loop) · e-pharmacy/product commerce (licensing + inventory + a different business) ·
custom backend (Supabase is not the constraint; your time is) · microservices (you have two people) ·
GraphQL (REST + RLS is simpler here) · own maps/routing stack · real-time dispatch/surge (it is the opposite
of the circuit thesis) · Apple Watch app · loyalty gamification beyond points · multi-vertical marketing
(build the abstraction, sell one thing).

---

## Appendix A — API surface (trusted endpoints; everything else is RLS-direct)

```
POST   /v1/quotes                      body: address, items[], pets[], slot → signed quote + breakdown
POST   /v1/orders                      body: quote_id, payment_method, idempotency_key
POST   /v1/orders/:id/cancel           → refund computed server-side from policy
POST   /v1/orders/:id/reschedule       body: new_slot_id
POST   /v1/slots/:id/hold              → hold_id, expires_at (10 min)
PATCH  /v1/visits/:id/status           role-gated state machine (partner/ops)
POST   /v1/visits/:id/start            body: otp
POST   /v1/visits/:id/complete         body: checklist, notes, prescription?
POST   /v1/payments/webhook            gateway → signature-verified, idempotent  ✅
POST   /v1/refunds                     ops only
POST   /v1/calls/connect               masked call bridge
POST   /v1/account/delete              soft-delete + schedule purge
GET    /v1/account/export              async job → signed download
GET    /v1/app/config                  min_supported_version, flags, maintenance
POST   /v1/support/tickets
```
Conventions: `/v1` ✅ · `Idempotency-Key` header required on every POST · `X-Request-Id` propagated ·
errors as `{code, message, details, request_id}` with stable machine-readable `code`s the app maps to copy.

## Appendix B — Visit state machine

| From | To | Actor | Side effects |
|---|---|---|---|
| requested | confirmed | system/ops | slot committed, push, calendar invite |
| confirmed | assigned | system | vet + circuit_stop assigned, push |
| assigned | en_route | vet | Live Activity starts, ETA stream, push |
| en_route | arrived | vet | OTP prompt shown to customer |
| arrived | in_progress | vet (OTP ok) | timer starts |
| in_progress | completed | vet | record saved, invoice, payment capture (if postpaid), review prompt, loyalty points |
| requested/confirmed/assigned | cancelled_by_user | customer | refund per policy, slot released, re-optimise route |
| any pre-arrival | cancelled_by_vet | vet/ops | full refund + goodwill credit, re-offer alternate slot |
| arrived | no_show_user | vet + ops confirm | cancellation fee per policy |
| completed | disputed | customer (≤7d) | ticket, payout hold |
| disputed | resolved | ops | refund/credit or dismissal, audited |

Illegal transitions are rejected by a DB trigger and logged to `audit_log`.

## Appendix C — Pricing formula (server-side, single source of truth)

```
base            = variant.price
multi_pet       = Σ additional_pets × variant.additional_pet_price
addons          = Σ addon.price
travel_fee      = cluster.travel_fee  (0 if slot is on an existing circuit run — the density dividend)
peak            = base × cluster.peak_multiplier(slot)      // default 1.0
subtotal        = base + multi_pet + addons + travel_fee + peak_delta
discount        = min(coupon_rule(subtotal), coupon.max_discount)
entitlement     = subscription credit applied (may zero the base)
wallet          = min(wallet.balance, subtotal − discount − entitlement)
taxable         = subtotal − discount − entitlement
gst             = round(taxable × rate)
total           = taxable + gst − wallet
```
Returned as an itemised array, displayed verbatim in the app, stored on the order for the invoice. The client
never computes a rupee.

## Appendix D — Security sketches

```sql
-- Default deny, then grant narrowly. Every table. No exceptions.
alter table visits enable row level security;
create policy visits_select_own on visits for select
  using (user_id = auth.uid()
      or vet_id = (select id from vets where auth_id = auth.uid())
      or auth.jwt() ->> 'role' in ('ops','admin'));
-- Customers may never write status; only trusted functions can.
revoke update (status) on visits from authenticated;

-- Booking: atomic, capacity-safe, idempotent.
create function book_visit(p_quote_id uuid, p_slot_id uuid, p_key text)
returns visits language plpgsql security definer as $fn$
declare v visits; begin
  perform 1 from idempotency_keys where key = p_key;
  if found then return (select * from visits where idempotency_key = p_key); end if;
  perform 1 from slots where id = p_slot_id for update;              -- serialise
  if (select booked_count >= capacity from slots where id = p_slot_id) then
    raise exception 'SLOT_FULL' using errcode = 'P0001';
  end if;
  -- validate quote signature + TTL, insert order/items/visit, bump booked_count,
  -- record idempotency key, enqueue outbox notification — all in this transaction.
  return v;
end $fn$;
```

## Appendix E — iOS layout v2

```
VetCircuit/
├── App/                     entry, DI, Router, SessionStore, AppDelegate      ✅
├── Packages/
│   ├── VCDomain/            models, use cases, policies (pure Swift)          ✅→move
│   ├── VCData/              repositories, APIClient, Outbox, cache, Keychain  ✅→move
│   ├── VCDesignSystem/      Theme, components, Mascot, motion                 ✅→move
│   └── VCPlatform/          Push, Analytics, Flags, Location, Payments, Log   🔨
├── Features/
│   ├── Onboarding/  Home/  Catalog/  Booking/  Cart/  Checkout/
│   ├── Visits/  Tracking/  Chat/  Pets/  Records/
│   ├── Account/  Subscription/  Wallet/  Support/  Referral/
└── Resources/               Assets, Info.plist, Localizable, legal            ✅
```

## Appendix F — What exists in this repo today

**Built** ✅: Clean-architecture skeleton (Domain/Data/Presentation) · mock + Supabase repositories ·
Sign in with Apple + OTP scaffolding · circuits list · single-visit booking · per-visit chat · reviews ·
visit history · multi-pet · subscriptions (checkout handoff) · loyalty · referrals · triage stub ·
live-tracking view · Postgres schema with RLS · signature-verified payment webhook · partner + admin Next.js
shells · XcodeGen + GitHub Actions CI · design system (Theme/Mascot/motion) · Keychain token storage.

**The gap to deployable**, in priority order:
1. Catalog + variants + add-ons (D) — everything downstream depends on it
2. Addresses + capacity slots + holds (A8, F2, E7)
3. Server-authoritative quote + cart + price breakdown (E)
4. `book_visit()` transaction + idempotency (7.1)
5. Cancel/reschedule policy + refunds + invoices (F3–F4, G4–G5)
6. 8-state machine + visit OTP + consent + record (I)
7. Delete account, consent dashboard, export (A6, A7, O5) — App Store + DPDP blockers
8. Ops console for verification, refunds, disputes, flags (Q)
9. Masked calling + chat photos (J2, J4)
10. Vet payouts (G7) — without it, supply churns

---

*Plan v2.0 · maintained alongside the code. When a section here and the code disagree, one of them is a bug —
fix the code or fix the plan, in the same pull request.*
