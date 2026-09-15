import Testing
import Foundation
@testable import VetCircuit

// K1 (structured visit record), I7 (in-visit checklist) and N4 (loyalty
// tiers) — three read-side features with no prior test coverage at all.

// MARK: - K1: structured visit record vs. the legacy `notes` blob.

private func makeRecordVisit(
    notes: String? = nil,
    diagnosisNotes: String? = nil,
    proceduresPerformed: [String] = [],
    medicationsGiven: [String] = []
) -> Visit {
    Visit(id: UUID(), userId: UUID(), petId: UUID(), vetId: UUID(), circuitId: UUID(),
          status: .completed, scheduledAt: .now.addingTimeInterval(-3_600),
          completedAt: .now, notes: notes, paymentId: nil,
          diagnosisNotes: diagnosisNotes,
          proceduresPerformed: proceduresPerformed,
          medicationsGiven: medicationsGiven)
}

@Suite("Visit.hasStructuredRecord (K1)")
struct VisitStructuredRecordTests {
    @Test("a visit with nothing recorded has no structured record")
    func emptyVisitHasNone() {
        #expect(!makeRecordVisit().hasStructuredRecord)
    }

    @Test("legacy free-text notes alone are not a structured record")
    func legacyNotesAreNotStructured() {
        let visit = makeRecordVisit(notes: "Seemed fine, advised rest and a follow-up in a week.")
        #expect(!visit.hasStructuredRecord, "the UI must still fall back to the legacy notes blob here")
        #expect(visit.notes?.isEmpty == false)
    }

    @Test("diagnosis notes alone make it a structured record")
    func diagnosisAloneQualifies() {
        #expect(makeRecordVisit(diagnosisNotes: "Otitis externa, left ear").hasStructuredRecord)
    }

    @Test("a procedure alone makes it a structured record")
    func procedureAloneQualifies() {
        #expect(makeRecordVisit(proceduresPerformed: ["Ear flush"]).hasStructuredRecord)
    }

    @Test("a medication alone makes it a structured record")
    func medicationAloneQualifies() {
        #expect(makeRecordVisit(medicationsGiven: ["Meloxicam 1.5mg/ml"]).hasStructuredRecord)
    }

    @Test("an empty diagnosis string does not count as a record, but a non-empty one does")
    func emptyDiagnosisStringDoesNotQualify() {
        #expect(!makeRecordVisit(diagnosisNotes: "").hasStructuredRecord)
        #expect(makeRecordVisit(diagnosisNotes: "Otitis externa").hasStructuredRecord)
    }

    @Test("structured fields win even when legacy notes are also present")
    func structuredWinsOverLegacyNotes() {
        let visit = makeRecordVisit(notes: "Old free-text blob",
                                    diagnosisNotes: "Otitis externa, left ear",
                                    proceduresPerformed: ["Ear flush"],
                                    medicationsGiven: ["Meloxicam"])
        #expect(visit.hasStructuredRecord)
        #expect(visit.proceduresPerformed == ["Ear flush"])
        #expect(visit.medicationsGiven == ["Meloxicam"])
    }
}

// MARK: - I7: in-visit checklist ordering and scoping.
//
// `MockVisitChecklistRepository` fabricates the same five contiguous,
// already-sorted items for *any* visit id, so it can prove neither that the
// use case sorts nor that it scopes. This double supplies deliberately
// unsorted, non-contiguous, duplicate-order rows across two visits.
actor FakeVisitChecklistRepository: VisitChecklistRepository {
    private let seeded: [VisitChecklistItem]
    init(_ seeded: [VisitChecklistItem]) { self.seeded = seeded }

    func items(visitId: UUID) async throws -> [VisitChecklistItem] {
        seeded.filter { $0.visitId == visitId }
    }
}

private func makeChecklistItem(visitId: UUID, label: String, sortOrder: Int) -> VisitChecklistItem {
    VisitChecklistItem(id: UUID(), visitId: visitId, label: label, isCompleted: true,
                       note: nil, completedAt: nil, sortOrder: sortOrder)
}

