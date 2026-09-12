import Foundation

// MARK: - In-memory mock repositories
// Used for SwiftUI previews, unit tests, and running the app without a
// configured backend. Swap for Supabase-backed implementations in
// App/DependencyContainer.swift once a project is configured.

actor MockAuthRepository: AuthRepository {
    private var user: User? = MockData.user

    func currentUser() async -> User? { user }

    func signInWithApple(identityToken: String, nonce: String) async throws -> User {
        user = MockData.user
        return MockData.user
    }

    func requestOTP(phone: String) async throws {}

    func verifyOTP(phone: String, code: String) async throws -> User {
        user = MockData.user
        return MockData.user
    }

    func signOut() async throws { user = nil }
}

actor MockCircuitRepository: CircuitRepository {
    func listCircuits(area: String?) async throws -> [Circuit] {
        guard let area else { return MockData.circuits }
        return MockData.circuits.filter { $0.clusterArea.localizedCaseInsensitiveContains(area) }
    }

    func circuit(id: UUID) async throws -> Circuit {
        guard let circuit = MockData.circuits.first(where: { $0.id == id }) else {
            throw DomainError.notFound("Circuit")
        }
        return circuit
    }
}

actor MockVisitRepository: VisitRepository {
    private var visits: [Visit] = MockData.visits

    func createVisit(petId: UUID, vetId: UUID, circuitId: UUID, slot: ScheduleSlot) async throws -> Visit {
        let visit = Visit(
            id: UUID(), userId: MockData.user.id, petId: petId, vetId: vetId, circuitId: circuitId,
            status: .requested, scheduledAt: slot.startTime, completedAt: nil, notes: nil, paymentId: nil
        )
        visits.append(visit)
        return visit
    }

    func listVisits(userId: UUID) async throws -> [Visit] {
        visits.filter { $0.userId == userId }
    }

    func visit(id: UUID) async throws -> Visit {
        guard let visit = visits.first(where: { $0.id == id }) else { throw DomainError.notFound("Visit") }
        return visit
    }

    func updateStatus(visitId: UUID, status: Visit.VisitStatus) async throws -> Visit {
        guard let index = visits.firstIndex(where: { $0.id == visitId }) else { throw DomainError.notFound("Visit") }
        visits[index].status = status
        return visits[index]
    }

    func cancelVisit(visitId: UUID) async throws {
        guard let index = visits.firstIndex(where: { $0.id == visitId }) else { throw DomainError.notFound("Visit") }
        visits[index].status = .cancelled
    }
}

actor MockSubscriptionRepository: SubscriptionRepository {
    private var subscription: Subscription?

    func currentSubscription(userId: UUID) async throws -> Subscription? { subscription }

    func subscribe(userId: UUID, plan: Subscription.PlanType) async throws -> Subscription {
        let sub = Subscription(id: UUID(), userId: userId, planType: plan, status: .active,
                                renewalDate: Calendar.current.date(byAdding: .month, value: 1, to: .now) ?? .now)
        subscription = sub
        return sub
    }

    func cancel(subscriptionId: UUID) async throws {
        if subscription?.id == subscriptionId { subscription?.status = .cancelled }
    }
}

actor MockPaymentRepository: PaymentRepository {
    func createCheckout(forVisit visitId: UUID, amountMinorUnits: Int) async throws -> URL {
        URL(string: "https://checkout.example.com/visit/\(visitId)")!
    }

    func createCheckout(forSubscription plan: Subscription.PlanType) async throws -> URL {
        URL(string: "https://checkout.example.com/subscription/\(plan.rawValue)")!
    }

    func paymentStatus(paymentId: UUID) async throws -> Payment.Status { .succeeded }
}

actor MockChatRepository: ChatRepository {
    private var messages: [UUID: [ChatMessage]] = [:]

    func history(visitId: UUID) async throws -> [ChatMessage] { messages[visitId] ?? [] }

    func send(visitId: UUID, body: String) async throws -> ChatMessage {
        let message = ChatMessage(id: UUID(), visitId: visitId, senderId: MockData.user.id, body: body, sentAt: .now, readAt: nil)
        messages[visitId, default: []].append(message)
        return message
    }

    nonisolated func subscribe(visitId: UUID, onMessage: @escaping @Sendable (ChatMessage) -> Void) -> AnyObject {
        NSObject() // no-op token; mock has no realtime transport
    }
}

