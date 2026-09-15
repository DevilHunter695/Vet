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
    private var paymentIdsByVisit: [UUID: UUID] = [:]

    init(status: Payment.Status) { self.status = status }

    func createCheckout(forVisit visitId: UUID, quoteId: UUID, amountMinorUnits: Int) async throws -> URL {
        checkoutCallCount += 1
        paymentIdsByVisit[visitId] = UUID()
        return URL(string: "https://checkout.example.com/visit/\(visitId)")!
    }

    func createCheckout(forVisit visitId: UUID, retryingPaymentId: UUID, amountMinorUnits: Int) async throws -> URL {
        checkoutCallCount += 1
        return URL(string: "https://checkout.example.com/visit/\(visitId)")!
    }

    func createCheckout(forSubscription plan: Subscription.PlanType, seatCount: Int) async throws -> URL {
        URL(string: "https://checkout.example.com/subscription/\(plan.rawValue)?seats=\(seatCount)")!
    }

    func paymentStatus(paymentId: UUID) async throws -> Payment.Status { status }

    func latestPaymentId(forVisit visitId: UUID) async throws -> UUID? { paymentIdsByVisit[visitId] }

    func createTipCheckout(forVisit visitId: UUID, amountMinorUnits: Int) async throws -> URL {
        URL(string: "https://checkout.example.com/tip/\(visitId)")!
    }

    func bookPayAfterVisit(forVisit visitId: UUID, quoteId: UUID, amountMinorUnits: Int) async throws -> UUID {
        let paymentId = UUID()
        paymentIdsByVisit[visitId] = paymentId
        status = .payAfterVisit
        return paymentId
    }

    func markPayAfterVisitCollected(paymentId: UUID) async throws -> Payment.Status {
        status = .succeeded
        return .succeeded
    }
}

private func makeTestQuote(expired: Bool = false) -> Quote {
    Quote(id: UUID(), cartId: UUID(),
          breakdown: PriceBreakdown(lineItems: [PriceLineItem(label: "Service", amountMinorUnits: 50000)], totalMinorUnits: 50000),
          signature: "test-signature",
          expiresAt: expired ? .now.addingTimeInterval(-60) : .now.addingTimeInterval(600))
}

@Suite("RetryPaymentUseCase")
struct RetryPaymentUseCaseTests {
    @Test("re-launches checkout when the payment failed and under the cap")
    func retriesWhenAllowed() async throws {
        let repo = FakePaymentRepository(status: .failed)
        let useCase = RetryPaymentUseCase(paymentRepository: repo)
        _ = try await useCase.execute(visitId: UUID(), paymentId: UUID(), quote: makeTestQuote(), priorAttempts: 0)
        let calls = await repo.checkoutCallCount
        #expect(calls == 1)
    }

