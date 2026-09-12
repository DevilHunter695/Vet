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
