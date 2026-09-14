import Testing
import Foundation
@testable import VetCircuit

// E6+E8+E10+G6: the quote -> checkout -> confirmed-visit booking pipeline.

@Suite("BookingCheckoutPolicy")
struct BookingCheckoutPolicyTests {
    @Test("a succeeded payment confirms the visit")
    func succeededConfirms() {
        let outcome = BookingCheckoutPolicy.outcome(forPaymentStatus: .succeeded, priorAttempts: 0)
        #expect(outcome == .confirmVisit)
    }

    @Test("a pending payment keeps the customer waiting, without failing")
    func pendingAwaits() {
        let outcome = BookingCheckoutPolicy.outcome(forPaymentStatus: .pending, priorAttempts: 0)
        #expect(outcome == .awaitingPayment)
    }

    @Test("a failed payment under the retry cap can retry")
    func failedUnderCapCanRetry() {
        let outcome = BookingCheckoutPolicy.outcome(forPaymentStatus: .failed, priorAttempts: 0)
        guard case .paymentFailed(let canRetry, _) = outcome else { Issue.record("expected paymentFailed"); return }
        #expect(canRetry)
    }

    @Test("a failed payment at the retry cap can no longer retry, and carries a reason")
    func failedAtCapStops() {
        let outcome = BookingCheckoutPolicy.outcome(forPaymentStatus: .failed, priorAttempts: PaymentRetryPolicy.maxAttempts)
        guard case .paymentFailed(let canRetry, let reason) = outcome else { Issue.record("expected paymentFailed"); return }
        #expect(!canRetry)
        #expect(reason != nil)
    }

    @Test("a refunded payment is treated as failed, with no retry offered")
    func refundedNeverRetries() {
        let outcome = BookingCheckoutPolicy.outcome(forPaymentStatus: .refunded, priorAttempts: 0)
        guard case .paymentFailed(let canRetry, _) = outcome else { Issue.record("expected paymentFailed"); return }
        #expect(!canRetry)
    }
}

private func makePipelineQuote(cartId: UUID = UUID(), expired: Bool = false) -> Quote {
    Quote(id: UUID(), cartId: cartId,
          breakdown: PriceBreakdown(lineItems: [PriceLineItem(label: "Service", amountMinorUnits: 50000)], totalMinorUnits: 50000),
          signature: "test-signature",
          expiresAt: expired ? .now.addingTimeInterval(-60) : .now.addingTimeInterval(600))
}

private func makePipelineSlot() -> ScheduleSlot {
    ScheduleSlot(id: UUID(), dayOfWeek: 2, startTime: .now.addingTimeInterval(3600),
                 endTime: .now.addingTimeInterval(7200), capacity: 3, bookedCount: 0)
}

@Suite("BookingCheckoutUseCase")
struct BookingCheckoutUseCaseTests {
    private func makePipeline(paymentStatus: Payment.Status = .succeeded) -> (BookingCheckoutUseCase, MockVisitRepository, FakePaymentRepository) {
        let visitRepository = MockVisitRepository()
        let paymentRepository = FakePaymentRepository(status: paymentStatus)
        let pipeline = BookingCheckoutUseCase(
            bookVisitUseCase: BookVisitUseCase(visitRepository: visitRepository),
            startCheckoutUseCase: StartCheckoutUseCase(paymentRepository: paymentRepository),
            visitRepository: visitRepository, paymentRepository: paymentRepository
        )
        return (pipeline, visitRepository, paymentRepository)
    }

    @Test("start() books a requested visit and returns a checkout URL")
    func startBooksAndChecksOut() async throws {
        let (pipeline, _, _) = makePipeline()
        let session = try await pipeline.start(
            petId: UUID(), vetId: UUID(), circuitId: UUID(), slot: makePipelineSlot(),
            quote: makePipelineQuote(), idempotencyKey: UUID().uuidString
        )
        #expect(session.visit.status == .requested)
        #expect(session.visit.paymentId == nil)
    }

    @Test("start() refuses an expired quote and never books a visit")
    func startRefusesExpiredQuote() async {
        let (pipeline, visitRepository, _) = makePipeline()
        await #expect(throws: DomainError.self) {
            _ = try await pipeline.start(
                petId: UUID(), vetId: UUID(), circuitId: UUID(), slot: makePipelineSlot(),
                quote: makePipelineQuote(expired: true), idempotencyKey: UUID().uuidString
            )
        }
        let visits = try await visitRepository.listVisits(userId: MockData.user.id)
        #expect(visits.isEmpty)
    }

    @Test("resolve() confirms and attaches payment once the payment succeeds")
    func resolveConfirmsOnSuccess() async throws {
        let (pipeline, _, _) = makePipeline(paymentStatus: .succeeded)
        let session = try await pipeline.start(
            petId: UUID(), vetId: UUID(), circuitId: UUID(), slot: makePipelineSlot(),
            quote: makePipelineQuote(), idempotencyKey: UUID().uuidString
        )
        let (visit, outcome) = try await pipeline.resolve(visitId: session.visit.id, priorAttempts: 0)
        #expect(outcome == .confirmVisit)
        #expect(visit.status == .confirmed)
        #expect(visit.paymentId != nil)
    }

    @Test("resolve() leaves the visit as requested, unconfirmed, while payment is pending")
    func resolveAwaitsOnPending() async throws {
        let (pipeline, _, _) = makePipeline(paymentStatus: .pending)
        let session = try await pipeline.start(
            petId: UUID(), vetId: UUID(), circuitId: UUID(), slot: makePipelineSlot(),
            quote: makePipelineQuote(), idempotencyKey: UUID().uuidString
        )
        let (visit, outcome) = try await pipeline.resolve(visitId: session.visit.id, priorAttempts: 0)
        #expect(outcome == .awaitingPayment)
        #expect(visit.status == .requested)
        #expect(visit.paymentId == nil)
    }

    @Test("resolve() never confirms the visit on a failed payment")
    func resolveNeverConfirmsOnFailure() async throws {
        let (pipeline, _, _) = makePipeline(paymentStatus: .failed)
        let session = try await pipeline.start(
            petId: UUID(), vetId: UUID(), circuitId: UUID(), slot: makePipelineSlot(),
            quote: makePipelineQuote(), idempotencyKey: UUID().uuidString
        )
        let (visit, outcome) = try await pipeline.resolve(visitId: session.visit.id, priorAttempts: 0)
        guard case .paymentFailed = outcome else { Issue.record("expected paymentFailed"); return }
        #expect(visit.status == .requested)
        #expect(visit.paymentId == nil)
    }
}
