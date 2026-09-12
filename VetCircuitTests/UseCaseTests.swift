import Testing
import Foundation
@testable import VetCircuit

// Domain-layer tests: pure Swift business logic, no UI or network spun up.

@Suite("BookVisitUseCase")
struct BookVisitUseCaseTests {
    @Test("rejects a slot that is not available")
    func rejectsUnavailableSlot() async {
        let repo = MockVisitRepository()
        let useCase = BookVisitUseCase(visitRepository: repo)
        let slot = ScheduleSlot(id: UUID(), dayOfWeek: 2, startTime: .now.addingTimeInterval(3600),
                                 endTime: .now.addingTimeInterval(7200), isAvailable: false)

        await #expect(throws: DomainError.slotUnavailable) {
            _ = try await useCase.execute(petId: UUID(), vetId: UUID(), circuitId: UUID(), slot: slot)
        }
    }

    @Test("rejects a slot in the past")
    func rejectsPastSlot() async {
        let repo = MockVisitRepository()
        let useCase = BookVisitUseCase(visitRepository: repo)
        let slot = ScheduleSlot(id: UUID(), dayOfWeek: 2, startTime: .now.addingTimeInterval(-3600),
                                 endTime: .now, isAvailable: true)

        await #expect(throws: DomainError.self) {
            _ = try await useCase.execute(petId: UUID(), vetId: UUID(), circuitId: UUID(), slot: slot)
        }
    }

    @Test("books a valid, future, available slot")
    func booksValidSlot() async throws {
        let repo = MockVisitRepository()
        let useCase = BookVisitUseCase(visitRepository: repo)
        let slot = ScheduleSlot(id: UUID(), dayOfWeek: 2, startTime: .now.addingTimeInterval(3600),
                                 endTime: .now.addingTimeInterval(7200), isAvailable: true)

        let visit = try await useCase.execute(petId: UUID(), vetId: UUID(), circuitId: UUID(), slot: slot)
        #expect(visit.status == .requested)
    }
}

@Suite("CancelVisitUseCase")
struct CancelVisitUseCaseTests {
    @Test("allows cancelling a requested visit")
    func cancelsRequested() async throws {
        let repo = MockVisitRepository()
        let visit = try await repo.createVisit(
            petId: UUID(), vetId: UUID(), circuitId: UUID(),
            slot: ScheduleSlot(id: UUID(), dayOfWeek: 1, startTime: .now.addingTimeInterval(3600), endTime: .now.addingTimeInterval(7200), isAvailable: true)
        )
        let useCase = CancelVisitUseCase(visitRepository: repo)
        try await useCase.execute(visitId: visit.id, currentStatus: .requested)
        let updated = try await repo.visit(id: visit.id)
        #expect(updated.status == .cancelled)
    }

    @Test("refuses to cancel a completed visit")
    func refusesCompletedCancel() async {
        let repo = MockVisitRepository()
        let useCase = CancelVisitUseCase(visitRepository: repo)
        await #expect(throws: DomainError.self) {
            try await useCase.execute(visitId: UUID(), currentStatus: .completed)
        }
    }
}

@Suite("SendChatMessageUseCase")
struct SendChatMessageUseCaseTests {
    @Test("rejects empty messages")
    func rejectsEmpty() async {
        let useCase = SendChatMessageUseCase(chatRepository: MockChatRepository())
        await #expect(throws: DomainError.self) {
            _ = try await useCase.execute(visitId: UUID(), body: "   ")
        }
    }

    @Test("sends a valid message")
    func sendsValid() async throws {
        let useCase = SendChatMessageUseCase(chatRepository: MockChatRepository())
        let message = try await useCase.execute(visitId: UUID(), body: "Hello!")
        #expect(message.body == "Hello!")
    }
}

@Suite("SubmitReviewUseCase")
struct SubmitReviewUseCaseTests {
    @Test("rejects out-of-range ratings")
    func rejectsInvalidRating() async {
        let useCase = SubmitReviewUseCase(reviewRepository: MockReviewRepository())
        await #expect(throws: DomainError.self) {
            _ = try await useCase.execute(visitId: UUID(), rating: 6, comment: nil)
        }
    }

    @Test("accepts a valid rating")
    func acceptsValidRating() async throws {
        let useCase = SubmitReviewUseCase(reviewRepository: MockReviewRepository())
        let review = try await useCase.execute(visitId: UUID(), rating: 4, comment: "Great visit")
        #expect(review.rating == 4)
    }
}

@Suite("RunTriageUseCase")
struct RunTriageUseCaseTests {
    @Test("rejects empty symptom description")
    func rejectsEmpty() async {
        let useCase = RunTriageUseCase(triageRepository: MockTriageRepository())
        await #expect(throws: DomainError.self) {
            _ = try await useCase.execute(species: .dog, symptoms: "  ")
        }
    }

    @Test("flags urgent symptoms")
    func flagsUrgent() async throws {
        let useCase = RunTriageUseCase(triageRepository: MockTriageRepository())
        let result = try await useCase.execute(species: .dog, symptoms: "He is bleeding heavily from a cut")
        #expect(result.recommendation == .bookVisitUrgently)
    }

    @Test("routes mild symptoms to self-care")
    func routesMildToSelfCare() async throws {
        let useCase = RunTriageUseCase(triageRepository: MockTriageRepository())
        let result = try await useCase.execute(species: .cat, symptoms: "Seems a little sleepy today")
        #expect(result.recommendation == .selfCare)
    }
}

@Suite("SendReferralUseCase")
struct SendReferralUseCaseTests {
    @Test("rejects an invalid phone number")
    func rejectsInvalidPhone() async {
        let useCase = SendReferralUseCase(referralRepository: MockReferralRepository())
        await #expect(throws: DomainError.self) {
            _ = try await useCase.execute(userId: UUID(), phone: "123")
        }
    }

    @Test("sends a valid invite")
    func sendsValidInvite() async throws {
        let useCase = SendReferralUseCase(referralRepository: MockReferralRepository())
        let referral = try await useCase.execute(userId: UUID(), phone: "9876543210")
        #expect(referral.status == .pending)
    }
}

@Suite("TrackVetUseCase")
struct TrackVetUseCaseTests {
    @Test("returns the vet's current location")
    func returnsLocation() async throws {
        let useCase = TrackVetUseCase(liveTrackingRepository: MockLiveTrackingRepository())
        let location = try await useCase.execute(visitId: UUID())
        #expect(location != nil)
    }
}

@Suite("ManagePetsUseCase")
struct ManagePetsUseCaseTests {
    @Test("rejects a pet with an empty name")
    func rejectsEmptyName() async {
        let useCase = ManagePetsUseCase(petRepository: MockPetRepository())
        let pet = Pet(id: UUID(), ownerId: UUID(), name: "  ", species: .dog, breed: nil, dateOfBirth: nil)
        await #expect(throws: DomainError.self) {
            _ = try await useCase.add(pet)
        }
    }
}
