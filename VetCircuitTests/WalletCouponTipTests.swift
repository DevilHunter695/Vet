import Testing
import Foundation
@testable import VetCircuit

// G6 (wallet), E4/N2 (coupons), E11 (tip) — domain-layer tests only, no UI.

@Suite("GetWalletBalanceUseCase")
struct GetWalletBalanceUseCaseTests {
    @Test("balance is the sum of ledger entries, including debits")
    func balanceSumsEntries() async throws {
        let repo = MockWalletRepository()
        let userId = UUID()
        _ = try await repo.balanceMinorUnits(userId: userId) // seeds the welcome credit
        let useCase = GetWalletBalanceUseCase(walletRepository: repo)

        let balance = try await useCase.balance(userId: userId)
        #expect(balance == 25_000)
    }

    @Test("entries come back newest first")
    func entriesOrderedNewestFirst() async throws {
        let repo = MockWalletRepository()
        let userId = UUID()
        let useCase = GetWalletBalanceUseCase(walletRepository: repo)

        let entries = try await useCase.entries(userId: userId)
        #expect(!entries.isEmpty)
    }
}

@Suite("ApplyCouponUseCase")
struct ApplyCouponUseCaseTests {
    @Test("rejects an empty code before hitting the repository")
    func rejectsEmptyCode() async {
        let useCase = ApplyCouponUseCase(couponRepository: MockCouponRepository())
        await #expect(throws: DomainError.self) {
            _ = try await useCase.execute(code: "   ", userId: UUID(), cartTotalMinorUnits: 10_000)
        }
    }

    @Test("a valid, in-window coupon above min spend applies")
    func validCouponApplies() async throws {
        let useCase = ApplyCouponUseCase(couponRepository: MockCouponRepository())
        let coupon = try await useCase.execute(code: "firstvisit", userId: UUID(), cartTotalMinorUnits: 10_000)
        #expect(coupon.code == "FIRSTVISIT")
    }

    @Test("a coupon under its minimum spend is rejected")
    func belowMinSpendRejected() async {
        let useCase = ApplyCouponUseCase(couponRepository: MockCouponRepository())
        await #expect(throws: DomainError.self) {
            _ = try await useCase.execute(code: "WINBACK100", userId: UUID(), cartTotalMinorUnits: 5_000)
        }
    }

    @Test("an expired coupon is rejected")
    func expiredCouponRejected() async {
        let useCase = ApplyCouponUseCase(couponRepository: MockCouponRepository())
        await #expect(throws: DomainError.self) {
            _ = try await useCase.execute(code: "EXPIRED10", userId: UUID(), cartTotalMinorUnits: 10_000)
        }
    }

    @Test("an unknown code is rejected")
    func unknownCodeRejected() async {
        let useCase = ApplyCouponUseCase(couponRepository: MockCouponRepository())
        await #expect(throws: DomainError.self) {
            _ = try await useCase.execute(code: "NOPE", userId: UUID(), cartTotalMinorUnits: 10_000)
        }
    }
}

@Suite("TipUseCase")
struct TipUseCaseTests {
    @Test("rejects a zero or negative tip")
    func rejectsNonPositiveTip() async {
        let useCase = TipUseCase(paymentRepository: MockPaymentRepository())
        await #expect(throws: DomainError.self) {
            _ = try await useCase.execute(visitId: UUID(), amountMinorUnits: 0)
        }
    }

    @Test("rejects an unreasonably large tip")
    func rejectsHugeTip() async {
        let useCase = TipUseCase(paymentRepository: MockPaymentRepository())
        await #expect(throws: DomainError.self) {
            _ = try await useCase.execute(visitId: UUID(), amountMinorUnits: 100_000_00)
        }
    }

    @Test("a preset tip amount succeeds")
    func presetTipSucceeds() async throws {
        let useCase = TipUseCase(paymentRepository: MockPaymentRepository())
        let url = try await useCase.execute(visitId: UUID(), amountMinorUnits: TipUseCase.presetAmountsMinorUnits[0])
        #expect(url.absoluteString.contains("tip"))
    }
}

@Suite("PricingEngine coupon + wallet interplay")
struct PricingEngineCouponWalletTests {
    private func variant() -> ServiceVariant {
        ServiceVariant(id: UUID(), serviceId: UUID(), name: "Standard", durationMinutes: 20,
                       priceMinorUnits: 100_000, additionalPetPriceMinorUnits: 20_000, isFollowUp: false)
    }

    @Test("coupon discount is capped at the subtotal")
    func couponCappedAtSubtotal() {
        let input = PricingEngine.Input(variant: variant(), addons: [], additionalPetCount: 0,
                                         travelFeeMinorUnits: 0, couponDiscountMinorUnits: 10_000_000)
        let breakdown = PricingEngine.quote(input)
        #expect(breakdown.totalMinorUnits == 0)
    }

    @Test("wallet applies after tax and cannot push the total negative")
    func walletCannotGoNegative() {
        let input = PricingEngine.Input(variant: variant(), addons: [], additionalPetCount: 0,
                                         travelFeeMinorUnits: 0, walletBalanceMinorUnits: 10_000_000)
        let breakdown = PricingEngine.quote(input)
        #expect(breakdown.totalMinorUnits == 0)
    }

    @Test("coupon and wallet stack: coupon reduces the taxable base, wallet reduces what's left")
    func couponAndWalletStack() {
        let input = PricingEngine.Input(variant: variant(), addons: [], additionalPetCount: 0,
                                         travelFeeMinorUnits: 0, couponDiscountMinorUnits: 20_000, walletBalanceMinorUnits: 30_000)
        let breakdown = PricingEngine.quote(input)
        // subtotal 100_000 - 20_000 discount = 80_000 taxable; +18% gst = 94_400; -30_000 wallet = 64_400
        #expect(breakdown.totalMinorUnits == 64_400)
    }
}
