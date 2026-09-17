# Feature status — what is actually verified, and how

99 features were marked done. This file says, for each one, what evidence
exists that it works. It is deliberately not a tick-list: the whole reason
this document exists is that a tick-list is what produced twelve features
that were structurally present and functionally inert while CI reported green.

## The four levels of evidence

| | Level | What it means |
|---|---|---|
| 🟢 | **Driven** | An XCUITest launches the real app and walks a customer through it. The screen renders, the control is *hittable*, and tapping it once produces the next screen. |
| 🟡 | **Logic tested** | The domain logic has unit tests (406 of them, all passing) and the screen exists and is reachable, but no test drives the whole path end-to-end. |
| 🟠 | **Built, unproven** | The code exists and is wired into `DependencyContainer`, but nothing tests it at either level. It may work. Nobody has checked. |
| ⚪ | **Mock-bound** | Implemented against a mock repository. Cannot be verified here at all — it needs a real payment gateway, push service, file storage or Apple entitlement. The Supabase implementations exist but have never been run. |

`isHittable` is the assertion that matters at the 🟢 level. The controls that
had to be tapped three or four times existed and were visible; they simply had
no touch region under what was painted. `exists` was true for all of them.

---

## Account & Profile

| ID | Feature | Status | Evidence |
|---|---|---|---|
| A1 | Sign in with Apple | — | **Excluded at your request.** |
| A5 | Edit profile | 🟢 | `testAccountAndMoneyScreensAreAllReachable` opens it from Profile in one tap |
| A6 | Delete account + data | 🟡 | `ManageAccountDeletionUseCase` suite; 30-day window logic tested |
| A7 | Export my data | 🟡 | `ExportDataUseCase` suite; JSON and PDF both real, PDF output asserted by `PDF rendering` suite |
| A8 | Multiple addresses + geofence | 🟢 | Driven; `ManageAddressesUseCase` suite covers the served/unserved split. Demo data now includes an address deliberately outside coverage |
| A9 | Household invite | 🟢 | Screen driven; `ManageHouseholdUseCase` suite |
| A10 | Face ID app lock | 🟠 | Toggle renders on Profile. `LAContext` cannot be exercised in CI |
| A11 | Blocked/deactivated handling | 🟡 | `A11 blocked/deactivated account gate` suite, including a test that fails loudly if a new status is added without deciding whether it locks the user out |

## Pets & Records

| ID | Feature | Status | Evidence |
|---|---|---|---|
| B1 | Multiple pets, add/edit/archive | 🟢 | Pet card driven from Profile; `ManagePetsUseCase` + archiving suites. Demo account now has three pets |
| B2 | Pet detail screen | 🟢 | `testOpeningAPetRevealsItsRecordScreens` |
| B3 | Weight & vitals chart | 🟢 | Section asserted present; `ManagePetWeightsUseCase` history + vitals suites. 18 months of weigh-ins seeded so the chart has a trend |
| B4 | Vaccination record + due reminders | 🟢 | Section asserted; `ManageVaccinationsUseCase` + `VaccinationPolicy` suites. One seeded vaccination is deliberately overdue |
| B5 | Prescription history | 🟢 | Section asserted; `ManagePrescriptionsUseCase` suite |
| B6 | Document vault | 🟡 | `ManagePetDocumentsUseCase` suite; four documents seeded. Storage is ⚪ (`mock-storage://` URLs) |
| B7 | Shareable health summary PDF | 🟡 | `GeneratePetHealthSummaryUseCase` suite covers content; `PDF rendering` suite asserts the bytes really are a PDF, including for a pet with no history |
| B8 | Deceased/rehomed handling | 🟡 | `ManagePetsUseCase archiving (B8)` suite — soft-delete only, history preserved |

## Discovery

