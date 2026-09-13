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
                                 endTime: .now.addingTimeInterval(7200), capacity: 1, bookedCount: 1)

        await #expect(throws: DomainError.slotUnavailable) {
            _ = try await useCase.execute(petId: UUID(), vetId: UUID(), circuitId: UUID(), slot: slot)
        }
    }

    @Test("rejects a slot in the past")
    func rejectsPastSlot() async {
        let repo = MockVisitRepository()
        let useCase = BookVisitUseCase(visitRepository: repo)
        let slot = ScheduleSlot(id: UUID(), dayOfWeek: 2, startTime: .now.addingTimeInterval(-3600),
                                 endTime: .now, capacity: 3, bookedCount: 0)

        await #expect(throws: DomainError.self) {
            _ = try await useCase.execute(petId: UUID(), vetId: UUID(), circuitId: UUID(), slot: slot)
        }
    }

    @Test("rejects a slot that is at full capacity even if not explicitly marked unavailable")
    func rejectsFullCapacitySlot() async {
        let repo = MockVisitRepository()
        let useCase = BookVisitUseCase(visitRepository: repo)
        let slot = ScheduleSlot(id: UUID(), dayOfWeek: 2, startTime: .now.addingTimeInterval(3600),
                                 endTime: .now.addingTimeInterval(7200), capacity: 5, bookedCount: 5)

        await #expect(throws: DomainError.slotUnavailable) {
            _ = try await useCase.execute(petId: UUID(), vetId: UUID(), circuitId: UUID(), slot: slot)
        }
    }

    @Test("books a valid, future, available slot")
    func booksValidSlot() async throws {
        let repo = MockVisitRepository()
        let useCase = BookVisitUseCase(visitRepository: repo)
        let slot = ScheduleSlot(id: UUID(), dayOfWeek: 2, startTime: .now.addingTimeInterval(3600),
                                 endTime: .now.addingTimeInterval(7200), capacity: 3, bookedCount: 0)

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
            slot: ScheduleSlot(id: UUID(), dayOfWeek: 1, startTime: .now.addingTimeInterval(3600), endTime: .now.addingTimeInterval(7200), capacity: 3, bookedCount: 0)
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

@Suite("GetCircuitsUseCase")
struct GetCircuitsUseCaseTests {
    @Test("filters circuits by vertical")
    func filtersByVertical() async throws {
        let useCase = GetCircuitsUseCase(repository: MockCircuitRepository())
        let vetCircuits = try await useCase.execute(area: nil, vertical: .vet)
        let elderCareCircuits = try await useCase.execute(area: nil, vertical: .elderCare)
        #expect(!vetCircuits.isEmpty)
        #expect(elderCareCircuits.isEmpty)
    }
}

@Suite("GetLoyaltyAccountUseCase")
struct GetLoyaltyAccountUseCaseTests {
    @Test("starts at zero points and bronze tier")
    func startsAtBronze() async throws {
        let useCase = GetLoyaltyAccountUseCase(loyaltyRepository: MockLoyaltyRepository())
        let account = try await useCase.execute(userId: UUID())
        #expect(account.points == 0)
        #expect(account.tier == .bronze)
    }

    @Test("awarding points can move the tier to silver")
    func awardingMovesTier() async throws {
        let repo = MockLoyaltyRepository()
        let account = try await repo.awardPoints(userId: UUID(), points: 250)
        #expect(account.tier == .silver)
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

@Suite("HoldSlotUseCase")
struct HoldSlotUseCaseTests {
    @Test("places a hold on a slot with remaining capacity")
    func placesHold() async throws {
        let circuitRepo = MockCircuitRepository()
        let holdRepo = MockSlotHoldRepository()
        let useCase = HoldSlotUseCase(circuitRepository: circuitRepo, slotHoldRepository: holdRepo)
        let circuit = MockData.circuits[0]
        let slot = circuit.schedule.first { $0.isAvailable }!

        let hold = try await useCase.execute(circuitId: circuit.id, slotId: slot.id, userId: UUID())
        #expect(hold.slotId == slot.id)
        #expect(!hold.isExpired)
    }

    @Test("rejects a hold once concurrent holds exhaust remaining capacity")
    func rejectsWhenHoldsExhaustCapacity() async throws {
        let circuitRepo = MockCircuitRepository()
        let holdRepo = MockSlotHoldRepository()
        let useCase = HoldSlotUseCase(circuitRepository: circuitRepo, slotHoldRepository: holdRepo)
        let circuit = MockData.circuits[0]
        let slot = circuit.schedule.first { $0.isAvailable }!

        for _ in 0..<slot.remainingCapacity {
            _ = try await useCase.execute(circuitId: circuit.id, slotId: slot.id, userId: UUID())
        }

        await #expect(throws: DomainError.slotUnavailable) {
            _ = try await useCase.execute(circuitId: circuit.id, slotId: slot.id, userId: UUID())
        }
    }
}

@Suite("ManageAddressesUseCase")
struct ManageAddressesUseCaseTests {
    @Test("rejects an address with an empty line1")
    func rejectsEmptyLine1() async {
        let repo = MockAddressRepository()
        let useCase = ManageAddressesUseCase(addressRepository: repo)
        let address = Address(id: UUID(), ownerId: UUID(), label: "Home", line1: "  ",
                               line2: nil, landmark: nil, accessNotes: nil, latitude: 0, longitude: 0, clusterArea: nil)

        await #expect(throws: DomainError.self) {
            _ = try await useCase.add(address)
        }
    }

    @Test("matches a served cluster on add, and reports uncovered outside one")
    func matchesClusterOnAdd() async throws {
        let repo = MockAddressRepository()
        let useCase = ManageAddressesUseCase(addressRepository: repo)

        let served = Address(id: UUID(), ownerId: UUID(), label: "Home", line1: "14, 5th Cross",
                              line2: nil, landmark: nil, accessNotes: nil, latitude: 12.9352, longitude: 77.6146, clusterArea: nil)
        let saved = try await useCase.add(served)
        #expect(saved.isServed)
        #expect(saved.clusterArea == "Koramangala 5th Block")

        let uncovered = Address(id: UUID(), ownerId: UUID(), label: "Farmhouse", line1: "Middle of nowhere",
                                 line2: nil, landmark: nil, accessNotes: nil, latitude: 30.0, longitude: 70.0, clusterArea: nil)
        let savedUncovered = try await useCase.add(uncovered)
        #expect(!savedUncovered.isServed)
    }

    @Test("the first address added for an owner becomes their default")
    func firstAddressBecomesDefault() async throws {
        let repo = MockAddressRepository()
        let useCase = ManageAddressesUseCase(addressRepository: repo)
        let ownerId = UUID()
        let address = Address(id: UUID(), ownerId: ownerId, label: "Home", line1: "Line 1",
                               line2: nil, landmark: nil, accessNotes: nil, latitude: 12.9352, longitude: 77.6146, clusterArea: nil)
        let saved = try await useCase.add(address)
        #expect(saved.isDefault)
    }
}

@Suite("GetCatalogUseCase")
struct GetCatalogUseCaseTests {
    @Test("filters services to the requested vertical")
    func filtersByVertical() async throws {
        let repo = MockCatalogRepository()
        let useCase = GetCatalogUseCase(catalogRepository: repo)

        let vetServices = try await useCase.execute(vertical: .vet)
        #expect(!vetServices.isEmpty)
        #expect(vetServices.allSatisfy { $0.category.vertical == .vet })

        let physioServices = try await useCase.execute(vertical: .physio)
        #expect(physioServices.allSatisfy { $0.category.vertical == .physio })
    }

    @Test("excludes services a pet's species is ineligible for")
    func filtersBySpeciesEligibility() async throws {
        let repo = MockCatalogRepository()
        let useCase = GetCatalogUseCase(catalogRepository: repo)
        let dogOnly = Service(
            id: UUID(), category: .dental, name: "Dog dental",
            summary: "", variants: [ServiceVariant(id: UUID(), serviceId: UUID(), name: "Standard", durationMinutes: 20, priceMinorUnits: 100)],
            eligibility: ServiceEligibility(species: [.dog])
        )
        await repo.seed([dogOnly])

        let forCats = try await useCase.execute(vertical: .vet, forSpecies: .cat)
        #expect(forCats.isEmpty)

        let forDogs = try await useCase.execute(vertical: .vet, forSpecies: .dog)
        #expect(forDogs.contains { $0.id == dogOnly.id })
    }

    @Test("a service with no species restriction is eligible for every species")
    func unrestrictedServiceIsUniversallyEligible() {
        let eligibility = ServiceEligibility()
        for species in Pet.Species.allCases {
            #expect(eligibility.allows(species: species))
        }
    }
}