@Suite("GetVisitChecklistUseCase (I7)")
struct GetVisitChecklistUseCaseTests {
    @Test("items are returned in ascending sortOrder even when stored shuffled and non-contiguous")
    func sortsAscendingWithGaps() async throws {
        let visitId = UUID()
        let third = makeChecklistItem(visitId: visitId, label: "Owner questions answered", sortOrder: 90)
        let first = makeChecklistItem(visitId: visitId, label: "Temperature & vitals", sortOrder: 5)
        let second = makeChecklistItem(visitId: visitId, label: "Physical examination", sortOrder: 40)
        let useCase = GetVisitChecklistUseCase(repository: FakeVisitChecklistRepository([third, second, first]))

        let items = try await useCase.execute(visitId: visitId)
        #expect(items.map(\.sortOrder) == [5, 40, 90])
        #expect(items.map(\.id) == [first.id, second.id, third.id])
    }

    @Test("duplicate sortOrders are all retained, and the ordering stays non-decreasing")
    func duplicateOrdersRetained() async throws {
        let visitId = UUID()
        let last = makeChecklistItem(visitId: visitId, label: "Wrap-up", sortOrder: 30)
        let tiedA = makeChecklistItem(visitId: visitId, label: "Weight recorded", sortOrder: 10)
        let tiedB = makeChecklistItem(visitId: visitId, label: "Temperature recorded", sortOrder: 10)
        let useCase = GetVisitChecklistUseCase(repository: FakeVisitChecklistRepository([last, tiedA, tiedB]))

        let items = try await useCase.execute(visitId: visitId)
        // Nothing may be dropped or collapsed by the sort.
        #expect(items.count == 3)
        #expect(Set(items.map(\.id)) == Set([tiedA.id, tiedB.id, last.id]))
        // `sorted(by:)` is not a stable sort, so the two tied rows may come
        // back in either relative order — but both must precede sortOrder 30.
        #expect(items.map(\.sortOrder) == [10, 10, 30])
        #expect(items.last?.id == last.id)
        #expect(zip(items, items.dropFirst()).allSatisfy { $0.0.sortOrder <= $0.1.sortOrder })
    }

    @Test("only the requested visit's items are returned")
    func scopedToTheRequestedVisit() async throws {
        let mine = UUID(), theirs = UUID()
        let mineFirst = makeChecklistItem(visitId: mine, label: "Vitals", sortOrder: 1)
        let mineSecond = makeChecklistItem(visitId: mine, label: "Vaccination reviewed", sortOrder: 2)
        // Deliberately the lowest sortOrder in the whole store: an unscoped
        // implementation would sort it to the very top of this visit's list.
        let otherVisitItem = makeChecklistItem(visitId: theirs, label: "Another visit's step", sortOrder: 0)
        let useCase = GetVisitChecklistUseCase(repository: FakeVisitChecklistRepository([otherVisitItem, mineSecond, mineFirst]))

        let items = try await useCase.execute(visitId: mine)
        #expect(items.map(\.id) == [mineFirst.id, mineSecond.id])
        #expect(!items.contains { $0.id == otherVisitItem.id })
        #expect(items.allSatisfy { $0.visitId == mine })

        // The other visit's checklist is intact — scoped, not emptied.
        let theirItems = try await useCase.execute(visitId: theirs)
        #expect(theirItems.map(\.id) == [otherVisitItem.id])
    }

    @Test("a visit with no checklist yields an empty list while a seeded visit's is unaffected")
    func unknownVisitIsEmpty() async throws {
        let seededVisit = UUID()
        let useCase = GetVisitChecklistUseCase(
            repository: FakeVisitChecklistRepository([makeChecklistItem(visitId: seededVisit, label: "Vitals", sortOrder: 1)])
        )
        let empty = try await useCase.execute(visitId: UUID())
        let seeded = try await useCase.execute(visitId: seededVisit)
        #expect(empty.isEmpty)
        #expect(seeded.count == 1)
    }
}

// MARK: - N4: loyalty tier thresholds.

@Suite("LoyaltyAccount.Tier.forPoints (N4)")
struct LoyaltyTierBoundaryTests {
    @Test("zero points is bronze")
    func zeroIsBronze() {
        #expect(LoyaltyAccount.Tier.forPoints(0) == .bronze)
    }

    @Test("a negative balance is still bronze, never a higher tier")
    func negativeIsBronze() {
        #expect(LoyaltyAccount.Tier.forPoints(-1) == .bronze)
        #expect(LoyaltyAccount.Tier.forPoints(-10_000) == .bronze)
    }

    @Test("199 points is the last bronze value and 200 is the first silver value")
    func bronzeSilverBoundary() {
        #expect(LoyaltyAccount.Tier.forPoints(199) == .bronze)
        #expect(LoyaltyAccount.Tier.forPoints(200) == .silver)
    }