| ID | Feature | Status | Evidence |
|---|---|---|---|
| C1 | Address-first discovery | 🟢 | Book tab drives it |
| C2 | Circuit list (slot/price/rating) | 🟢 | `testBookTabShowsCircuitsWithSlotPriceAndRating` asserts the row carries all three |
| C3 | Filters | 🟢 | Driven; `CircuitFilter` suite |
| C4 | Sort options | 🟡 | `CircuitSortOption` suite |
| C5 | Vet detail screen | 🟡 | `GetVetProfileUseCase` suite; reviews seeded per vet |
| C6 | Service detail screen | 🟢 | `testCatalogOpensAServiceWithVariantsAndAddons` |
| C7 | Coverage map | 🟠 | Screen exists. MapKit rendering is not assertable in CI |
| C8 | Search | 🟡 | `SearchUseCase` suite |
| C9 | Recently viewed / rebook | 🟡 | `C9 recently viewed` suite — ordering, de-duplication on revisit, the cap, and dropping ids whose circuit has left the platform |
| C10 | Waitlist for uncovered areas | 🟡 | `JoinWaitlistUseCase` suite |
| C11 | Emergency path | 🟢 | Asserted present without scrolling, and the screen opens |

## Catalog

| ID | Feature | Status | Evidence |
|---|---|---|---|
| D1 | Catalog by category | 🟢 | Driven; `GetCatalogUseCase` suite |
| D2 | Service variants | 🟢 | Driven, **plus a regression lock**: no service may advertise "from ₹0" again. `D2 minimum pet age eligibility` suite |
| D3 | Add-ons | 🟡 | `D3 add-on eligibility` + `ManageCartUseCase — D3/D6` suites |
| D4 | Packages with redemption tracking | 🟢 | Driven, asserting each card lists its contents; `BuyPackageUseCase` + `PackageRedemptionPolicy` suites |
| D5 | Per-vet pricing overrides | 🟡 | `PricingEngine vet override (D5)` + `MockQuoteRepository override resolution (D5)` suites |
| D6 | Multi-pet in one visit | 🟡 | `D6 multi-pet in one visit` suite covers the app side; `0063_visit_additional_pets.sql` adds the column, the `book_visit()` parameter and a trigger rejecting a duplicated or someone-else's pet. The SQL has never been executed — see the caveats |

## Cart & Checkout

| ID | Feature | Status | Evidence |
|---|---|---|---|
| E1 | Cart | 🟢 | Driven, **plus two regression locks**: the cart button must be hittable, and the cart must never open blank |
| E2 | Cart persistence | 🟡 | `ManageCartUseCase` suite |
| E3 | Transparent price breakdown | 🟡 | `PricingEngine` suites (coupon/wallet/entitlement interplay) |
| E4 | Coupons | 🟡 | `ApplyCouponUseCase` + `N2 coupon campaign discounts` suites. **Note:** `usageLimit`/`perUserLimit` are not enforced client-side and must not be — that belongs in `validate_coupon()` server-side |
| E5 | Wallet/loyalty redemption | 🟡 | `LoyaltyRedemptionPolicy` + `PricingEngine coupon + wallet interplay` suites |
| E6 | Server-signed quote gating | 🟡 | `BookingCheckoutUseCase` suite — including two tests that an expired quote books nothing |
| E7 | Slot hold during checkout | 🟢 | Driven in the slot-picker test; `HoldSlotUseCase` suite |
| E8 | Pay-after-visit choice | 🟡 | `PaymentRetryPolicy + pay-after-visit` + `MarkPayAfterVisitCollectedUseCase` suites. The one payment path that works end to end against Postgres, because it moves no money |
| E9 | Saved payment methods | 🟢 | Screen driven; `ManageSavedPaymentMethodsUseCase (E9)` suite |
| E11 | Tip the vet | 🟡 | `TipUseCase` suite |

## Scheduling

