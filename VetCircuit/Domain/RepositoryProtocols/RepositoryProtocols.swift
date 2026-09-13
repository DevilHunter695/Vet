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
    func submit(visitId: UUID, rating: Int, comment: String?) async throws -> Review
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

protocol PushTokenRepository: Sendable {
    func registerDeviceToken(_ token: String, userId: UUID) async throws
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
    func createQuote(for cart: Cart, catalog: [Service]) async throws -> Quote
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

protocol AppNotificationRepository: Sendable {
    /// J7: the in-app notification centre/history — distinct from
    /// `NotificationPreferencesRepository`'s per-channel opt-in/out toggles.
    func notifications(userId: UUID) async throws -> [AppNotification]
    func markRead(id: UUID) async throws
}
