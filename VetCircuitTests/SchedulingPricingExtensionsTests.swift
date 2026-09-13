import Testing
import Foundation
@testable import VetCircuit

// D5, F5, F6, F7 — pure-domain tests for the scheduling/pricing extensions.

@Suite("PricingEngine vet override (D5)")
struct PricingEngineOverrideTests {
    @Test("uses the catalog price when no override is present")
    func noOverride() {
        let variant = ServiceVariant(id: UUID(), serviceId: UUID(), name: "Standard", durationMinutes: 20, priceMinorUnits: 50_000)
        let breakdown = PricingEngine.quote(.init(variant: variant, addons: [], additionalPetCount: 0, travelFeeMinorUnits: 0, gstRate: 0))
        #expect(breakdown.totalMinorUnits == 50_000)
    }

    @Test("a vet's override price replaces the catalog price")
    func withOverride() {
        let variant = ServiceVariant(id: UUID(), serviceId: UUID(), name: "Standard", durationMinutes: 20, priceMinorUnits: 50_000)
        let breakdown = PricingEngine.quote(.init(variant: variant, addons: [], additionalPetCount: 0, travelFeeMinorUnits: 0, gstRate: 0, vetOverridePriceMinorUnits: 40_000))
        #expect(breakdown.totalMinorUnits == 40_000)
    }
}

@Suite("MockQuoteRepository override resolution (D5)")
struct QuoteOverrideResolutionTests {
    @Test("an override for the specific variant is applied over the catalog default")
    func appliesVariantOverride() async throws {
        let vetId = UUID(), serviceId = UUID(), variantId = UUID()
        let variant = ServiceVariant(id: variantId, serviceId: serviceId, name: "Standard", durationMinutes: 20, priceMinorUnits: 50_000)
        let service = Service(id: serviceId, category: .consult, name: "Consult", summary: "", whatToPrepare: nil, variants: [variant])
        let cart = Cart(id: UUID(), userId: UUID(), addressId: nil, circuitId: UUID(), slotId: nil,
                         items: [CartItem(id: UUID(), serviceId: serviceId, variantId: variantId, petIds: [UUID()])])
        let override = VetServiceOverride(id: UUID(), vetId: vetId, serviceId: serviceId, variantId: variantId, priceOverrideMinorUnits: 30_000, isOffered: true)

        let repo = MockQuoteRepository(couponRepository: MockCouponRepository(), walletRepository: MockWalletRepository())
        let quote = try await repo.createQuote(for: cart, catalog: [service], overrides: [override], useWalletBalance: false, applyEntitlementCredit: false)
        #expect(quote.breakdown.lineItems.first?.amountMinorUnits == 30_000)
    }
}

@Suite("RecurrenceScheduler (F5)")
struct RecurrenceSchedulerTests {
    @Test("weekly advances by exactly 7 days")
    func weekly() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let last = calendar.date(from: DateComponents(year: 2026, month: 1, day: 5))!
        let next = RecurrenceScheduler.nextOccurrence(after: last, cadence: .weekly, calendar: calendar)
        #expect(calendar.dateComponents([.day], from: last, to: next).day == 7)
    }

    @Test("monthly lands on the same day-of-month next month")
    func monthly() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let last = calendar.date(from: DateComponents(year: 2026, month: 1, day: 15))!
        let next = RecurrenceScheduler.nextOccurrence(after: last, cadence: .monthly, calendar: calendar)
        let comps = calendar.dateComponents([.year, .month, .day], from: next)
        #expect(comps.year == 2026 && comps.month == 2 && comps.day == 15)
    }
}

@Suite("ManageRecurringBookingUseCase (F5)")
struct ManageRecurringBookingUseCaseTests {
    @Test("create, pause, and cancel a rule")
    func lifecycle() async throws {
        let repo = MockRecurringBookingRuleRepository()
        let useCase = ManageRecurringBookingUseCase(recurringBookingRuleRepository: repo)
        let userId = UUID()
        let rule = try await useCase.execute(userId: userId, petId: UUID(), serviceId: UUID(), variantId: UUID(),
                                              circuitId: UUID(), cadence: .monthly, firstOccurrenceAt: .now.addingTimeInterval(86_400))
        #expect(rule.isActive)

        let paused = try await useCase.setActive(id: rule.id, isActive: false)
        #expect(paused.isActive == false)

        try await useCase.cancel(id: rule.id)
        let remaining = try await useCase.list(userId: userId)
        #expect(remaining.isEmpty)
    }
}

@Suite("RespondToRescheduleProposalUseCase (F6)")
struct RespondToRescheduleProposalUseCaseTests {
    @Test("accepting a vet-initiated proposal reschedules the visit even inside the 4h window")
    func acceptReschedules() async throws {
        let visitRepo = MockVisitRepository()
        let circuitRepo = MockCircuitRepository()
        let circuit = MockData.circuits[0]
        let slot = circuit.schedule.first { $0.isAvailable }!
        let visit = try await visitRepo.createVisit(petId: UUID(), vetId: circuit.vetId, circuitId: circuit.id, slot: slot, idempotencyKey: UUID().uuidString)

        // The visit's own slot is inside the 4h window relative to "now" in this test,
        // which is exactly the case a customer-initiated reschedule would reject.
        let newSlot = circuit.schedule.first { $0.id != slot.id && $0.isAvailable } ?? slot
        let proposal = RescheduleProposal(id: UUID(), visitId: visit.id, proposedByRole: .vet,
                                           proposedSlotId: newSlot.id, status: .pending, createdAt: .now)
        let proposalRepo = MockRescheduleProposalRepository()
        _ = try await proposalRepo.create(proposal)
        let loyaltyRepo = MockLoyaltyRepository()

        let useCase = RespondToRescheduleProposalUseCase(proposalRepository: proposalRepo, visitRepository: visitRepo,
                                                           circuitRepository: circuitRepo, loyaltyRepository: loyaltyRepo)
        let updated = try await useCase.execute(proposal: proposal, visit: visit, accept: true)
        #expect(updated.status == .accepted)

        let rescheduled = try await visitRepo.visit(id: visit.id)
        #expect(rescheduled.scheduledAt == newSlot.startTime)
    }