| ID | Feature | Status | Evidence |
|---|---|---|---|
| F1 | Slot picker | 🟢 | `testSlotPickerOffersTappableTimesAndTheCTAGatesOnSelection` |
| F2 | Capacity per slot | 🟢 | Driven (slots carry remaining capacity); `BookVisitUseCase` suite covers oversell |
| F3 | Reschedule | 🟡 | `RescheduleVisitUseCase` + `RespondToRescheduleProposalUseCase (F6)` suites |
| F4 | Cancel with policy | 🟢 | **The bug you reported.** Driven, asserting the refund consequence is stated before confirming; `CancelVisitUseCase` + `CancellationPolicy` + `NoShowPolicy (F7)` suites |
| F8 | Buffer/travel-time aware slots | 🟡 | `SlotBufferPolicy` suite |
| F9 | Vet blackout/leave | 🟡 | `ManageVetBlackoutsUseCase` + `GetCircuitsUseCase blackout filtering` suites |

## Payments

| ID | Feature | Status | Evidence |
|---|---|---|---|
| G1 | Hosted checkout, no raw card data | ⚪ | Architecturally correct — the app only ever holds a URL. Unverifiable without a gateway, and `SupabasePaymentRepository` now refuses rather than handing back a fake one |
| G2 | Webhook-only confirmation | ⚪ | Same. The webhook handler is server-side and does not exist here |
| G3 | Payment retry | 🟡 | `PaymentRetryPolicy` + `RetryPaymentUseCase` suites |
| G4 | Refunds | 🟡 | `G4 refunds` suite — issuance, per-visit scoping, and that an ops-initiated refund stays attributable while a policy-driven one does not |
| G5 | GST invoice PDF | 🟡 | `G5 GST invoice` suite covers itemisation and inclusive totals; `InvoicePDFRenderer` renders and the screen previews it via PDFKit |
| G6 | Wallet ledger | 🟢 | Driven, asserting it shows a *ledger* and not just a balance; `GetWalletBalanceUseCase` suite |

## Subscriptions

| ID | Feature | Status | Evidence |
|---|---|---|---|
| H1 | Plan catalog | 🟡 | `PlanCatalogEntry` suite |
| H3 | Manage (upgrade/downgrade/pause/cancel) | 🟡 | `ManageSubscriptionUseCase` + `SubscriptionManagementPolicy` suites |
| H4 | Renewal reminders | 🟡 | `RenewalReminderPolicy` + `RenewalReminderUseCase` + `DunningPolicy` suites |
| H6 | Subscription credit entitlements | 🟡 | `EntitlementPolicy` + `PricingEngine entitlement credit` suites |
| H7 | Corporate/RWA seats | 🟡 | `ManageCorporateSeatsUseCase` suite |

## Live Visit

| ID | Feature | Status | Evidence |
|---|---|---|---|
| I1 | "Happening now" card | 🟢 | Driven, **plus a lock that the Visits tab is not empty** now the seed exists. One seeded visit is `enRoute` |
| I2 | Status timeline | 🟢 | Driven from visit detail; `MockVisitRepository status history` + `Visit.legalTransitions` suites |
| I3 | Live Activity / Dynamic Island | ⚪ | ActivityKit cannot run in this CI |
| I4 | Live map + ETA | 🟠 | `TrackVetUseCase` suite covers ETA. Map rendering not assertable |
| I5 | Start-of-visit OTP | 🟡 | `StartVisitUseCase` suite |
| I6 | Digital consent waiver | 🟡 | `ManageConsentUseCase` suite |
| I7 | Visit checklist | 🟡 | `GetVisitChecklistUseCase (I7)` suite |

## Communication

| ID | Feature | Status | Evidence |
|---|---|---|---|
| J1 | Per-visit chat | 🟡 | `SendChatMessageUseCase` suite; `SupabaseChatRepository` persists messages and read receipts, with a named Realtime gap |
| J2 | Chat photo attachments | 🟡 | `SendChatMessageUseCase photo attachments` suite. Against Postgres this refuses rather than posting an empty message — it needs a storage bucket and an `attachment_url` column |
| J3 | Read receipts / unread badge | 🟡 | `ChatUnreadPolicy` suite |
| J5 | Auto-close chat + escalation | 🟡 | `ChatPolicy` suite |
| J7 | Notification centre + preferences | 🟢 | Both screens driven; `ManageNotificationPreferencesUseCase` suite. Centre now seeded with five notifications, two unread |

