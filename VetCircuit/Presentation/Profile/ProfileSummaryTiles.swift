import SwiftUI

/// Four figures that answer "how am I doing here?" without making the user
/// open four screens. A prototype shows navigation; a finished product shows
/// state.
struct ProfileSummaryTiles: View {
    let walletBalanceMinorUnits: Int
    let loyaltyPoints: Int
    let loyaltyTint: Color
    let activePetsCount: Int
    let completedVisitCount: Int

    var body: some View {
        // One divided strip rather than four separate cards: see `StatStrip`
        // for why. Four figures share the width comfortably here because the
        // strip is shallow and the value font is a callout, not a title — the
        // old two-column grid needed the extra room only because each figure
        // was trying to be a headline.
        StatStrip(items: [
            .init(
                value: CurrencyFormatter.rupees(walletBalanceMinorUnits),
                label: "Wallet", systemImage: "indianrupeesign.circle.fill", tint: Theme.emerald
            ),
            .init(
                value: "\(loyaltyPoints)",
                label: "Points", systemImage: "star.fill",
                tint: loyaltyTint
            ),
            .init(
                value: "\(activePetsCount)",
                label: activePetsCount == 1 ? "Pet" : "Pets",
                systemImage: "pawprint.fill", tint: Theme.primary
            ),
            .init(
                value: "\(completedVisitCount)",
                label: "Visits", systemImage: "checkmark.seal.fill", tint: Theme.primaryLight,
                accessibilityName: "Visits done"
            )
        ])
    }
}
