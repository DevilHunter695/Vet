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
