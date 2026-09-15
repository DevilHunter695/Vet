import Testing
import Foundation
@testable import VetCircuit

// B6/B7: document vault + PDF health summary.

@Suite("ManagePetDocumentsUseCase")
struct ManagePetDocumentsUseCaseTests {
    @Test("rejects an empty title")
    func rejectsEmptyTitle() async {
        let repo = MockPetDocumentRepository()
        let useCase = ManagePetDocumentsUseCase(repository: repo)

        await #expect(throws: DomainError.self) {
            _ = try await useCase.upload(petId: UUID(), uploaderId: UUID(), title: "   ", data: Data([1, 2, 3]))
        }
    }

    @Test("rejects empty file data")
    func rejectsEmptyData() async {
        let repo = MockPetDocumentRepository()
        let useCase = ManagePetDocumentsUseCase(repository: repo)

        await #expect(throws: DomainError.self) {
            _ = try await useCase.upload(petId: UUID(), uploaderId: UUID(), title: "Insurance", data: Data())
        }
    }

    @Test("uploads and lists a document against the right pet, newest first")
    func uploadsAndListsNewestFirst() async throws {
        let repo = MockPetDocumentRepository()
        let useCase = ManagePetDocumentsUseCase(repository: repo)
        let petId = UUID()
        let uploaderId = UUID()

        let first = try await useCase.upload(petId: petId, uploaderId: uploaderId, title: "Old report", data: Data([1]))
        try await Task.sleep(nanoseconds: 2_000_000)
        let second = try await useCase.upload(petId: petId, uploaderId: uploaderId, title: "New report", data: Data([2]))
        // A document against a different pet should never leak into this list.
        _ = try await useCase.upload(petId: UUID(), uploaderId: uploaderId, title: "Other pet's doc", data: Data([3]))

        let documents = try await useCase.list(petId: petId)
        #expect(documents.count == 2)
        #expect(documents.first?.id == second.id)
        #expect(documents.last?.id == first.id)
    }

    @Test("a mock upload fabricates a placeholder URL rather than leaving it empty")
    func uploadFabricatesPlaceholderURL() async throws {
        let repo = MockPetDocumentRepository()
        let useCase = ManagePetDocumentsUseCase(repository: repo)

        let document = try await useCase.upload(petId: UUID(), uploaderId: UUID(), title: "Vaccine card", data: Data([1, 2, 3]))
        #expect(document.fileURL.absoluteString.contains("documents"))
    }

    @Test("delete removes the document from subsequent listings")
    func deleteRemovesDocument() async throws {
        let repo = MockPetDocumentRepository()
        let useCase = ManagePetDocumentsUseCase(repository: repo)
        let petId = UUID()

        let document = try await useCase.upload(petId: petId, uploaderId: UUID(), title: "Report", data: Data([1]))
        try await useCase.delete(id: document.id)
        let documents = try await useCase.list(petId: petId)
        #expect(documents.isEmpty)
    }
}

@Suite("GeneratePetHealthSummaryUseCase")
struct GeneratePetHealthSummaryUseCaseTests {
    private func makePet() -> Pet {
        Pet(id: UUID(), ownerId: UUID(), name: "Bruno", species: .dog, breed: "Labrador",
            dateOfBirth: Calendar.current.date(byAdding: .year, value: -3, to: .now),
            allergies: "Chicken", chronicConditions: "Mild arthritis")
    }

    @Test("renders non-empty PDF data with the PDF magic header")
    func rendersValidPDF() {
        let useCase = GeneratePetHealthSummaryUseCase()
        let pet = makePet()
        let weights = [PetWeightEntry(id: UUID(), petId: pet.id, weightKg: 24.5, recordedAt: .now)]
        let vaccinations = [Vaccination(id: UUID(), petId: pet.id, vaccineName: "Rabies", givenAt: .now,
                                         nextDueAt: Calendar.current.date(byAdding: .month, value: 12, to: .now) ?? .now,
                                         batchNumber: nil)]

        let data = useCase.execute(pet: pet, weightHistory: weights, vaccinations: vaccinations)

        #expect(!data.isEmpty)
        // "%PDF" magic header — proof this is a real PDF, not arbitrary bytes.
        let header = data.prefix(4)
        #expect(header == Data("%PDF".utf8))
    }

    @Test("still renders a valid PDF with no weight or vaccination history")
    func rendersWithEmptyHistory() {
        let useCase = GeneratePetHealthSummaryUseCase()
        let pet = makePet()

        let data = useCase.execute(pet: pet, weightHistory: [], vaccinations: [])

        #expect(!data.isEmpty)
        #expect(data.prefix(4) == Data("%PDF".utf8))
    }
}

// B3: weight & vitals (temperature/heart rate beyond just weight).

