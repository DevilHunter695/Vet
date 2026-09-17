import SwiftUI

/// O6 (P0): a static, in-app privacy policy so App Store review and DPDP
/// compliance don't depend on a web page being reachable. This is a
/// reasonable best-effort draft written for this app, not legal advice —
/// have it reviewed by counsel before relying on it commercially.
struct PrivacyPolicyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Privacy Policy").font(.brandLargeTitle)
                Text("Last updated: September 2026").font(.brandCaption).foregroundStyle(Theme.textSecondary)

                LegalSection(title: "Who we are") {
                    Text("VetCircuit is a marketplace connecting pet owners with independent, VCI-registered veterinary professionals for home visits. VetCircuit is not itself a veterinary clinic and does not employ the vets who visit you.")
                }

                LegalSection(title: "What we collect") {
                    Text("""
                    • Account details: name, phone number, email, and Sign in with Apple identifier.
                    • Household details: your addresses (including precise location, used only to match you to a serving circuit and to give the vet directions), and your pets' details (species, breed, date of birth, and medical notes recorded by a vet).
                    • Visit data: booking history, chat messages and photos you send a vet, call metadata (not call recordings) for masked calling, and visit records/prescriptions written by your vet.
                    • Payment data: processed by our payment gateway (Razorpay); we never see or store your card, UPI, or bank details ourselves — only the payment status and gateway reference.
                    • Device data: push notification token, app version, and coarse usage analytics used to fix crashes and improve reliability.
                    """)
                }

                LegalSection(title: "Why we collect it") {
                    Text("We use this data to operate the marketplace: matching you to a circuit, running your bookings, processing payment, letting you and your vet communicate, keeping a medical record for your pet, complying with tax and financial record-keeping law, and sending the reminders and updates you've opted into (see Notification preferences).")
                }

                LegalSection(title: "Who we share it with") {
                    Text("The vet assigned to your visit sees your pet's records, address, and access notes needed to perform the visit. Our payment gateway processes transactions on our behalf. We do not sell your data. We disclose data to law enforcement only when legally compelled to.")
                }

                LegalSection(title: "Your rights (DPDP Rules 2025)") {
                    Text("As a data principal under India's Digital Personal Data Protection framework, you can: view and withdraw specific consents (Profile → Privacy & consent), export a copy of your data, and request deletion of your account. Deletion has a 30-day window to undo it by mistake, after which your personal data is purged — financial records required to be retained by law (e.g. invoices) are kept for the legally mandated period, clearly separate from your personal profile.")
                }

                LegalSection(title: "Data retention") {
                    Text("Active account data is retained while your account exists. Visit, payment, and invoice records are retained as required by Indian tax and consumer-protection law even after account deletion. Chat messages tied to a visit are retained for the same window as the visit record, to support any dispute raised about that visit.")
                }

                LegalSection(title: "Security") {
                    Text("Data is encrypted in transit. Access to production data is restricted to authorized operations staff and logged. We never store raw card details — hosted checkout keeps that entirely with our PCI-compliant payment gateway.")
                }

                LegalSection(title: "Cancellations and refunds") {
                    Text("Cancellation and refund handling is governed by our stated cancellation policy, shown at booking and in Help centre — this privacy policy does not itself set commercial terms; see Terms of Service for those.")
                }

                LegalSection(title: "Contact") {
                    Text("Questions about this policy or your data can be raised through Profile → Help centre → Contact support.")
                }

                Text("This policy is a good-faith draft for VetCircuit and is not a substitute for advice from a qualified lawyer.")
                    .font(.brandCaption).foregroundStyle(Theme.textSecondary).italic()
            }
            .padding()
        }
        .auroraScreenBackground()
        .floatingTabBarInset()
        .navigationTitle("Privacy Policy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct LegalSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.brandHeadline)
            content.font(.brandBody).foregroundStyle(Theme.textSecondary)
        }
    }
}

#Preview {
    NavigationStack { PrivacyPolicyView() }
}
