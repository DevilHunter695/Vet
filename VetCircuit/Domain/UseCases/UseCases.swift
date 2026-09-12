import Foundation

// MARK: - Use cases: pure business logic, unit-testable without UI or network

struct GetCircuitsUseCase {
    let repository: CircuitRepository

    func execute(area: String?) async throws -> [Circuit] {
        let circuits = try await repository.listCircuits(area: area)
        return circuits.sorted { $0.clusterArea < $1.clusterArea }
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

    func execute(userId: UUID, plan: Subscription.PlanType) async throws -> URL {
        try await paymentRepository.createCheckout(forSubscription: plan)
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
