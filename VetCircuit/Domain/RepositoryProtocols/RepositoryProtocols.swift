import Foundation

// MARK: - Repository protocols (Domain layer depends only on abstractions)

protocol AuthRepository: Sendable {
    func currentUser() async -> User?
    func signInWithApple(identityToken: String, nonce: String) async throws -> User
    func requestOTP(phone: String) async throws
    func verifyOTP(phone: String, code: String) async throws -> User
    func signOut() async throws
}

protocol CircuitRepository: Sendable {
    func listCircuits(area: String?) async throws -> [Circuit]
    func circuit(id: UUID) async throws -> Circuit
}

protocol VisitRepository: Sendable {
    /// `idempotencyKey` (plan §7.1: "every mutating endpoint takes an
    /// idempotency key, no exceptions") makes a retried booking — a double
    /// tap, a retry after a flaky network response — return the *same*
    /// visit instead of creating a duplicate.
    func createVisit(petId: UUID, vetId: UUID, circuitId: UUID, slot: ScheduleSlot, idempotencyKey: String) async throws -> Visit
    func listVisits(userId: UUID) async throws -> [Visit]
    func visit(id: UUID) async throws -> Visit
    func updateStatus(visitId: UUID, status: Visit.VisitStatus) async throws -> Visit
    func cancelVisit(visitId: UUID) async throws
    /// F3: reschedule to a new slot — the visit keeps its identity (history,
    /// chat thread) rather than being cancelled and rebooked.
    func rescheduleVisit(visitId: UUID, newSlot: ScheduleSlot) async throws -> Visit
    /// The amount actually paid for this visit, needed to compute a refund.
    func paidAmountMinorUnits(visitId: UUID) async throws -> Int
    /// I2: the timestamped status timeline, oldest first — server-recorded
    /// (0046_visit_status_events.sql), since the client never knew *when*
    /// a past transition happened, only what the current status is.
    func statusHistory(visitId: UUID) async throws -> [VisitStatusEvent]
}

protocol AccountRepository: Sendable {
    /// A6: soft-delete with a 30-day window — financial records are
    /// retained per statute (see plan §A6) rather than hard-deleted.
    func requestDeletion(userId: UUID) async throws -> DeletionRequest
    func cancelDeletionRequest(userId: UUID) async throws
    func pendingDeletionRequest(userId: UUID) async throws -> DeletionRequest?
    /// A7: assembles the customer's full data export.
    func exportData(userId: UUID) async throws -> DataExport
}

protocol VisitOTPRepository: Sendable {
    /// Generates (or returns the existing, unexpired) start-of-visit OTP —
    /// called once a visit reaches `arrived`.
    func generateOTP(visitId: UUID) async throws -> VisitOTP
    /// Verifies the code the customer read aloud; on success the visit
    /// transitions to `in_progress` server-side.
    func verifyOTP(visitId: UUID, code: String) async throws -> Bool
}

protocol ConsentRepository: Sendable {
    func activeConsents(userId: UUID) async throws -> [ConsentRecord]
    func grant(userId: UUID, purpose: String, version: String) async throws -> ConsentRecord
    func withdraw(userId: UUID, purpose: String) async throws
}

protocol RefundRepository: Sendable {
    /// G4: refunds tracked to the gateway. Ops-initiated refunds pass a
    /// non-nil `initiatedByOpsUserId`; a policy-driven cancellation refund
    /// passes nil (automatic).
    func issueRefund(visitId: UUID, paymentId: UUID, amountMinorUnits: Int, reason: String, initiatedByOpsUserId: UUID?) async throws -> Refund
    func refunds(visitId: UUID) async throws -> [Refund]
}

protocol PaymentDisputeRepository: Sendable {
    /// G9: disputes tied to a single visit, newest first — a visit almost
    /// never has more than one, but this stays a list for the same reason
    /// `RefundRepository.refunds` does.
    func disputes(visitId: UUID) async throws -> [PaymentDispute]
}

/// I7: read-only from the customer side — see the type comment on
/// `VisitChecklistItem`.
protocol VisitChecklistRepository: Sendable {
    func items(visitId: UUID) async throws -> [VisitChecklistItem]
}

