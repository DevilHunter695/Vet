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
        .navigationTitle("Corporate plan")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var estimatedTotal: String {
        let total = Double(seatCount * pricePerSeatMinorUnits) / 100
        return total.formatted(.currency(code: "INR"))
    }
}

#Preview {
    NavigationStack { CorporatePlanView { _ in } }
}