@Suite("ManagePetWeightsUseCase vitals")
struct ManagePetWeightsUseCaseVitalsTests {
    @Test("accepts a weight-only entry with no vitals")
    func acceptsWeightOnly() async throws {
        let useCase = ManagePetWeightsUseCase(repository: MockPetWeightRepository())
        let entry = try await useCase.addEntry(petId: UUID(), weightKg: 12.5)
        #expect(entry.temperatureCelsius == nil)
        #expect(entry.heartRateBpm == nil)
    }

    @Test("records temperature and heart rate when supplied")
    func recordsVitals() async throws {
        let useCase = ManagePetWeightsUseCase(repository: MockPetWeightRepository())
        let entry = try await useCase.addEntry(petId: UUID(), weightKg: 12.5, temperatureCelsius: 38.5, heartRateBpm: 90)
        #expect(entry.temperatureCelsius == 38.5)
        #expect(entry.heartRateBpm == 90)
    }

    @Test("rejects an implausible temperature")
    func rejectsImplausibleTemperature() async {
        let useCase = ManagePetWeightsUseCase(repository: MockPetWeightRepository())
        await #expect(throws: DomainError.self) {
            _ = try await useCase.addEntry(petId: UUID(), weightKg: 12.5, temperatureCelsius: 60)
        }
    }

    @Test("rejects an implausible heart rate")
    func rejectsImplausibleHeartRate() async {
        let useCase = ManagePetWeightsUseCase(repository: MockPetWeightRepository())
        await #expect(throws: DomainError.self) {
            _ = try await useCase.addEntry(petId: UUID(), weightKg: 12.5, heartRateBpm: 1000)
        }
    }
}

// MARK: - B3: weight/vitals history — the trend chart plots this list in the
// order it arrives, so ordering is load-bearing, not cosmetic.

@Suite("ManagePetWeightsUseCase history (B3)")
struct ManagePetWeightsUseCaseHistoryTests {
    @Test("history comes back oldest-first even when entries are logged out of order")
    func historyIsChronological() async throws {
        let useCase = ManagePetWeightsUseCase(repository: MockPetWeightRepository())
        let petId = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        // Logged newest-first on purpose — a backdated entry is the normal
        // case for an owner catching up on a home scale.
        let june = try await useCase.addEntry(petId: petId, weightKg: 12.0, recordedAt: now)
        let april = try await useCase.addEntry(petId: petId, weightKg: 10.0, recordedAt: now.addingTimeInterval(-86_400 * 60))
        let may = try await useCase.addEntry(petId: petId, weightKg: 11.0, recordedAt: now.addingTimeInterval(-86_400 * 30))

        let history = try await useCase.history(petId: petId)
        #expect(history.map(\.id) == [april.id, may.id, june.id])
        #expect(history.map(\.weightKg) == [10.0, 11.0, 12.0])
        // Non-decreasing timestamps, restated independently of the id order.
        #expect(zip(history, history.dropFirst()).allSatisfy { $0.0.recordedAt <= $0.1.recordedAt })
    }

    @Test("history is scoped to the requested pet — another pet's readings never appear")
    func historyIsScopedToThePet() async throws {
        let useCase = ManagePetWeightsUseCase(repository: MockPetWeightRepository())
        let bruno = UUID(), mittens = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let brunoEarly = try await useCase.addEntry(petId: bruno, weightKg: 28.0, recordedAt: now.addingTimeInterval(-86_400))
        let brunoLate = try await useCase.addEntry(petId: bruno, weightKg: 29.0, recordedAt: now)
        let mittensEntry = try await useCase.addEntry(petId: mittens, weightKg: 4.2, recordedAt: now)

        let brunoHistory = try await useCase.history(petId: bruno)
        // Both of Bruno's readings survive the filter...
        #expect(brunoHistory.map(\.id) == [brunoEarly.id, brunoLate.id])
        // ...and the cat's 4.2kg reading is specifically absent, rather than
        // the filter having thrown everything away.
        #expect(!brunoHistory.contains { $0.id == mittensEntry.id })
        #expect(brunoHistory.allSatisfy { $0.petId == bruno })

        let mittensHistory = try await useCase.history(petId: mittens)
        #expect(mittensHistory.map(\.id) == [mittensEntry.id])
    }

    @Test("a pet with nothing logged has an empty history while another pet's stays intact")
    func unknownPetHasNoHistory() async throws {
        let useCase = ManagePetWeightsUseCase(repository: MockPetWeightRepository())
        let known = UUID()
        _ = try await useCase.addEntry(petId: known, weightKg: 12.0)

        let unknownPetHistory = try await useCase.history(petId: UUID())
        let knownPetHistory = try await useCase.history(petId: known)
        #expect(unknownPetHistory.isEmpty)
        #expect(knownPetHistory.count == 1)
    }
}