## Post-Visit

| ID | Feature | Status | Evidence |
|---|---|---|---|
| K1 | Structured visit record | 🟡 | `Visit.hasStructuredRecord (K1)` suite. Eleven seeded visits now carry real diagnosis/procedure/medication records |
| K2 | Prescription PDF | 🟡 | `PDF rendering` suite asserts the document renders and writes a shareable `.pdf` file |
| K3 | Medication reminders | 🟡 | `ManageMedicationRemindersUseCase` + `MedicationReminder` suites |
| K4 | Vaccination certificate PDF | 🟡 | `PDF rendering` suite, including a vaccination with no given-date |
| K5 | 1-tap follow-up booking | 🟡 | `FollowUpBookingPolicy (K5)` suite |
| K6 | Lab test ordering | 🟡 | `GetLabTestReportsUseCase` suite; two reports seeded |
| K7 | Rate & review | 🟡 | `SubmitReviewUseCase` + moderation integration suites |
| K8 | Report a problem → dispute | 🟡 | `K8 payment disputes` suite |

## Trust & Safety

| ID | Feature | Status | Evidence |
|---|---|---|---|
| L3 | Verified badge | 🟢 | Asserted in the circuit row label; `GetCircuitsUseCase verification filtering` suite |
| L4 | SOS + share-visit link | 🟡 | `FileIncidentReportUseCase / SOSUseCase` suite |
| L6 | Review moderation | 🟡 | `ReviewModerationPolicy` suite |
| L8 | "Not an emergency" disclaimer | 🟢 | Asserted present in the booking flow *and* on the emergency screen |

## Support

| ID | Feature | Status | Evidence |
|---|---|---|---|
| M1 | Help centre | 🟢 | Driven. Eleven real articles seeded |
| M2 | Contact support w/ ticket | 🟢 | Both "Contact support" and "My tickets" driven; `ContactSupportUseCase` suite |
| M4 | Refund/credit from ticket | 🟡 | `IssueSupportRefundUseCase (M4)` suite |
| M5 | Call support (hours gated) | 🟡 | `BusinessHoursPolicy and ContactSupportByCallUseCase (M5)` suite |

## Growth

| ID | Feature | Status | Evidence |
|---|---|---|---|
| N1 | Referral + fraud guard | 🟢 | Screen driven; `SendReferralUseCase` + fraud-guard suites |
| N2 | Coupon campaigns | 🟡 | `N2 coupon campaign discounts` suite |
| N3 | Lifecycle pushes | 🟡 | `DrainLifecycleNotificationQueueUseCase` + `NotificationDeliveryPolicy` suites. Actual delivery is ⚪ |
| N4 | Loyalty points/tiers | 🟡 | `LoyaltyAccount.Tier.forPoints (N4)` suite. Demo account seeded at silver |
| N5 | In-app rating prompt | 🟠 | `SKStoreReviewController` cannot be exercised in CI |
| N7 | Deep links | 🟡 | `DeepLinkParser` + `Router.handle` suites, including nested-screen routing |

## Settings

| ID | Feature | Status | Evidence |
|---|---|---|---|
| O1 | Notification preferences | 🟢 | Driven; `ManageNotificationPreferencesUseCase` suite |
| O3 | Appearance | 🟢 | `testBothAppearancesRenderWithoutLosingContent` |
| O5 | Consent dashboard | 🟢 | Driven; `ManageConsentUseCase` suite |
| O7 | Force-upgrade gate | 🟡 | `CheckAppConfigUseCase` + `RemoteAppConfig version comparison` suites |
| O8 | Maintenance mode | 🟡 | `CheckAppConfigUseCase` suite (which I had missed) plus `O8 maintenance mode`, including that maintenance takes precedence over a force-upgrade — sending someone to the App Store during an outage updates an app that still won't work |

