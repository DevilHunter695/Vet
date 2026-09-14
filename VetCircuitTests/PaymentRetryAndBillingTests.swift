import Testing
import Foundation
@testable import VetCircuit

// G3: payment retry policy + use case.

@Suite("PaymentRetryPolicy")
struct PaymentRetryPolicyTests {
    @Test("a succeeded payment is never offered a retry")
    func succeededNeverRetries() {
        let outcome = PaymentRetryPolicy.evaluate(status: .succeeded, priorAttempts: 0)
        #expect(!outcome.canRetry)
        #expect(outcome.reason == nil)
    }

    @Test("a failed payment under the attempt cap can retry")
    func failedUnderCapCanRetry() {
        let outcome = PaymentRetryPolicy.evaluate(status: .failed, priorAttempts: 1)
        #expect(outcome.canRetry)
        #expect(outcome.attemptsRemaining == PaymentRetryPolicy.maxAttempts - 1)
    }

    @Test("a failed payment at the attempt cap stops offering a retry, with a reason")
    func failedAtCapStops() {
        let outcome = PaymentRetryPolicy.evaluate(status: .failed, priorAttempts: PaymentRetryPolicy.maxAttempts)
        #expect(!outcome.canRetry)
        #expect(outcome.reason != nil)
    }
}

/// A payment repository test double whose status/checkout behavior is
/// configurable per test — `MockPaymentRepository` always reports
/// `.succeeded`, which can't exercise the retry path.
actor FakePaymentRepository: PaymentRepository {
    var status: Payment.Status
    private(set) var checkoutCallCount = 0

    init(status: Payment.Status) { self.status = status }

    func createCheckout(forVisit visitId: UUID, amountMinorUnits: Int) async throws -> URL {
        checkoutCallCount += 1
        return URL(string: "https://checkout.example.com/visit/\(visitId)")!
    }

    func createCheckout(forSubscription plan: Subscription.PlanType) async throws -> URL {
        URL(string: "https://checkout.example.com/subscription/\(plan.rawValue)")!
    }

    func paymentStatus(paymentId: UUID) async throws -> Payment.Status { status }

    func createTipCheckout(forVisit visitId: UUID, amountMinorUnits: Int) async throws -> URL {
        URL(string: "https://checkout.example.com/tip/\(visitId)")!
    }
}

@Suite("RetryPaymentUseCase")
struct RetryPaymentUseCaseTests {
    @Test("re-launches checkout when the payment failed and under the cap")
    func retriesWhenAllowed() async throws {
        let repo = FakePaymentRepository(status: .failed)
        let useCase = RetryPaymentUseCase(paymentRepository: repo)
        _ = try await useCase.execute(visitId: UUID(), paymentId: UUID(), amountMinorUnits: 50000, priorAttempts: 0)
        let calls = await repo.checkoutCallCount
        #expect(calls == 1)
    }

    @Test("refuses to retry a payment that already succeeded")
    func refusesWhenSucceeded() async {
        let repo = FakePaymentRepository(status: .succeeded)
        let useCase = RetryPaymentUseCase(paymentRepository: repo)
        await #expect(throws: DomainError.self) {
            _ = try await useCase.execute(visitId: UUID(), paymentId: UUID(), amountMinorUnits: 50000, priorAttempts: 0)
        }
    }

    @Test("refuses to retry once the attempt cap is reached")
    func refusesAtCap() async {
        let repo = FakePaymentRepository(status: .failed)
        let useCase = RetryPaymentUseCase(paymentRepository: repo)
        await #expect(throws: DomainError.self) {
            _ = try await useCase.execute(visitId: UUID(), paymentId: UUID(), amountMinorUnits: 50000, priorAttempts: PaymentRetryPolicy.maxAttempts)
        }
    }
}

// I2: visit status timeline.

@Suite("MockVisitRepository status history")
struct VisitStatusHistoryTests {
    @Test("records a real event for every status transition")
    func recordsRealTransitions() async throws {
        let repo = MockVisitRepository()
        let slot = ScheduleSlot(id: UUID(), dayOfWeek: 2, startTime: .now.addingTimeInterval(3600),
                                 endTime: .now.addingTimeInterval(7200), capacity: 3, bookedCount: 0)
        let visit = try await repo.createVisit(petId: UUID(), vetId: UUID(), circuitId: UUID(), slot: slot, idempotencyKey: UUID().uuidString)
        _ = try await repo.updateStatus(visitId: visit.id, status: .confirmed)
        _ = try await repo.updateStatus(visitId: visit.id, status: .assigned)

        let history = try await repo.statusHistory(visitId: visit.id)
        #expect(history.map(\.status) == [.requested, .confirmed, .assigned])
        #expect(zip(history, history.dropFirst()).allSatisfy { $0.occurredAt <= $1.occurredAt })
    }