actor MockReviewRepository: ReviewRepository {
    func submit(visitId: UUID, rating: Int, comment: String?) async throws -> Review {
        Review(id: UUID(), visitId: visitId, vetId: MockData.circuits[0].vetId, userId: MockData.user.id,
               rating: rating, comment: comment, createdAt: .now)
    }
}

actor MockPetRepository: PetRepository {
    private var pets: [Pet] = MockData.user.pets

    func listPets(ownerId: UUID) async throws -> [Pet] { pets.filter { $0.ownerId == ownerId } }

    func addPet(_ pet: Pet) async throws -> Pet {
        pets.append(pet)
        return pet
    }

    func updatePet(_ pet: Pet) async throws -> Pet {
        guard let index = pets.firstIndex(where: { $0.id == pet.id }) else { throw DomainError.notFound("Pet") }
        pets[index] = pet
        return pet
    }

    func deletePet(id: UUID) async throws {
        pets.removeAll { $0.id == id }
    }
}

actor MockPushTokenRepository: PushTokenRepository {
    func registerDeviceToken(_ token: String, userId: UUID) async throws {}
}

actor MockLiveTrackingRepository: LiveTrackingRepository {
    func currentLocation(visitId: UUID) async throws -> VetLocation? {
        // Bengaluru-ish coordinate, jittered slightly so the map shows movement.
        VetLocation(visitId: visitId, latitude: 12.9352 + Double.random(in: -0.002...0.002),
                    longitude: 77.6146 + Double.random(in: -0.002...0.002), updatedAt: .now, etaMinutes: Int.random(in: 3...20))
    }

    nonisolated func subscribeToLocation(visitId: UUID, onUpdate: @escaping @Sendable (VetLocation) -> Void) -> AnyObject {
        let timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { _ in
            let location = VetLocation(visitId: visitId, latitude: 12.9352 + Double.random(in: -0.003...0.003),
                                        longitude: 77.6146 + Double.random(in: -0.003...0.003), updatedAt: .now,
                                        etaMinutes: Int.random(in: 1...15))
            onUpdate(location)
        }
        return timer
    }
}

actor MockCallRepository: CallRepository {
    func startCall(visitId: UUID) async throws -> URL {
        URL(string: "https://call.example.com/visit/\(visitId)")!
    }
}

actor MockLoyaltyRepository: LoyaltyRepository {
    private var accounts: [UUID: LoyaltyAccount] = [:]

    func account(userId: UUID) async throws -> LoyaltyAccount {
        accounts[userId] ?? LoyaltyAccount(userId: userId, points: 0, tier: .bronze)
    }

    func awardPoints(userId: UUID, points: Int) async throws -> LoyaltyAccount {
        var current = try await account(userId: userId)
        current.points += points
        current.tier = .forPoints(current.points)
        accounts[userId] = current
        return current
    }
}

actor MockReferralRepository: ReferralRepository {
    private var referrals: [Referral] = []

    func myReferralCode(userId: UUID) async throws -> String {
        "VC-" + userId.uuidString.prefix(6).uppercased()
    }

    func sendInvite(userId: UUID, phone: String) async throws -> Referral {
        let referral = Referral(id: UUID(), referrerId: userId, code: try await myReferralCode(userId: userId),
                                 invitedPhone: phone, status: .pending, rewardApplied: false, createdAt: .now)
        referrals.append(referral)
        return referral
    }

    func listReferrals(userId: UUID) async throws -> [Referral] {
        referrals.filter { $0.referrerId == userId }
    }
}

// MARK: - Shared fixture data

enum MockData {
    static let user = User(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        phone: "+919999999999", name: "Aanya Sharma", email: nil, createdAt: .now,
        pets: [Pet(id: UUID(), ownerId: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                   name: "Bruno", species: .dog, breed: "Labrador", dateOfBirth: nil)]
    )

    static let vet = Vet(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        name: "Dr. Rohan Mehta", licenseNumber: "VCI-2024-11234",
        verificationStatus: .verified, rating: 4.8, reviewCount: 132, photoURL: nil
    )

    static let circuits: [Circuit] = [
        Circuit(
            id: UUID(), vetId: vet.id, vet: vet, clusterArea: "Koramangala 5th Block",
            schedule: (0..<3).map { offset in
                ScheduleSlot(
                    id: UUID(), dayOfWeek: (offset % 7) + 1,
                    startTime: Calendar.current.date(byAdding: .day, value: offset, to: .now) ?? .now,
                    endTime: Calendar.current.date(byAdding: .hour, value: offset + 1, to: .now) ?? .now,
                    isAvailable: true
                )
            }
        )
    ]

    static let visits: [Visit] = []
}