---

## Tally

| Status | Count |
|---|---|
| 🟢 Driven through the running app | 34 |
| 🟡 Domain logic unit-tested, screen reachable | 57 |
| 🟠 Built, nothing tests it | 4 |
| ⚪ Mock-bound, unverifiable without a real backend | 3 |
| — Excluded at your request | 1 |

**91 of 99 have real evidence behind them. 4 have none. 3 cannot be tested in
this environment at any level, and saying otherwise would be a lie.**

The 🟠 four, and why each is genuinely stuck rather than merely neglected:

- **A10 Face ID lock** — `LAContext` has no biometric hardware to talk to in a
  simulator, and no way to simulate a successful or failed match.
- **C7 coverage map** and **I4 live map rendering** — MapKit draws into a
  surface XCUITest cannot introspect. The *logic* behind I4 is covered by the
  `TrackVetUseCase` suite; it is the rendering that is unassertable.
- **N5 rating prompt** — `SKStoreReviewController` deliberately does nothing
  in a test environment, by Apple's design.

Each needs a person holding a device. None can be closed from here.

The ⚪ three: G1 hosted checkout, G2 webhook-only confirmation, I3 Live Activity.
All three need something this environment cannot provide — a payment gateway, a
server receiving webhooks, and ActivityKit on a real device.

One more correction while I am counting honestly: O8 was listed as untested
because I grepped for the tag "O8" and found none in the test target. It had a
`CheckAppConfigUseCase` suite the whole time. The 🟠 column was built by
tag-grepping, which is the same weak evidence this document exists to replace;
the four that remain have been checked by hand.

## The honest caveats

1. **Everything runs on mock repositories, and the swap is now a config
   change.** Supply `SUPABASE_URL` and `SUPABASE_ANON_KEY` and 51 repositories
   resolve to Postgres. Five still have no conformer —
   `LiveTrackingRepository`, `TriageRepository` and three deliberately
   device-local ones. Two more are partial and say so on the container:
   chat persists messages and read receipts but has no Realtime channel, so a
   thread refreshes on load rather than pushing, and photo attachments refuse
   rather than post an empty message; payments does status, lookup and the
   entire pay-after-visit path, but refuses the four hosted-checkout methods,
   because creating a gateway session needs a server-side function this
   repository does not contain. That refusal is deliberate — the mock returns
   a fake checkout URL and reports success, so a credentialed build left on it
   would show a booking as paid when no money moved. The schema is proven to
   build (61 migrations, applied in CI), but the app has never completed a
   round trip to a live instance.
2. **A correction.** An earlier version of this file said no PDF was rendered
   anywhere. That was wrong. B7, G5, K2, K4 and A7 all render through
   `UIGraphicsPDFRenderer` — a system framework, no service or account needed
   — and all are wired to share sheets. I had grepped for one type name, found
   no call sites, and concluded a feature was missing rather than checking:
   the same "read the source and draw a conclusion" mistake that produced the
   twelve inert features in the first place. There is now a `PDF rendering`
   suite that asserts the output actually begins with `%PDF-`, because that is
   the difference between a renderer that works and one that believes it does.
3. **D6 is written end to end, and proven only on the app side.** A booking
   carries every pet on the cart line, the mock records them, and
   `0063_visit_additional_pets.sql` adds the column, the `book_visit()`
   parameter and a trigger that rejects a pet listed twice or a pet belonging
   to someone else — the array cannot carry a foreign key, so that ownership
   check is the only thing standing between it and a hole through `pets`' RLS.
   No migration in this repository has ever been run, this one included. It is
   reviewed code, not verified behaviour.
4. **The screenshots exist but I have not seen them.** CI attaches one per
   walkthrough stop; this environment's egress blocks the artifact host. Every
   claim here about layout rests on the tests and on contrast arithmetic, not
   on having looked at the app.
