import SwiftUI
import UIKit

/// E11: shown once on a completed visit, presets plus a custom amount. A
/// tip goes 100% to the vet (0028_tips.sql's credit_vet_on_tip_succeeded
/// trigger) rather than the ~70% split a regular visit earns.
struct TipVetView: View {
    let visitId: UUID
    var onTipped: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var customAmountText = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private let tipUseCase = DependencyContainer.shared.tipUseCase()

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("Add a tip for your vet")
                    .font(.brandHeadline)
                Text("100% goes directly to the vet who visited you.")
                    .font(.brandCaption)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)

                HStack(spacing: 12) {
                    ForEach(TipUseCase.presetAmountsMinorUnits, id: \.self) { amount in
                        // Two taps in quick succession used to open two
                        // gateway sessions — i.e. two real charges.
                        Button {
                            guard !isSubmitting else { return }
                            Haptics.tap()
                            Task { await submit(amountMinorUnits: amount) }
                        } label: {
                            Text(CurrencyFormatter.rupees(amount))
                                .font(.brandBody.bold())
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.bordered)
                        .disabled(isSubmitting)
                    }
                }

                HStack {
                    TextField("Custom amount (₹)", text: $customAmountText)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                    Button("Send") {
                        guard !isSubmitting, let rupees = Int(customAmountText), rupees > 0 else { return }
                        Task { await submit(amountMinorUnits: rupees * 100) }
                    }
                    .disabled(Int(customAmountText) == nil || isSubmitting)
                }

                if let errorMessage {
                    ErrorBanner(message: errorMessage)
                }

                if isSubmitting {
                    Label("Opening secure checkout…", systemImage: "lock.fill")
                        .font(.brandCaption).foregroundStyle(Theme.textSecondary)
                    ProgressView()
                }

                Spacer()
            }
            .padding()
            .auroraScreenBackground()
            .navigationTitle("Tip the vet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { dismiss() }
                }
            }
        }
    }

    private func submit(amountMinorUnits: Int) async {
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            let checkoutURL = try await tipUseCase.execute(visitId: visitId, amountMinorUnits: amountMinorUnits)
            await UIApplication.shared.open(checkoutURL)
            onTipped()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    TipVetView(visitId: UUID())
}
