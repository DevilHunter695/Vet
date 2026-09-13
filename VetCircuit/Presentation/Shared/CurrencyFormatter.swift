import Foundation

/// All amounts are stored as integer minor units (paise) per plan §5.1 —
/// "money never drifts" — so every display point formats through here rather
/// than doing its own float division.
enum CurrencyFormatter {
    static func rupees(_ minorUnits: Int) -> String {
        let rupees = Double(minorUnits) / 100
        return rupees.formatted(.currency(code: "INR").precision(.fractionLength(rupees.truncatingRemainder(dividingBy: 1) == 0 ? 0 : 2)))
    }
}