/// I8: guards `SendPostVisitSummaryUseCase` against re-sending the same
/// visit's push every time the app notices it's completed. Honest gap:
/// this is a device-local "have I sent this" flag, not a server-side one —
/// a real deployment would want the completion trigger (and its
/// idempotency) to live server-side, next to whatever marks a visit
/// `completed` in the first place, not client-detected on next launch.
protocol PostVisitSummaryRepository: Sendable {
    func hasSent(visitId: UUID) async throws -> Bool
    func markSent(visitId: UUID) async throws
}

protocol InvoiceRepository: Sendable {
    /// G5: GST-compliant invoice per order, generated once a visit completes.
    func invoice(visitId: UUID) async throws -> Invoice?
}

protocol SubscriptionRepository: Sendable {
    func currentSubscription(userId: UUID) async throws -> Subscription?
    func subscribe(userId: UUID, plan: Subscription.PlanType) async throws -> Subscription
    func cancel(subscriptionId: UUID) async throws

    // H3: manage — upgrade/downgrade/pause/resume. Each returns the updated
    // row rather than Void so the UI can show the new renewal date/plan
    // without a second round trip.
    func changePlan(subscriptionId: UUID, to plan: Subscription.PlanType) async throws -> Subscription
    func pause(subscriptionId: UUID) async throws -> Subscription
    func resume(subscriptionId: UUID) async throws -> Subscription

    // H5: dunning state, read/written by the retry-ladder job (plan §6.5)
    // and surfaced read-only to the customer app ("payment failed, retrying...").
    func dunningState(subscriptionId: UUID) async throws -> DunningState?
    func recordDunningState(_ state: DunningState) async throws
}

protocol PaymentRepository: Sendable {
    func createCheckout(forVisit visitId: UUID, amountMinorUnits: Int) async throws -> URL
    func createCheckout(forSubscription plan: Subscription.PlanType) async throws -> URL
    func paymentStatus(paymentId: UUID) async throws -> Payment.Status
    /// E11: tagged distinctly from a regular visit charge (payments.kind =
    /// 'tip') so the server can credit the vet 100% of it instead of the
    /// ~70% split a completed visit earns (0028_tips.sql).
    func createTipCheckout(forVisit visitId: UUID, amountMinorUnits: Int) async throws -> URL
}

// MARK: - E9: saved payment methods — only a gateway token reference is
// ever stored; a card/UPI's raw details never reach this app or its backend.
protocol SavedPaymentMethodRepository: Sendable {
    func list(userId: UUID) async throws -> [SavedPaymentMethod]
    /// `gatewayTokenId` and `displayLabel` come back from the (not-yet-wired)
    /// gateway SDK's tokenization step — this call only persists the
    /// reference, it never sees a PAN/CVV.
    func save(userId: UUID, gatewayTokenId: String, displayLabel: String, makeDefault: Bool) async throws -> SavedPaymentMethod
    func remove(id: UUID) async throws
    func setDefault(id: UUID, userId: UUID) async throws
}

protocol ChatRepository: Sendable {
    func history(visitId: UUID) async throws -> [ChatMessage]
    func send(visitId: UUID, body: String) async throws -> ChatMessage
    /// J2: uploads image data to a private, visit-scoped bucket and returns
    /// the resulting attachment message — never a client-guessable public URL.
    func sendPhoto(visitId: UUID, imageData: Data) async throws -> ChatMessage
    func subscribe(visitId: UUID, onMessage: @escaping @Sendable (ChatMessage) -> Void) -> AnyObject
}

protocol ReviewRepository: Sendable {
    /// `comment` is the already-moderated text (PII redacted where needed)
    /// and `needsModeration`/`flags` are `ReviewModerationPolicy`'s verdict —
    /// `SubmitReviewUseCase` runs the policy before ever calling this.
    func submit(visitId: UUID, rating: Int, comment: String?, needsModeration: Bool, moderationFlags: [String]) async throws -> Review
    /// C5: reviews for a vet's profile — the ratings histogram and review
    /// list are both computed client-side from this.
    func reviews(vetId: UUID) async throws -> [Review]
}