    @Test("refuses to retry a payment that already succeeded")
    func refusesWhenSucceeded() async {
        let repo = FakePaymentRepository(status: .succeeded)
        let useCase = RetryPaymentUseCase(paymentRepository: repo)
        await #expect(throws: DomainError.self) {
            _ = try await useCase.execute(visitId: UUID(), paymentId: UUID(), quote: makeTestQuote(), priorAttempts: 0)
        }
    }

    @Test("refuses to retry once the attempt cap is reached")
    func refusesAtCap() async {
        let repo = FakePaymentRepository(status: .failed)
        let useCase = RetryPaymentUseCase(paymentRepository: repo)
        await #expect(throws: DomainError.self) {
            _ = try await useCase.execute(visitId: UUID(), paymentId: UUID(), quote: makeTestQuote(), priorAttempts: PaymentRetryPolicy.maxAttempts)
        }
    }

    @Test("refuses to retry with an expired quote even if the payment can otherwise retry")
    func refusesWithExpiredQuote() async {
        let repo = FakePaymentRepository(status: .failed)
        let useCase = RetryPaymentUseCase(paymentRepository: repo)
        await #expect(throws: DomainError.self) {
            _ = try await useCase.execute(visitId: UUID(), paymentId: UUID(), quote: makeTestQuote(expired: true), priorAttempts: 0)
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

// H7: corporate/RWA seat assignment.

@Suite("ManageCorporateSeatsUseCase")
struct ManageCorporateSeatsUseCaseTests {
    @Test("assigns seats up to the seat count, then refuses")
    func refusesOverCapacity() async throws {
        let repo = MockCorporateSeatAssignmentRepository()
        let useCase = ManageCorporateSeatsUseCase(repository: repo)
        let subscriptionId = UUID()

        _ = try await useCase.assign(subscriptionId: subscriptionId, phone: "+911111111111", seatCount: 1)
        await #expect(throws: DomainError.self) {
            _ = try await useCase.assign(subscriptionId: subscriptionId, phone: "+912222222222", seatCount: 1)
        }
    }

    @Test("unassigning frees the seat for reassignment")
    func unassignFreesSeat() async throws {
        let repo = MockCorporateSeatAssignmentRepository()
        let useCase = ManageCorporateSeatsUseCase(repository: repo)
        let subscriptionId = UUID()

        let assignment = try await useCase.assign(subscriptionId: subscriptionId, phone: "+911111111111", seatCount: 1)
        try await useCase.unassign(id: assignment.id)
        let second = try await useCase.assign(subscriptionId: subscriptionId, phone: "+912222222222", seatCount: 1)
        #expect(second.assignedPhone == "+912222222222")
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

// H4: RenewalReminderUseCase — the T-7/T-1 policy wired through the J8
// pipeline, deduped per subscription+stage+day so ProfileView's routine
// load doesn't refire the same reminder every time it runs that day.

private actor FakeRenewalReminderDedupeRepository: RenewalReminderDedupeRepository {
    private var sent: Set<String> = []

    private func key(_ subscriptionId: UUID, _ stage: RenewalReminderPolicy.Stage, _ day: Date) -> String {
        "\(subscriptionId)|\(stage)|\(Calendar.current.startOfDay(for: day))"
    }

    func hasSent(subscriptionId: UUID, stage: RenewalReminderPolicy.Stage, day: Date) async throws -> Bool {
        sent.contains(key(subscriptionId, stage, day))
    }

    func markSent(subscriptionId: UUID, stage: RenewalReminderPolicy.Stage, day: Date) async throws {
        sent.insert(key(subscriptionId, stage, day))
    }
}

@Suite("RenewalReminderUseCase")
struct RenewalReminderUseCaseTests {
    private func makeUseCase(smsRepo: MockSMSFallbackRepository, dedupe: FakeRenewalReminderDedupeRepository) -> RenewalReminderUseCase {
        RenewalReminderUseCase(
            sendTransactionalNotificationUseCase: SendTransactionalNotificationUseCase(
                pushTokenRepository: MockPushTokenRepository(),
                notificationPreferencesRepository: MockNotificationPreferencesRepository(),
                smsFallbackRepository: smsRepo
            ),
            dedupeRepository: dedupe
        )
    }

    @Test("sends the T-7 reminder through the notification pipeline")
    func sendsSevenDayReminder() async throws {
        let now = Date()
        let renewal = Calendar.current.date(byAdding: .day, value: 7, to: Calendar.current.startOfDay(for: now))!
        var user = MockData.user
        user.phone = "+919876543210"
        let subscription = Subscription(id: UUID(), userId: user.id, planType: .monthly, status: .active, renewalDate: renewal)
        let smsRepo = MockSMSFallbackRepository()
        let useCase = makeUseCase(smsRepo: smsRepo, dedupe: FakeRenewalReminderDedupeRepository())

        let stage = try await useCase.execute(user: user, subscription: subscription, now: now)

        #expect(stage == .sevenDaysBefore)
        let records = await smsRepo.sentRecords
        #expect(records.count == 1)
        #expect(records.first?.category == .subscriptionRenewalDue)
    }

    @Test("does not refire the same stage twice in one day")
    func dedupesWithinTheSameDay() async throws {
        let now = Date()
        let renewal = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now))!
        var user = MockData.user
        user.phone = "+919876543210"
        let subscription = Subscription(id: UUID(), userId: user.id, planType: .monthly, status: .active, renewalDate: renewal)
        let smsRepo = MockSMSFallbackRepository()
        let useCase = makeUseCase(smsRepo: smsRepo, dedupe: FakeRenewalReminderDedupeRepository())

        let first = try await useCase.execute(user: user, subscription: subscription, now: now)
        let second = try await useCase.execute(user: user, subscription: subscription, now: now.addingTimeInterval(120))

        #expect(first == .oneDayBefore)
        #expect(second == nil)
        let records = await smsRepo.sentRecords
        #expect(records.count == 1)
    }

    @Test("sends nothing for a cancelled subscription even on a reminder day")
    func skipsInactiveSubscription() async throws {
        let now = Date()
        let renewal = Calendar.current.date(byAdding: .day, value: 7, to: Calendar.current.startOfDay(for: now))!
        var user = MockData.user
        user.phone = "+919876543210"
        let subscription = Subscription(id: UUID(), userId: user.id, planType: .monthly, status: .cancelled, renewalDate: renewal)
        let smsRepo = MockSMSFallbackRepository()
        let useCase = makeUseCase(smsRepo: smsRepo, dedupe: FakeRenewalReminderDedupeRepository())

        let stage = try await useCase.execute(user: user, subscription: subscription, now: now)

        #expect(stage == nil)
        #expect(await smsRepo.sentRecords.isEmpty)
    }
}