// MARK: - B5: prescription history. `MockPrescriptionRepository` holds a
// private, empty array with no insert API, so a seedable double stands in for
// it — the code under test is `ManagePrescriptionsUseCase.history`'s
// scoping/sorting, not the mock's storage.

actor FakePrescriptionRepository: PrescriptionRepository {
    private let seeded: [Prescription]
    init(_ seeded: [Prescription]) { self.seeded = seeded }

    func history(petId: UUID) async throws -> [Prescription] {
        seeded.filter { $0.petId == petId }
    }
}

private func makePrescription(petId: UUID, medicationName: String, issuedAt: Date) -> Prescription {
    Prescription(id: UUID(), visitId: UUID(), petId: petId, medicationName: medicationName,
                 dosage: "1 tablet twice daily", instructions: nil,
                 prescribedByVetId: UUID(), issuedAt: issuedAt)
}

@Suite("ManagePrescriptionsUseCase history (B5)")
struct ManagePrescriptionsUseCaseHistoryTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("prescriptions come back newest-issued first, whatever order they were stored in")
    func newestIssuedFirst() async throws {
        let petId = UUID()
        let oldest = makePrescription(petId: petId, medicationName: "Amoxicillin", issuedAt: now.addingTimeInterval(-86_400 * 30))
        let middle = makePrescription(petId: petId, medicationName: "Meloxicam", issuedAt: now.addingTimeInterval(-86_400 * 7))
        let newest = makePrescription(petId: petId, medicationName: "Clavamox", issuedAt: now)
        let useCase = ManagePrescriptionsUseCase(repository: FakePrescriptionRepository([middle, newest, oldest]))

        let history = try await useCase.history(petId: petId)
        #expect(history.map(\.id) == [newest.id, middle.id, oldest.id])
        // The current medication must be the one the UI shows first — a stale
        // prescription at the top is a dosing hazard.
        #expect(history.first?.medicationName == "Clavamox")
        #expect(zip(history, history.dropFirst()).allSatisfy { $0.0.issuedAt >= $0.1.issuedAt })
    }

    @Test("history is scoped to the requested pet — another pet's medication never leaks in")
    func scopedToRequestedPet() async throws {
        let bruno = UUID(), mittens = UUID()
        let brunoNewest = makePrescription(petId: bruno, medicationName: "Clavamox", issuedAt: now)
        let brunoOlder = makePrescription(petId: bruno, medicationName: "Amoxicillin", issuedAt: now.addingTimeInterval(-86_400 * 10))
        // A cat's dose of a drug that is toxic at canine strength is exactly
        // the cross-pet leak this assertion exists to catch.
        let mittensNewer = makePrescription(petId: mittens, medicationName: "Methimazole", issuedAt: now.addingTimeInterval(86_400))
        let useCase = ManagePrescriptionsUseCase(repository: FakePrescriptionRepository([brunoOlder, mittensNewer, brunoNewest]))

        let history = try await useCase.history(petId: bruno)
        #expect(history.map(\.id) == [brunoNewest.id, brunoOlder.id])
        #expect(!history.contains { $0.id == mittensNewer.id })
        #expect(!history.contains { $0.medicationName == "Methimazole" })
        #expect(history.allSatisfy { $0.petId == bruno })

        // The other pet's own list is intact — the filter scopes, it doesn't empty.
        let mittensHistory = try await useCase.history(petId: mittens)
        #expect(mittensHistory.map(\.id) == [mittensNewer.id])
    }

    @Test("a pet with no prescriptions gets an empty list while a seeded pet's is unaffected")
    func petWithNoPrescriptions() async throws {
        let bruno = UUID()
        let useCase = ManagePrescriptionsUseCase(
            repository: FakePrescriptionRepository([makePrescription(petId: bruno, medicationName: "Clavamox", issuedAt: now)])
        )
        let unknownPetHistory = try await useCase.history(petId: UUID())
        let brunoHistory = try await useCase.history(petId: bruno)
        #expect(unknownPetHistory.isEmpty)
        #expect(brunoHistory.count == 1)
    }

    @Test("two prescriptions issued at the same instant are both retained")
    func sameInstantKeepsBoth() async throws {
        let petId = UUID()
        let a = makePrescription(petId: petId, medicationName: "Drug A", issuedAt: now)
        let b = makePrescription(petId: petId, medicationName: "Drug B", issuedAt: now)
        let useCase = ManagePrescriptionsUseCase(repository: FakePrescriptionRepository([a, b]))

        let history = try await useCase.history(petId: petId)
        #expect(history.count == 2)
        #expect(Set(history.map(\.id)) == Set([a.id, b.id]))
    }
}