    @Test("599 points is the last silver value and 600 is the first gold value")
    func silverGoldBoundary() {
        #expect(LoyaltyAccount.Tier.forPoints(599) == .silver)
        #expect(LoyaltyAccount.Tier.forPoints(600) == .gold)
    }

    @Test("mid-band values land in the band they belong to")
    func midBandValues() {
        #expect(LoyaltyAccount.Tier.forPoints(100) == .bronze)
        #expect(LoyaltyAccount.Tier.forPoints(400) == .silver)
        #expect(LoyaltyAccount.Tier.forPoints(5_000) == .gold)
    }

    @Test("tiers never go backwards as points increase")
    func tiersAreMonotonic() {
        let rank: [LoyaltyAccount.Tier: Int] = [.bronze: 0, .silver: 1, .gold: 2]
        let ranks = stride(from: 0, through: 1_000, by: 1).map { rank[LoyaltyAccount.Tier.forPoints($0)]! }
        #expect(zip(ranks, ranks.dropFirst()).allSatisfy { $0.0 <= $0.1 })
        #expect(ranks.first == 0)
        #expect(ranks.last == 2)
    }
}

// MARK: - D3: add-on eligibility.
//
// `Addon.eligibility` existed as data and was read by no code anywhere, so a
// dog-only add-on could be attached to a cat's booking and priced into the
// quote. The gate that now enforces it is only active when
// `ManageCartUseCase` is built with a catalog and pet repository — they are
// optional with `nil` defaults so existing call sites still compile, which
// means dropping the wiring in `DependencyContainer` would silently disable
// the whole check again. `wiringIsWhatMakesTheGateRun` below is the test that
// fails if that happens.

private actor StubCatalogRepository: CatalogRepository {
    private let services: [Service]
    init(services: [Service]) { self.services = services }

    func listServices(vertical: Vertical?) async throws -> [Service] { services }

    func service(id: UUID) async throws -> Service {
        guard let match = services.first(where: { $0.id == id }) else {
            throw DomainError.notFound("Service")
        }
        return match
    }
}

private actor StubPetRepository: PetRepository {
    private var pets: [Pet]
    init(pets: [Pet]) { self.pets = pets }

    func listPets(ownerId: UUID) async throws -> [Pet] { pets.filter { $0.ownerId == ownerId } }
    func addPet(_ pet: Pet) async throws -> Pet { pets.append(pet); return pet }
    func updatePet(_ pet: Pet) async throws -> Pet { pet }
    func deletePet(id: UUID) async throws {}
    func updatePhoto(petId: UUID, data: Data) async throws -> Pet {
        guard let match = pets.first(where: { $0.id == petId }) else { throw DomainError.notFound("Pet") }
        return match
    }
}

@Suite("D3 add-on eligibility")
struct AddonEligibilityTests {

    /// Owner with one dog and one cat; a service whose only add-on is dog-only.
    private struct Fixture {
        let ownerId: UUID
        let dog: Pet
        let cat: Pet
        let service: Service
        let dogOnlyAddon: Addon
        let variantId: UUID

        init() {
            // Bound locally first: a struct initialiser may not read `self`
            // until every stored property is assigned.
            let ownerId = UUID()
            self.ownerId = ownerId
            dog = Pet(id: UUID(), ownerId: ownerId, name: "Bruno", species: .dog, breed: nil, dateOfBirth: nil)
            cat = Pet(id: UUID(), ownerId: ownerId, name: "Misty", species: .cat, breed: nil, dateOfBirth: nil)

            let serviceId = UUID()
            let variantId = UUID()
            self.variantId = variantId
            let addon = Addon(
                id: UUID(), name: "Nail trim", priceMinorUnits: 15_000,
                eligibility: ServiceEligibility(species: [.dog])
            )
            self.dogOnlyAddon = addon
            self.service = Service(
                id: serviceId, category: .grooming, name: "Grooming", summary: "",
                whatToPrepare: nil,
                variants: [ServiceVariant(id: variantId, serviceId: serviceId, name: "Standard",
                                          durationMinutes: 30, priceMinorUnits: 80_000)],
                addons: [addon]
            )
        }

        func line(for pet: Pet) -> CartItem {
            CartItem(id: UUID(), serviceId: service.id, variantId: variantId,
                     petIds: [pet.id], addonIds: [dogOnlyAddon.id])
        }