// MARK: - Emergency path (plan §C11) — public-read, admin-write list of
// 24x7 emergency clinics to route a customer to when this app says outright
// it is not the right tool for the situation.
protocol EmergencyClinicRepository: Sendable {
    func listClinics() async throws -> [EmergencyClinic]
}

protocol PetRepository: Sendable {
    func listPets(ownerId: UUID) async throws -> [Pet]
    func addPet(_ pet: Pet) async throws -> Pet
    func updatePet(_ pet: Pet) async throws -> Pet
    func deletePet(id: UUID) async throws
}

// MARK: - Pet health records (plan §3 B, §3 K)

protocol PetWeightRepository: Sendable {
    /// Oldest-first, so the chart in `PetDetailView` can plot it directly.
    func history(petId: UUID) async throws -> [PetWeightEntry]
    func addEntry(_ entry: PetWeightEntry) async throws -> PetWeightEntry
}

protocol VaccinationRepository: Sendable {
    func history(petId: UUID) async throws -> [Vaccination]
    func record(_ vaccination: Vaccination) async throws -> Vaccination
}

protocol PrescriptionRepository: Sendable {
    func history(petId: UUID) async throws -> [Prescription]
}

/// F9: vet-declared leave/holiday windows.
protocol VetBlackoutRepository: Sendable {
    func blackouts(vetId: UUID) async throws -> [VetBlackout]
    /// Batch fetch for filtering a whole discovery page's worth of circuits
    /// without one round trip per vet.
    func blackouts(vetIds: [UUID]) async throws -> [VetBlackout]
    func create(_ blackout: VetBlackout) async throws -> VetBlackout
    func delete(id: UUID) async throws
}

/// K3: medication reminders. Household members of the pet (see
/// `HouseholdRepository`) can manage a pet's reminders, matching the pets
/// household-visibility grant (0020_households.sql) rather than inventing a
/// separate sharing model.
protocol MedicationReminderRepository: Sendable {
    func reminders(petId: UUID) async throws -> [MedicationReminder]
    func create(_ reminder: MedicationReminder) async throws -> MedicationReminder
    func update(_ reminder: MedicationReminder) async throws -> MedicationReminder
    func delete(id: UUID) async throws
}

protocol PushTokenRepository: Sendable {
    func registerDeviceToken(_ token: String, userId: UUID) async throws
    /// J8: whether this user currently has any registered device token —
    /// the delivery policy's first signal for "can push even reach them".
    func hasDeviceToken(userId: UUID) async throws -> Bool
}

/// J8: records the intent to send an SMS/WhatsApp fallback when push isn't
/// viable. No real gateway (Twilio/MSG91/...) is wired into this codebase —
/// see the type comment on `TransactionalNotificationCategory` and the
/// `send-sms-fallback` Edge Function for exactly where that call would go.
protocol SMSFallbackRepository: Sendable {
    func sendFallback(
        userId: UUID, phone: String, category: TransactionalNotificationCategory,
        body: String, reason: NotificationDeliveryDecision.FallbackReason
    ) async throws -> SMSFallbackRecord
}

// MARK: - V2: live tracking, calling, referrals

protocol LiveTrackingRepository: Sendable {
    /// Latest known location for the vet servicing this visit, if they're en route.
    func currentLocation(visitId: UUID) async throws -> VetLocation?
    /// Streams location updates for the duration of the visit's "en route" state.
    func subscribeToLocation(visitId: UUID, onUpdate: @escaping @Sendable (VetLocation) -> Void) -> AnyObject
}

protocol CallRepository: Sendable {
    /// J4: bridges a masked voice call for this visit — the customer dials
    /// `proxyNumber`, never the vet's real number. The gateway (Exotel/
    /// Twilio) resolves the proxy to whichever leg answers.
    func startCall(visitId: UUID) async throws -> CallSession
}

protocol ReferralRepository: Sendable {
    func myReferralCode(userId: UUID) async throws -> String
    func sendInvite(userId: UUID, phone: String) async throws -> Referral
    func listReferrals(userId: UUID) async throws -> [Referral]
}

