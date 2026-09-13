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
    func createVisit(petId: UUID, vetId: UUID, circuitId: UUID, slot: ScheduleSlot) async throws -> Visit
    func listVisits(userId: UUID) async throws -> [Visit]
    func visit(id: UUID) async throws -> Visit
    func updateStatus(visitId: UUID, status: Visit.VisitStatus) async throws -> Visit
    func cancelVisit(visitId: UUID) async throws
}

protocol SubscriptionRepository: Sendable {
    func currentSubscription(userId: UUID) async throws -> Subscription?
    func subscribe(userId: UUID, plan: Subscription.PlanType) async throws -> Subscription
    func cancel(subscriptionId: UUID) async throws
}

protocol PaymentRepository: Sendable {
    func createCheckout(forVisit visitId: UUID, amountMinorUnits: Int) async throws -> URL
    func createCheckout(forSubscription plan: Subscription.PlanType) async throws -> URL
    func paymentStatus(paymentId: UUID) async throws -> Payment.Status
}

protocol ChatRepository: Sendable {
    func history(visitId: UUID) async throws -> [ChatMessage]
    func send(visitId: UUID, body: String) async throws -> ChatMessage
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
    /// Creates (or joins) a call room for a visit and returns a joinable URL/token payload.
    func startCall(visitId: UUID) async throws -> URL
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

protocol LoyaltyRepository: Sendable {
    func account(userId: UUID) async throws -> LoyaltyAccount
    /// Called when a visit completes; awards points and returns the updated account.
    func awardPoints(userId: UUID, points: Int) async throws -> LoyaltyAccount
}