    @Test("declining awards a goodwill loyalty credit")
    func declineAwardsCredit() async throws {
        let visitRepo = MockVisitRepository()
        let circuitRepo = MockCircuitRepository()
        let circuit = MockData.circuits[0]
        let slot = circuit.schedule.first { $0.isAvailable }!
        let visit = try await visitRepo.createVisit(petId: UUID(), vetId: circuit.vetId, circuitId: circuit.id, slot: slot, idempotencyKey: UUID().uuidString)

        let proposal = RescheduleProposal(id: UUID(), visitId: visit.id, proposedByRole: .vet,
                                           proposedSlotId: slot.id, status: .pending, createdAt: .now)
        let proposalRepo = MockRescheduleProposalRepository()
        _ = try await proposalRepo.create(proposal)
        let loyaltyRepo = MockLoyaltyRepository()
        let before = try await loyaltyRepo.account(userId: visit.userId)

        let useCase = RespondToRescheduleProposalUseCase(proposalRepository: proposalRepo, visitRepository: visitRepo,
                                                           circuitRepository: circuitRepo, loyaltyRepository: loyaltyRepo)
        let updated = try await useCase.execute(proposal: proposal, visit: visit, accept: false)
        #expect(updated.status == .declined)

        let after = try await loyaltyRepo.account(userId: visit.userId)
        #expect(after.points == before.points + NoShowPolicy.goodwillCreditPoints)
    }
}

@Suite("NoShowPolicy (F7)")
struct NoShowPolicyTests {
    @Test("customer no-show forfeits the full amount")
    func customerNoShow() {
        let outcome = NoShowPolicy.customerNoShow(paidMinorUnits: 100_000)
        #expect(outcome.refundPercent == 0)
        #expect(outcome.refundMinorUnits == 0)
        #expect(outcome.goodwillCreditPoints == 0)
    }

    @Test("vet no-show refunds in full and adds a goodwill credit")
    func vetNoShow() {
        let outcome = NoShowPolicy.vetNoShow(paidMinorUnits: 100_000)
        #expect(outcome.refundPercent == 100)
        #expect(outcome.refundMinorUnits == 100_000)
        #expect(outcome.goodwillCreditPoints == NoShowPolicy.goodwillCreditPoints)
    }
}

@Suite("Visit.legalTransitions noShowVet (F7)")
struct NoShowVetTransitionTests {
    @Test("assigned -> noShowVet is legal")
    func fromAssigned() {
        #expect(Visit.canTransition(from: .assigned, to: .noShowVet))
    }

    @Test("enRoute -> noShowVet is legal")
    func fromEnRoute() {
        #expect(Visit.canTransition(from: .enRoute, to: .noShowVet))
    }

    @Test("noShowVet is terminal")
    func terminal() {
        #expect(Visit.VisitStatus.noShowVet.isTerminal)
    }
}

@Suite("ReportVetNoShowUseCase (F7)")
struct ReportVetNoShowUseCaseTests {
    @Test("rejects reporting before the grace window has elapsed")
    func tooEarly() async {
        let visitRepo = MockVisitRepository()
        let refundRepo = MockRefundRepository()
        let loyaltyRepo = MockLoyaltyRepository()
        let useCase = ReportVetNoShowUseCase(visitRepository: visitRepo, refundRepository: refundRepo, loyaltyRepository: loyaltyRepo)
        let visit = Visit(id: UUID(), userId: UUID(), petId: UUID(), vetId: UUID(), circuitId: UUID(),
                           status: .assigned, scheduledAt: .now.addingTimeInterval(-60), completedAt: nil, notes: nil, paymentId: UUID())

        await #expect(throws: DomainError.self) {
            _ = try await useCase.execute(visit: visit)
        }
    }

    @Test("rejects a visit in a status not eligible for a vet no-show report")
    func wrongStatus() async {
        let visitRepo = MockVisitRepository()
        let refundRepo = MockRefundRepository()
        let loyaltyRepo = MockLoyaltyRepository()
        let useCase = ReportVetNoShowUseCase(visitRepository: visitRepo, refundRepository: refundRepo, loyaltyRepository: loyaltyRepo)
        let visit = Visit(id: UUID(), userId: UUID(), petId: UUID(), vetId: UUID(), circuitId: UUID(),
                           status: .requested, scheduledAt: .now.addingTimeInterval(-3600), completedAt: nil, notes: nil, paymentId: UUID())

        await #expect(throws: DomainError.self) {
            _ = try await useCase.execute(visit: visit)
        }
    }
}
