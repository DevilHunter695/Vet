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
