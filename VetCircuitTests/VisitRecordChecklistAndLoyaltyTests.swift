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