// MARK: - G5: GST tax invoice.

@Suite("G5 GST invoice")
struct GSTInvoiceTests {
    @Test("an invoice carries a non-empty number that is stable for a visit and distinct across visits")
    func invoiceNumberIsStableAndDistinct() async throws {
        let repo = MockInvoiceRepository()
        let visitA = UUID(), visitB = UUID()

        let first = try #require(await repo.invoice(visitId: visitA))
        let again = try #require(await repo.invoice(visitId: visitA))
        let other = try #require(await repo.invoice(visitId: visitB))

        #expect(!first.invoiceNumber.trimmingCharacters(in: .whitespaces).isEmpty)
        #expect(first.invoiceNumber == again.invoiceNumber,
                "re-fetching one visit's invoice must not mint a new number")
        #expect(first.invoiceNumber != other.invoiceNumber,
                "two visits must never share an invoice number")
        #expect(first.visitId == visitA)
        #expect(other.visitId == visitB)
    }

    @Test("gstMinorUnits agrees with the GST line in the invoice's own breakdown")
    func gstFigureMatchesTheBreakdownLine() async throws {
        let repo = MockInvoiceRepository()
        let invoice = try #require(await repo.invoice(visitId: UUID()))

        // A tax invoice whose headline GST figure isn't the GST it itemizes is
        // a filing defect, not a cosmetic one.
        let gstLine = try #require(invoice.breakdown.lineItems.first(where: { $0.label.localizedCaseInsensitiveContains("GST") }))
        #expect(gstLine.amountMinorUnits == invoice.gstMinorUnits)
    }

    @Test("the invoice total is the taxable amount plus GST, and the line items sum to it")
    func totalIncludesGST() async throws {
        let repo = MockInvoiceRepository()
        let invoice = try #require(await repo.invoice(visitId: UUID()))

        let lineSum = invoice.breakdown.lineItems.reduce(0) { $0 + $1.amountMinorUnits }
        #expect(lineSum == invoice.breakdown.totalMinorUnits,
                "the itemization must add up to the total the customer is charged")
        #expect(invoice.gstMinorUnits > 0)

        let preTax = invoice.breakdown.lineItems
            .filter { !$0.label.localizedCaseInsensitiveContains("GST") }
            .reduce(0) { $0 + $1.amountMinorUnits }
        #expect(invoice.breakdown.totalMinorUnits == preTax + invoice.gstMinorUnits,
                "a total that omits the GST the invoice itself reports undercharges the customer and understates the tax filing")
    }

    @Test("an invoice's GST is 18% of its pre-tax lines, the rate PricingEngine charges")
    func gstRateMatchesPricingEngine() async throws {
        let repo = MockInvoiceRepository()
        let invoice = try #require(await repo.invoice(visitId: UUID()))

        let preTax = invoice.breakdown.lineItems
            .filter { !$0.label.localizedCaseInsensitiveContains("GST") }
            .reduce(0) { $0 + $1.amountMinorUnits }
        #expect(invoice.gstMinorUnits == Int((Double(preTax) * 0.18).rounded()))
    }
}

