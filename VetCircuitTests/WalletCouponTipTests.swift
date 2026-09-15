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

// MARK: - N2: coupon campaign discount maths.
//
// `MockQuoteRepository.discountMinorUnits(for:subtotal:)` is `private static`,
// so it is exercised here through its only caller — `createQuote` — which is
// also the path a real cart takes. A synthetic single-variant catalog is used
// rather than `MockData.services` so the subtotal is an exact, chosen number.

private func makeCouponCatalog(priceMinorUnits: Int) -> (Service, CartItem) {
    let serviceId = UUID(), variantId = UUID()
    let variant = ServiceVariant(id: variantId, serviceId: serviceId, name: "Standard",
                                 durationMinutes: 20, priceMinorUnits: priceMinorUnits)
    let service = Service(id: serviceId, category: .consult, name: "Consult", summary: "",
                          whatToPrepare: nil, variants: [variant])
    let item = CartItem(id: UUID(), serviceId: serviceId, variantId: variantId, petIds: [UUID()])
    return (service, item)
}

/// Quotes a single-line cart at `subtotal` with `code` applied, and returns
/// the signed discount line's amount (nil when no discount line was emitted).
/// `circuitId` is non-nil so the flat ₹45 travel fee stays out of the subtotal.
private func discountLineAmount(code: String?, subtotal: Int) async throws -> Int? {
    let (service, item) = makeCouponCatalog(priceMinorUnits: subtotal)
    let cart = Cart(id: UUID(), userId: UUID(), addressId: nil, circuitId: UUID(), slotId: nil,
                    items: [item], couponCode: code)
    let repo = MockQuoteRepository(couponRepository: MockCouponRepository(), walletRepository: MockWalletRepository())
    let quote = try await repo.createQuote(for: cart, catalog: [service], overrides: [],
                                           useWalletBalance: false, applyEntitlementCredit: false)
    return quote.breakdown.lineItems.first { $0.label == "Discount" }?.amountMinorUnits
}

@Suite("N2 coupon campaign discounts")
struct CouponCampaignDiscountTests {
    @Test("a percentage coupon is capped by maxDiscountMinorUnits, not left unbounded")
    func percentageIsCapped() async throws {
        // FIRSTVISIT is 20% off capped at ₹300. On a ₹3,000 subtotal the
        // uncapped percentage would be ₹600 — twice the campaign's cap.
        let discount = try await discountLineAmount(code: "FIRSTVISIT", subtotal: 300_000)
        #expect(discount == -30_000)
        #expect(discount != -60_000, "the 20% figure was applied without honouring maxDiscountMinorUnits")
    }

    @Test("a percentage coupon below its cap keeps the full percentage — the cap is not a flat rate")
    func percentageUnderCapIsNotClamped() async throws {
        // 20% of ₹1,000 is ₹200, comfortably under FIRSTVISIT's ₹300 cap.
        let discount = try await discountLineAmount(code: "FIRSTVISIT", subtotal: 100_000)
        #expect(discount == -20_000)
    }

    @Test("CLUSTERLAUNCH's 15% is capped at its own, different ceiling")
    func secondCampaignUsesItsOwnCap() async throws {
        // 15% of ₹3,000 is ₹450; the campaign cap is ₹200.
        let discount = try await discountLineAmount(code: "CLUSTERLAUNCH", subtotal: 300_000)
        #expect(discount == -20_000)
    }

    @Test("a fixedAmountOff coupon takes its value verbatim and never the percentage path")
    func fixedAmountIgnoresPercentage() async throws {
        // WINBACK100 is ₹100 off flat. Were discountValue read as a percentage
        // it would take 10,000% of the subtotal; were it capped like a
        // percentage coupon it would still not be exactly ₹100 on both subtotals.
        let onLargeCart = try await discountLineAmount(code: "WINBACK100", subtotal: 300_000)
        let onSmallCart = try await discountLineAmount(code: "WINBACK100", subtotal: 50_000)
        #expect(onLargeCart == -10_000)
        #expect(onSmallCart == -10_000)
    }

    @Test("a coupon below its minimum spend yields no discount line at all, while a qualifying cart does")
    func belowMinSpendYieldsNoDiscountLine() async throws {
        // WINBACK100 needs a ₹200 subtotal. ₹150 must not discount; ₹250 must.
        let belowMinSpend = try await discountLineAmount(code: "WINBACK100", subtotal: 15_000)
        let aboveMinSpend = try await discountLineAmount(code: "WINBACK100", subtotal: 25_000)
        #expect(belowMinSpend == nil)
        #expect(aboveMinSpend == -10_000)
    }

    @Test("an unknown or absent code leaves the quote undiscounted")
    func unknownCodeDoesNotDiscount() async throws {
        let unknown = try await discountLineAmount(code: "NOT-A-CAMPAIGN", subtotal: 300_000)
        let absent = try await discountLineAmount(code: nil, subtotal: 300_000)
        #expect(unknown == nil)
        #expect(absent == nil)
    }

    @Test("the discounted quote's GST and total are computed on the post-discount amount")
    func capFlowsThroughToTotal() async throws {
        let (service, item) = makeCouponCatalog(priceMinorUnits: 300_000)
        let cart = Cart(id: UUID(), userId: UUID(), addressId: nil, circuitId: UUID(), slotId: nil,
                        items: [item], couponCode: "FIRSTVISIT")
        let repo = MockQuoteRepository(couponRepository: MockCouponRepository(), walletRepository: MockWalletRepository())
        let quote = try await repo.createQuote(for: cart, catalog: [service], overrides: [],
                                               useWalletBalance: false, applyEntitlementCredit: false)
        // ₹3,000 - ₹300 capped discount = ₹2,700 taxable; 18% GST = ₹486.
        let gstLine = try #require(quote.breakdown.lineItems.first(where: { $0.label.hasPrefix("GST") }))
        #expect(gstLine.amountMinorUnits == 48_600)
        #expect(quote.breakdown.totalMinorUnits == 318_600)
    }

    @Test("the campaign coupons carry the usage limits N2 describes")
    func campaignsCarryUsageLimits() async throws {
        let repo = MockCouponRepository()
        let firstVisit = try #require(await repo.validate(code: "FIRSTVISIT", userId: UUID(), cartTotalMinorUnits: 300_000))
        let clusterLaunch = try #require(await repo.validate(code: "CLUSTERLAUNCH", userId: UUID(), cartTotalMinorUnits: 300_000))
        #expect(firstVisit.perUserLimit == 1)
        #expect(clusterLaunch.usageLimit == 500)
        // NB: neither limit is *enforced* anywhere client-side — `validate` is
        // stateless and there is no redemption-recording API on
        // `CouponRepository` — so enforcement can only be asserted once the
        // server-side `validate_coupon()` contract is mirrored here.
    }
}