protocol CartRepository: Sendable {
    /// Server-side cart (E2) — persists across devices, restored on relaunch.
    func currentCart(userId: UUID) async throws -> Cart
    func save(_ cart: Cart) async throws -> Cart
    func clear(userId: UUID) async throws
}

protocol QuoteRepository: Sendable {
    /// E6: the only source of a rupee amount the app is ever allowed to
    /// display or reference in an order. Pricing happens entirely server-side.
    /// `useWalletBalance` is the customer's toggle intent — the server (or
    /// the mock, standing in for it) looks up the *real* balance and applies
    /// at most that, never trusting a client-supplied amount.
    /// `applyEntitlementCredit` (H6) tells the server the first line item's
    /// base price should be zeroed against the caller's subscription credit
    /// — the server still re-derives and re-checks eligibility itself
    /// (`GetQuoteUseCase` only decides "is it worth asking", never "is it
    /// allowed": the client is never the source of truth for money).
    /// `overrides` (D5) are the booking vet's per-service price overrides, if
    /// any — resolved by the caller from the cart's circuit before quoting.
    func createQuote(for cart: Cart, catalog: [Service], overrides: [VetServiceOverride], useWalletBalance: Bool, applyEntitlementCredit: Bool) async throws -> Quote
}

protocol WalletRepository: Sendable {
    /// G6: balance is always derived from the ledger, never stored — see
    /// wallet_ledger's append-only discipline (0026_wallet_ledger.sql).
    func balanceMinorUnits(userId: UUID) async throws -> Int
    func entries(userId: UUID) async throws -> [WalletLedgerEntry]
}

protocol CouponRepository: Sendable {
    /// E4/N2: validated server-side via an RPC (never a direct table
    /// select) so codes aren't enumerable and stacking/usage limits are
    /// enforced in one place. Returns nil if the code doesn't apply.
    func validate(code: String, userId: UUID, cartTotalMinorUnits: Int) async throws -> Coupon?
}

/// H6: subscription credit balance, separate from `SubscriptionRepository`
/// because it resets on a period boundary, not a billing-status transition.
protocol SubscriptionEntitlementRepository: Sendable {
    func currentEntitlement(subscriptionId: UUID) async throws -> SubscriptionEntitlement?
    /// Persists a credit decrement (and any due rollover) atomically —
    /// returns the entitlement after the consumption, or throws if there was
    /// nothing left to consume (server-enforced, mirrors slot-hold capacity
    /// checks: the client's own `EntitlementPolicy.canApplyCredit` call is
    /// only a UI hint, not the authority).
    func consumeCredit(subscriptionId: UUID) async throws -> SubscriptionEntitlement
}

protocol SlotHoldRepository: Sendable {
    /// Places a 10-minute hold on a slot's remaining capacity for this user.
    /// Throws `.slotUnavailable` if no capacity remains once other active
    /// holds are accounted for.
    func placeHold(slotId: UUID, userId: UUID) async throws -> SlotHold
    func releaseHold(id: UUID) async throws
    /// Active (non-expired) holds against a slot — used to compute
    /// effective remaining capacity during checkout.
    func activeHolds(slotId: UUID) async throws -> [SlotHold]
}

protocol AddressRepository: Sendable {
    func listAddresses(ownerId: UUID) async throws -> [Address]
    func addAddress(_ address: Address) async throws -> Address
    func updateAddress(_ address: Address) async throws -> Address
    func deleteAddress(id: UUID) async throws
    func setDefault(id: UUID, ownerId: UUID) async throws
    /// Server-side geofence check: does a lat/lng fall inside a served cluster?
    /// Returns the matched cluster area name, or nil if uncovered.
    func matchCluster(latitude: Double, longitude: Double) async throws -> String?
}

protocol CatalogRepository: Sendable {
    /// All services offered, optionally scoped to a vertical (vet/elder-care/physio).
    func listServices(vertical: Vertical?) async throws -> [Service]
    func service(id: UUID) async throws -> Service
}

protocol PackageRepository: Sendable {
    /// D4: packages/bundles, browsed the same way services are.
    func listPackages(vertical: Vertical?) async throws -> [Package]
    func package(id: UUID) async throws -> Package
}