// MARK: - K8: payment disputes (chargebacks).

/// `MockPaymentDisputeRepository` starts empty and its `seededDisputes` array
/// is actor-isolated with no seeding API, so it cannot be given rows from a
/// test. This double stands in for the same contract.
actor FakePaymentDisputeRepository: PaymentDisputeRepository {
    private let seeded: [PaymentDispute]
    init(_ seeded: [PaymentDispute]) { self.seeded = seeded }

    func disputes(visitId: UUID) async throws -> [PaymentDispute] {
        seeded.filter { $0.visitId == visitId }
    }
}

private func makeDispute(visitId: UUID, status: PaymentDispute.Status, reason: String = "Product not received") -> PaymentDispute {
    PaymentDispute(id: UUID(), paymentId: UUID(), visitId: visitId, gatewayDisputeId: "dp_\(UUID().uuidString.prefix(8))",
                   reason: reason, amountMinorUnits: 59_900, status: status,
                   openedAt: .now.addingTimeInterval(-3_600),
                   resolvedAt: status == .won || status == .lost ? .now : nil,
                   evidenceSubmittedAt: nil)
}

@Suite("K8 payment disputes")
struct PaymentDisputeTests {
    @Test("an open dispute is active")
    func openIsActive() {
        #expect(makeDispute(visitId: UUID(), status: .open).isActive)
    }

    @Test("a dispute needing a response is still active")
    func needsResponseIsActive() {
        #expect(makeDispute(visitId: UUID(), status: .needsResponse).isActive)
    }

    @Test("a won dispute is resolved, not active")
    func wonIsNotActive() {
        #expect(!makeDispute(visitId: UUID(), status: .won).isActive)
    }

    @Test("a lost dispute is resolved, not active")
    func lostIsNotActive() {
        #expect(!makeDispute(visitId: UUID(), status: .lost).isActive)
    }

    @Test("every dispute status is classified, and exactly the unresolved two are active")
    func activeSetIsExactlyOpenAndNeedsResponse() {
        let visitId = UUID()
        let all: [PaymentDispute.Status] = [.open, .needsResponse, .won, .lost]
        let active = Set(all.filter { makeDispute(visitId: visitId, status: $0).isActive }.map(\.rawValue))
        #expect(active == ["open", "needs_response"])
    }

    @Test("disputes(visitId:) returns this visit's rows and none of another visit's")
    func disputesAreScopedToTheVisit() async throws {
        let mine = UUID(), theirs = UUID()
        let myOpen = makeDispute(visitId: mine, status: .open, reason: "Duplicate charge")
        let myWon = makeDispute(visitId: mine, status: .won, reason: "Fraudulent")
        let notMine = makeDispute(visitId: theirs, status: .open, reason: "Someone else's chargeback")
        let repo = FakePaymentDisputeRepository([myOpen, notMine, myWon])

        let rows = try await repo.disputes(visitId: mine)
        // Both of this visit's rows present...
        #expect(rows.count == 2)
        #expect(rows.contains { $0.id == myOpen.id })
        #expect(rows.contains { $0.id == myWon.id })
        // ...and the other visit's is absent rather than the filter having
        // simply emptied the list.
        #expect(!rows.contains { $0.id == notMine.id })
        #expect(rows.allSatisfy { $0.visitId == mine })

        let theirRows = try await repo.disputes(visitId: theirs)
        #expect(theirRows.map(\.id) == [notMine.id])
    }

    @Test("only the unresolved dispute drives the customer-facing active hold")
    func activeHoldPicksTheOpenRow() async throws {
        let visitId = UUID()
        let open = makeDispute(visitId: visitId, status: .needsResponse)
        let settled = makeDispute(visitId: visitId, status: .lost)
        let repo = FakePaymentDisputeRepository([settled, open])

        let active = try await repo.disputes(visitId: visitId).filter(\.isActive)
        #expect(active.map(\.id) == [open.id])
    }
}
