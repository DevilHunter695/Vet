import Foundation

// MARK: - Use cases: pure business logic, unit-testable without UI or network

struct GetCircuitsUseCase {
    let repository: CircuitRepository

    func execute(area: String?, vertical: Vertical = .vet) async throws -> [Circuit] {
        let circuits = try await repository.listCircuits(area: area)
        return circuits
            .filter { $0.vertical == vertical }
            .sorted { $0.clusterArea < $1.clusterArea }
    }
}

struct BookVisitUseCase {
    let visitRepository: VisitRepository

    func execute(petId: UUID, vetId: UUID, circuitId: UUID, slot: ScheduleSlot) async throws -> Visit {
        guard slot.isAvailable else { throw DomainError.slotUnavailable }
        guard slot.startTime > Date() else {
            throw DomainError.validation("Please choose a slot in the future.")
        }
        return try await visitRepository.createVisit(petId: petId, vetId: vetId, circuitId: circuitId, slot: slot)
    }
}

struct CancelVisitUseCase {
    let visitRepository: VisitRepository

    func execute(visitId: UUID, currentStatus: Visit.VisitStatus) async throws {
        guard currentStatus == .requested || currentStatus == .confirmed else {
            throw DomainError.validation("This visit can no longer be cancelled.")
        }
        try await visitRepository.cancelVisit(visitId: visitId)
    }
}

struct GetVisitHistoryUseCase {
    let visitRepository: VisitRepository

    func execute(userId: UUID) async throws -> [Visit] {
        let visits = try await visitRepository.listVisits(userId: userId)
        return visits.sorted { $0.scheduledAt > $1.scheduledAt }
    }
}

struct SubscribeToPlanUseCase {
    let subscriptionRepository: SubscriptionRepository
    let paymentRepository: PaymentRepository

    func execute(userId: UUID, plan: Subscription.PlanType, seatCount: Int = 1) async throws -> URL {
        if plan.isBulk {
            guard seatCount >= 5 else {
                throw DomainError.validation("Corporate/RWA plans require at least 5 seats.")
            }
        }
        return try await paymentRepository.createCheckout(forSubscription: plan)
    }
}

struct SendChatMessageUseCase {
    let chatRepository: ChatRepository

    func execute(visitId: UUID, body: String) async throws -> ChatMessage {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DomainError.validation("Message can't be empty.")
        }
        guard trimmed.count <= 2000 else {
            throw DomainError.validation("Message is too long.")
        }
        return try await chatRepository.send(visitId: visitId, body: trimmed)
    }
}

struct SubmitReviewUseCase {
    let reviewRepository: ReviewRepository

    func execute(visitId: UUID, rating: Int, comment: String?) async throws -> Review {
        guard (1...5).contains(rating) else {
            throw DomainError.validation("Rating must be between 1 and 5.")
        }
        return try await reviewRepository.submit(visitId: visitId, rating: rating, comment: comment)
    }
}

struct ManagePetsUseCase {
    let petRepository: PetRepository

    func list(ownerId: UUID) async throws -> [Pet] {
        try await petRepository.listPets(ownerId: ownerId)
    }

    func add(_ pet: Pet) async throws -> Pet {
        guard !pet.name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw DomainError.validation("Pet name is required.")
        }
        return try await petRepository.addPet(pet)
    }

    func remove(id: UUID) async throws {
        try await petRepository.deletePet(id: id)
    }
}

struct StartCheckoutUseCase {
    let paymentRepository: PaymentRepository

    func execute(visitId: UUID, amountMinorUnits: Int) async throws -> URL {
        guard amountMinorUnits > 0 else {
            throw DomainError.validation("Invalid amount.")
        }
        return try await paymentRepository.createCheckout(forVisit: visitId, amountMinorUnits: amountMinorUnits)
    }
}

// MARK: - V2 use cases

struct TrackVetUseCase {
    let liveTrackingRepository: LiveTrackingRepository

    func execute(visitId: UUID) async throws -> VetLocation? {
        try await liveTrackingRepository.currentLocation(visitId: visitId)
    }

    func subscribe(visitId: UUID, onUpdate: @escaping @Sendable (VetLocation) -> Void) -> AnyObject {
        liveTrackingRepository.subscribeToLocation(visitId: visitId, onUpdate: onUpdate)
    }
}

struct StartCallUseCase {
    let callRepository: CallRepository

    func execute(visitId: UUID) async throws -> URL {
        try await callRepository.startCall(visitId: visitId)
    }
}

struct GetLoyaltyAccountUseCase {
    let loyaltyRepository: LoyaltyRepository

    func execute(userId: UUID) async throws -> LoyaltyAccount {
        try await loyaltyRepository.account(userId: userId)
    }
}

struct GetCatalogUseCase {
    let catalogRepository: CatalogRepository

    /// Services for a vertical, filtered to ones a given pet is actually
    /// eligible for (species gate) — showing an ineligible service just to
    /// hide it behind a disabled button is a worse experience than not
    /// listing it at all.
    func execute(vertical: Vertical, forSpecies species: Pet.Species? = nil) async throws -> [Service] {
        let services = try await catalogRepository.listServices(vertical: vertical)
        let eligible = species.map { s in services.filter { $0.eligibility.allows(species: s) } } ?? services
        return eligible.sorted { $0.name < $1.name }
    }
}

struct SendReferralUseCase {
    let referralRepository: ReferralRepository

    func execute(userId: UUID, phone: String) async throws -> Referral {
        let digitsOnly = phone.filter(\.isNumber)
        guard digitsOnly.count >= 10 else {
            throw DomainError.validation("Enter a valid phone number to invite.")
        }
        return try await referralRepository.sendInvite(userId: userId, phone: phone)
    }
}