        func wiredUseCase(_ cartRepository: CartRepository) -> ManageCartUseCase {
            ManageCartUseCase(
                cartRepository: cartRepository,
                catalogRepository: StubCatalogRepository(services: [service]),
                petRepository: StubPetRepository(pets: [dog, cat])
            )
        }
    }

    @Test("a dog-only add-on is rejected for a cat")
    func rejectsIneligibleSpecies() async throws {
        let fixture = Fixture()
        let cartRepository = MockCartRepository()
        let useCase = fixture.wiredUseCase(cartRepository)
        let cart = Cart(id: UUID(), userId: fixture.ownerId)

        await #expect(throws: DomainError.self) {
            _ = try await useCase.addItem(fixture.line(for: fixture.cat), to: cart)
        }

        // Discriminating: the line must not have been saved either. A gate
        // that throws after persisting is not a gate.
        let saved = try await cartRepository.currentCart(userId: fixture.ownerId)
        #expect(saved.items.isEmpty)
    }

    @Test("the same add-on is accepted for an eligible dog")
    func acceptsEligibleSpecies() async throws {
        let fixture = Fixture()
        let useCase = fixture.wiredUseCase(MockCartRepository())
        let cart = Cart(id: UUID(), userId: fixture.ownerId)

        let updated = try await useCase.addItem(fixture.line(for: fixture.dog), to: cart)

        // The positive case matters as much as the negative one: a gate that
        // rejects everything would pass the test above on its own.
        #expect(updated.items.count == 1)
        #expect(updated.items.first?.addonIds == [fixture.dogOnlyAddon.id])
    }

    @Test("wiring is what makes the gate run — unwired, the cat's booking sails through")
    func wiringIsWhatMakesTheGateRun() async throws {
        let fixture = Fixture()
        // Exactly how `ManageCartUseCase` is constructed everywhere that
        // hasn't been wired: no catalog, no pets. This documents that the
        // default is permissive, so if `DependencyContainer` ever stops
        // passing the repositories the failure is understood rather than
        // mysterious.
        let unwired = ManageCartUseCase(cartRepository: MockCartRepository())
        let cart = Cart(id: UUID(), userId: fixture.ownerId)

        let updated = try await unwired.addItem(fixture.line(for: fixture.cat), to: cart)
        #expect(updated.items.count == 1)
    }
}

// MARK: - D2: minimum pet age.

@Suite("D2 minimum pet age eligibility")
struct MinimumPetAgeTests {

    private func pet(ageMonths: Int?) -> Pet {
        let dob = ageMonths.map { Calendar.current.date(byAdding: .month, value: -$0, to: .now)! }
        return Pet(id: UUID(), ownerId: UUID(), name: "Test", species: .dog, breed: nil, dateOfBirth: dob)
    }

    @Test("a service with a minimum age excludes a pet below it")
    func excludesTooYoung() {
        let eligibility = ServiceEligibility(minPetAgeMonths: 6)
        #expect(!eligibility.allows(pet: pet(ageMonths: 0)))
        #expect(!eligibility.allows(pet: pet(ageMonths: 5)))
    }

    @Test("a pet at or above the minimum is allowed")
    func allowsOldEnough() {
        let eligibility = ServiceEligibility(minPetAgeMonths: 6)
        #expect(eligibility.allows(pet: pet(ageMonths: 6)))
        #expect(eligibility.allows(pet: pet(ageMonths: 12)))
    }

    @Test("unknown date of birth passes the age gate rather than hiding the service")
    func unknownAgePasses() {
        // Deliberate product choice: an owner who hasn't filled in a birthday
        // should still see what they can book. The vet checks age in person.
        #expect(ServiceEligibility(minPetAgeMonths: 6).allows(pet: pet(ageMonths: nil)))
    }

    @Test("species and age gates compose — both must pass")
    func speciesAndAgeCompose() {
        let eligibility = ServiceEligibility(species: [.dog], minPetAgeMonths: 6)
        let youngDog = pet(ageMonths: 2)
        var oldCat = pet(ageMonths: 24); oldCat.species = .cat
        var oldDog = pet(ageMonths: 24)
        oldDog.species = .dog

        #expect(!eligibility.allows(pet: youngDog))   // right species, too young
        #expect(!eligibility.allows(pet: oldCat))     // old enough, wrong species
        #expect(eligibility.allows(pet: oldDog))      // both pass
    }
}
