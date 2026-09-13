import SwiftUI

/// I6: a digital consent/liability waiver accepted before a customer's
/// first visit — a legal shield, shown once and recorded with a version
/// so a future policy change can require re-acceptance.
struct LiabilityWaiverView: View {
    let userId: UUID
    let onAccepted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isAccepting = false
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
                    .foregroundStyle(.secondary)

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
            .navigationTitle("Consent")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                PrimaryButton(title: "I agree, continue", isLoading: isAccepting) {
                    Task {
                        isAccepting = true
                        _ = try? await manageConsentUseCase.acceptLiabilityWaiver(userId: userId)
                        Haptics.success()
                        onAccepted()
                        dismiss()
                    }
                }
                .padding()
                .background(.regularMaterial)
            }
        }
    }
}

#Preview {
    LiabilityWaiverView(userId: UUID()) {}
}
