import SwiftUI

/// I6: a digital consent/liability waiver accepted before a customer's
/// first visit — a legal shield, shown once and recorded with a version
/// so a future policy change can require re-acceptance.
struct LiabilityWaiverView: View {
    let userId: UUID
    let onAccepted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isAccepting = false
    @State private var errorMessage: String?
    private let manageConsentUseCase = DependencyContainer.shared.manageConsentUseCase()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Before your first visit").font(.brandLargeTitle)
                    Text("""
                    A VetCircuit vet or para-vet will visit your home. By continuing, you agree that:

                    • VetCircuit is a marketplace connecting you with independent, VCI-registered veterinary professionals — not itself a clinic.
                    • You'll provide safe, reasonable access to your pet for the visit.
                    • Veterinary care carries inherent risk; the vet will explain any procedure before performing it.
                    • You can withdraw this consent at any time in Profile → Privacy & consent, which pauses future bookings until it's re-accepted.
                    """)
                    .font(.brandBody)
                    .foregroundStyle(Theme.textSecondary)

                    // O6: the full legal text lives in-app, not only in this
                    // summary — required for App Store review and DPDP.
                    VStack(alignment: .leading, spacing: 8) {
                        NavigationLink("Read full Privacy Policy") { PrivacyPolicyView() }
                        NavigationLink("Read full Terms of Service") { TermsOfServiceView() }
                    }
                    .font(.brandBody)
                }
                .padding()
            }
            .auroraScreenBackground()
            .navigationTitle("Consent")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    // I6: swallowing this with `try?` recorded no consent row
                    // and then waved the user through — the legal shield this
                    // screen exists to provide simply wasn't there.
                    if let errorMessage {
                        ErrorBanner(message: errorMessage)
                    }
                    PrimaryButton(title: "I agree, continue", isLoading: isAccepting) {
                        Task { await accept() }
                    }
                }
                .padding()
                .background(.regularMaterial)
            }
        }
    }

    private func accept() async {
        isAccepting = true
        errorMessage = nil
        do {
            _ = try await manageConsentUseCase.acceptLiabilityWaiver(userId: userId)
            Haptics.success()
            isAccepting = false
            onAccepted()
            dismiss()
        } catch {
            // No consent recorded means no continuing.
            Haptics.error()
            isAccepting = false
            errorMessage = "We couldn't record your consent, so we can't continue yet. \(error.localizedDescription)"
        }
    }
}

#Preview {
    LiabilityWaiverView(userId: UUID()) {}
}
