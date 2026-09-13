import Foundation

/// Appendix C — the single pricing formula, implemented once as pure,
/// framework-free Swift so it's identically testable on the client and
/// portable into the server-side quote function (plan §6.2: "the client
/// never computes a rupee" means this exact logic runs authoritatively on
/// the server; this copy exists so mock/local development has real prices
/// without a backend, and so the formula itself has unit test coverage).
enum PricingEngine {
    struct Input {
        var variant: ServiceVariant
        var addons: [Addon]
        var additionalPetCount: Int   // pets beyond the first on this line
        var travelFeeMinorUnits: Int  // 0 if the slot is on an existing circuit run
        var peakMultiplier: Double = 1.0
        var couponDiscountMinorUnits: Int = 0
        var walletBalanceMinorUnits: Int = 0
        var gstRate: Double = 0.18
        /// D5: a vet's per-service price override, when one exists for this
        /// vet+service/variant — takes precedence over the catalog default.
        var vetOverridePriceMinorUnits: Int? = nil
    }

    static func quote(_ input: Input) -> PriceBreakdown {
        var lineItems: [PriceLineItem] = []

        let base = input.vetOverridePriceMinorUnits ?? input.variant.priceMinorUnits
        lineItems.append(PriceLineItem(label: input.variant.name, amountMinorUnits: base))

        let multiPet = input.additionalPetCount * input.variant.additionalPetPriceMinorUnits
        if multiPet > 0 {
            lineItems.append(PriceLineItem(label: "Additional pet(s) ×\(input.additionalPetCount)", amountMinorUnits: multiPet))
        }

        let addonsTotal = input.addons.reduce(0) { $0 + $1.priceMinorUnits }
        for addon in input.addons {
            lineItems.append(PriceLineItem(label: addon.name, amountMinorUnits: addon.priceMinorUnits))
        }

        if input.travelFeeMinorUnits > 0 {
            lineItems.append(PriceLineItem(label: "Travel fee", amountMinorUnits: input.travelFeeMinorUnits))
        }

        let subtotalBeforePeak = base + multiPet + addonsTotal + input.travelFeeMinorUnits
        let peakDelta = Int((Double(subtotalBeforePeak) * (input.peakMultiplier - 1.0)).rounded())
        if peakDelta != 0 {
            lineItems.append(PriceLineItem(label: "Peak-time adjustment", amountMinorUnits: peakDelta))
        }

        let subtotal = subtotalBeforePeak + peakDelta

        let discount = min(input.couponDiscountMinorUnits, subtotal)
        if discount > 0 {
            lineItems.append(PriceLineItem(label: "Discount", amountMinorUnits: -discount))
        }

        let taxable = max(0, subtotal - discount)
        let gst = Int((Double(taxable) * input.gstRate).rounded())
        if gst > 0 {
            lineItems.append(PriceLineItem(label: "GST (\(Int(input.gstRate * 100))%)", amountMinorUnits: gst))
        }

        let preWalletTotal = taxable + gst
        let walletApplied = min(input.walletBalanceMinorUnits, preWalletTotal)
        if walletApplied > 0 {
            lineItems.append(PriceLineItem(label: "Wallet credit", amountMinorUnits: -walletApplied))
        }

        let total = max(0, preWalletTotal - walletApplied)
        return PriceBreakdown(lineItems: lineItems, totalMinorUnits: total)
    }
}