protocol LoyaltyRepository: Sendable {
    func account(userId: UUID) async throws -> LoyaltyAccount
    /// Called when a visit completes; awards points and returns the updated account.
    func awardPoints(userId: UUID, points: Int) async throws -> LoyaltyAccount
}

// MARK: - D5: per-vet service overrides — public read (customers need to see
// the effective price before booking), vet-write-own.
protocol VetServiceOverrideRepository: Sendable {
    func overrides(vetId: UUID) async throws -> [VetServiceOverride]
    func setOverride(_ override: VetServiceOverride) async throws -> VetServiceOverride
}

// MARK: - F5: recurring booking rules — owner-only.
protocol RecurringBookingRuleRepository: Sendable {
    func rules(userId: UUID) async throws -> [RecurringBookingRule]
    func create(_ rule: RecurringBookingRule) async throws -> RecurringBookingRule
    func setActive(id: UUID, isActive: Bool) async throws -> RecurringBookingRule
    func delete(id: UUID) async throws
}

// MARK: - F6: vet-initiated reschedule proposals.
protocol RescheduleProposalRepository: Sendable {
    func pendingProposal(visitId: UUID) async throws -> RescheduleProposal?
    func create(_ proposal: RescheduleProposal) async throws -> RescheduleProposal
    func respond(id: UUID, accept: Bool) async throws -> RescheduleProposal
}

/// H7: corporate/RWA seat assignment — who fills each of a corporate
/// subscription's billed seats. `SubscriptionManagementPolicy`'s seat-floor
/// rule stays the money-side authority; this is purely the roster.
protocol CorporateSeatAssignmentRepository: Sendable {
    func assignments(subscriptionId: UUID) async throws -> [CorporateSeatAssignment]
    /// Throws if every seat is already filled — enforced against
    /// `Subscription.seatCount`, the real (billed) ceiling.
    func assignSeat(subscriptionId: UUID, phone: String, seatCount: Int) async throws -> CorporateSeatAssignment
    func unassignSeat(id: UUID) async throws
}

protocol NotificationPreferencesRepository: Sendable {
    /// Returns the default (all-on except promotions) preferences if the user
    /// has never saved any — there is always a value to render toggles from.
    func preferences(userId: UUID) async throws -> NotificationPreferences
    func save(_ preferences: NotificationPreferences) async throws -> NotificationPreferences
}

protocol AppConfigRepository: Sendable {
    /// O7/O8: fetched once at launch, no auth required — a signed-out device
    /// on a killed binary still needs to be told to update.
    func fetchConfig() async throws -> RemoteAppConfig
}

// MARK: - Support, help & notifications (plan §M, §J7)

protocol HelpRepository: Sendable {
    /// M1: remote FAQ content — no app-store release needed to fix an answer.
    func listArticles() async throws -> [HelpArticle]
}

protocol SupportRepository: Sendable {
    /// M2/K8: a ticket, optionally carrying visit context (a dispute is just
    /// a ticket with `visitId` set). No update method on purpose — once
    /// submitted, only ops can change its status (mirrors `refunds`: the
    /// client reads state, never writes it after creation).
    func createTicket(userId: UUID, visitId: UUID?, subject: String, body: String) async throws -> SupportTicket
    func myTickets(userId: UUID) async throws -> [SupportTicket]
}

// MARK: - M4: support-issued refunds/credits, with an append-only audit
// trail. The actual money movement (refund row / wallet ledger entry)
// happens inside the `issue-support-refund` Edge Function, service-role
// only — this repository never inserts into `refunds` or `wallet_ledger`
// directly, mirroring `RefundRepository.issueRefund`'s trusted-boundary.
protocol SupportRefundAuditRepository: Sendable {
    func issueSupportRefund(
        ticketId: UUID, visitId: UUID, issuedByUserId: UUID,
        kind: SupportRefundAudit.Kind, amountMinorUnits: Int, reason: String
    ) async throws -> SupportRefundAudit
    func auditTrail(ticketId: UUID) async throws -> [SupportRefundAudit]
}

protocol AppNotificationRepository: Sendable {
    /// J7: the in-app notification centre/history — distinct from
    /// `NotificationPreferencesRepository`'s per-channel opt-in/out toggles.
    func notifications(userId: UUID) async throws -> [AppNotification]
    func markRead(id: UUID) async throws
}