    @Test("an unknown visit id yields an empty timeline rather than throwing")
    func unknownVisitIsEmpty() async throws {
        let repo = MockVisitRepository()
        let history = try await repo.statusHistory(visitId: UUID())
        #expect(history.isEmpty)
    }
}

// H1: plan catalog — inclusions & fair-use limits visible before purchase.

@Suite("PlanCatalogEntry")
struct PlanCatalogEntryTests {
    @Test("every individual plan lists at least one inclusion")
    func everyPlanHasInclusions() {
        for entry in PlanCatalogEntry.all {
            #expect(!entry.inclusions.isEmpty)
        }
    }

    @Test("fair-use summary reflects the real entitlement credit count")
    func fairUseMatchesEntitlementPolicy() {
        let monthly = PlanCatalogEntry.all.first { $0.planType == .monthly }!
        let credits = EntitlementPolicy.creditsGrantedPerPeriod(plan: .monthly, seatCount: 1)
        #expect(monthly.fairUseSummary.contains("\(credits)"))
    }
}

// H4: renewal reminders.

@Suite("RenewalReminderPolicy")
struct RenewalReminderPolicyTests {
    @Test("fires the 7-day reminder exactly at T-7")
    func sevenDayReminder() {
        let now = Date()
        let renewal = Calendar.current.date(byAdding: .day, value: 7, to: Calendar.current.startOfDay(for: now))!
        #expect(RenewalReminderPolicy.dueStage(renewalDate: renewal, now: now) == .sevenDaysBefore)
    }

    @Test("fires the 1-day reminder exactly at T-1")
    func oneDayReminder() {
        let now = Date()
        let renewal = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now))!
        #expect(RenewalReminderPolicy.dueStage(renewalDate: renewal, now: now) == .oneDayBefore)
    }

    @Test("no reminder on an unrelated day")
    func noReminderOtherDays() {
        let now = Date()
        let renewal = Calendar.current.date(byAdding: .day, value: 3, to: Calendar.current.startOfDay(for: now))!
        #expect(RenewalReminderPolicy.dueStage(renewalDate: renewal, now: now) == nil)
    }
}

// H5: dunning status use case — wiring on top of the already-pure DunningPolicy.

@Suite("DunningStatusUseCase")
struct DunningStatusUseCaseTests {
    @Test("first failure schedules a retry, not grace")
    func firstFailureSchedulesRetry() async throws {
        let repo = MockSubscriptionRepository()
        let sub = try await repo.subscribe(userId: UUID(), plan: .monthly)
        let useCase = DunningStatusUseCase(subscriptionRepository: repo)

        let outcome = try await useCase.recordFailure(subscriptionId: sub.id)
        guard case .retryScheduled = outcome else { Issue.record("expected retryScheduled"); return }
        let status = try await useCase.currentStatus(subscriptionId: sub.id)
        #expect(status?.failedAttempts == 1)
    }

    @Test("after the retry ladder is exhausted, grace starts")
    func ladderExhaustionStartsGrace() async throws {
        let repo = MockSubscriptionRepository()
        let sub = try await repo.subscribe(userId: UUID(), plan: .monthly)
        let useCase = DunningStatusUseCase(subscriptionRepository: repo)

        for _ in 0..<DunningPolicy.retryLadderDays.count { _ = try await useCase.recordFailure(subscriptionId: sub.id) }
        let outcome = try await useCase.recordFailure(subscriptionId: sub.id)
        guard case .graceStarted = outcome else { Issue.record("expected graceStarted"); return }
    }

    @Test("grace expiry downgrades the plan and clears dunning state")
    func graceExpiryDowngrades() async throws {
        let repo = MockSubscriptionRepository()
        let sub = try await repo.subscribe(userId: UUID(), plan: .annual)
        try await repo.recordDunningState(DunningState(subscriptionId: sub.id, failedAttempts: 4, nextRetryAt: nil, gracePeriodEndsAt: .now.addingTimeInterval(-3600)))
        let useCase = DunningStatusUseCase(subscriptionRepository: repo)

        let downgraded = try await useCase.resolveIfGraceExpired(subscriptionId: sub.id)
        #expect(downgraded)
        let updated = try await repo.currentSubscription(userId: sub.userId)
        #expect(updated?.planType == DunningPolicy.downgradeTarget)
    }

    @Test("does nothing while grace hasn't expired yet")
    func doesNothingBeforeGraceExpiry() async throws {
        let repo = MockSubscriptionRepository()
        let sub = try await repo.subscribe(userId: UUID(), plan: .annual)
        try await repo.recordDunningState(DunningState(subscriptionId: sub.id, failedAttempts: 4, nextRetryAt: nil, gracePeriodEndsAt: .now.addingTimeInterval(3600)))
        let useCase = DunningStatusUseCase(subscriptionRepository: repo)

        let downgraded = try await useCase.resolveIfGraceExpired(subscriptionId: sub.id)
        #expect(!downgraded)
    }
}
