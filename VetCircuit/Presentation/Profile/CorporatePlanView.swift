import SwiftUI

/// V3: corporate/RWA (residential welfare association) bulk subscriptions —
/// a single plan covering many households in one apartment complex/office.
struct CorporatePlanView: View {
    @State private var seatCount = 10
    let onSubscribe: (Int) -> Void

    private let pricePerSeatMinorUnits = 29900 // ₹299/seat/month, illustrative

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Corporate / RWA plan", systemImage: "building.2.fill")
                            .font(.brandHeadline)
                            .foregroundStyle(Theme.primary)
                        Text("One plan covering every household in your apartment complex or office campus, billed centrally.")
                            .font(.brandBody)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .appearAnimation()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Number of seats").font(.brandHeadline)
                    Stepper(value: $seatCount, in: 5...500, step: 5) {
                        Text("\(seatCount) seats").font(.brandBody)
                    }
                    .onChange(of: seatCount) { _, _ in Haptics.rigid() }
                    Text("Minimum 5 seats.")
                        .font(.brandCaption)
                        .foregroundStyle(.secondary)
                }

                Card {
                    HStack {
                        Text("Estimated monthly total").font(.brandBody)
                        Spacer()
                        Text(estimatedTotal)
                            .font(.brandHeadline)
                            .contentTransition(.numericText())
                            .animation(Theme.springQuick, value: seatCount)
                    }
                }

                PrimaryButton(title: "Continue to checkout") {
                    onSubscribe(seatCount)
                }
            }
            .padding()
        }
        .auroraScreenBackground()
        .navigationTitle("Corporate plan")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var estimatedTotal: String {
        // Through the shared formatter like every other price in the app —
        // amounts are integer minor units and must never be divided ad hoc.
        CurrencyFormatter.rupees(seatCount * pricePerSeatMinorUnits)
    }
}

#Preview {
    NavigationStack { CorporatePlanView { _ in } }
}