// MARK: - A9 household sharing

protocol HouseholdRepository: Sendable {
    /// The household a user belongs to (owner or member), if any — a user
    /// can be a member of at most one household in this model, matching
    /// the plan's "invite spouse/family" scope rather than arbitrary groups.
    func myHousehold(userId: UUID) async throws -> Household?
    func createHousehold(name: String, ownerId: UUID) async throws -> Household
    func members(householdId: UUID) async throws -> [HouseholdMember]
    /// Invites by phone; the member row exists (with `invitedPhone` set)
    /// even before the invitee's own user row does, mirroring `Referral`.
    func invite(householdId: UUID, phone: String) async throws -> HouseholdMember
    /// A member removes themselves, or the owner removes anyone — enforced
    /// server-side by RLS (0020_households.sql), not just in the UI.
    func removeMember(householdId: UUID, memberId: UUID) async throws
}

// MARK: - C10 waitlist

// MARK: - C8 search — "Postgres FTS is enough; do not add a search cluster"
// (plan §3 C8). Default extensions give every conformer (including any mock
// or preview stub not updated here) a working client-side substring search
// over whatever `listCircuits`/`listServices` already returns; the Supabase
// conformers override these with a real server-side FTS/ILIKE query so
// search doesn't require pulling the entire catalog to the client in prod.

extension CircuitRepository {
    func searchCircuits(term: String, area: String?) async throws -> [Circuit] {
        let circuits = try await listCircuits(area: area)
        let needle = term.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return circuits }
        return circuits.filter {
            $0.clusterArea.lowercased().contains(needle) || ($0.vet?.name.lowercased().contains(needle) ?? false)
        }
    }
}

extension CatalogRepository {
    func searchServices(term: String, vertical: Vertical?) async throws -> [Service] {
        let services = try await listServices(vertical: vertical)
        let needle = term.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return services }
        return services.filter {
            $0.name.lowercased().contains(needle) || $0.summary.lowercased().contains(needle)
        }
    }
}

protocol WaitlistRepository: Sendable {
    func join(userId: UUID, addressId: UUID?, latitude: Double, longitude: Double, areaLabel: String?) async throws -> WaitlistEntry
    /// Count only — never the individual rows, so "N neighbours waiting"
    /// never exposes who they are (see `waitlist_count_near` RPC).
    func countNear(latitude: Double, longitude: Double, radiusKm: Double) async throws -> Int
    func hasJoined(userId: UUID, addressId: UUID?) async throws -> Bool
}

// MARK: - B6 document vault — prior vet reports / insurance docs against a
// pet. No Storage SDK wiring exists yet: the Supabase conformer inserts a
// real `pet_documents` row referencing a `documents` bucket path, but the
// actual file bytes upload is a TODO (see `SupabasePetDocumentRepository`).
protocol PetDocumentRepository: Sendable {
    func list(petId: UUID) async throws -> [PetDocument]
    /// `data` is the raw file bytes to upload; the Supabase conformer will
    /// eventually push these to Storage under a UUID-based filename — for
    /// now the mock just fabricates a placeholder URL from that filename.
    func upload(petId: UUID, uploaderId: UUID, title: String, data: Data) async throws -> PetDocument
    func delete(id: UUID) async throws
}

/// K6: lab test reports attached to a visit. No client insert/update method
/// on purpose — reports are uploaded ops-side once results are back, matching
/// `SupportRepository`'s "the client reads state, never writes it after
/// creation" pattern.
protocol LabTestReportRepository: Sendable {
    func reports(petId: UUID) async throws -> [LabTestReport]
    func reports(visitId: UUID) async throws -> [LabTestReport]
}

/// L4/L5: a reporter can create and read only their own reports — ops-side
/// listing (all reports, vet suspension) is an ops-console concern, out of
/// scope here (see 0027_incident_reports.sql).
protocol IncidentReportRepository: Sendable {
    func fileReport(_ report: IncidentReport) async throws -> IncidentReport
    func myReports(reporterId: UUID) async throws -> [IncidentReport]
}
