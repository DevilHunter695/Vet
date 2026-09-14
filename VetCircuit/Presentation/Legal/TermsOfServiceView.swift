import SwiftUI

/// O6 (P0): a static, in-app Terms of Service — a reasonable draft written
/// for VetCircuit's actual booking/refund/liability model, not lorem ipsum,
/// but not a substitute for legal review before commercial launch.
struct TermsOfServiceView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Terms of Service").font(.brandLargeTitle)
                Text("Last updated: September 2026").font(.brandCaption).foregroundStyle(.secondary)

                LegalSection(title: "The marketplace model") {
                    Text("VetCircuit operates a platform connecting pet owners with independent, VCI-registered veterinary professionals ('vets') who perform home visits on a scheduled circuit basis. VetCircuit is not a party to the veterinary care itself, does not employ the vets, and does not practice veterinary medicine. The vet is solely responsible for the professional care given during a visit.")
                }

                LegalSection(title: "Not an emergency service") {
                    Text("VetCircuit is a scheduled, non-emergency service. If your pet has a life-threatening emergency, go directly to the nearest 24×7 veterinary emergency facility rather than booking through the app.")
                }

                LegalSection(title: "Booking, pricing and payment") {
                    Text("The price shown before you confirm a booking — including any per-pet, add-on, travel, and tax components — is the full price charged; it is generated server-side and cannot be altered by the app. Payment is processed by our payment gateway. Cash/UPI-to-vet is available only where explicitly offered at checkout.")
                }

                LegalSection(title: "Cancellation and refund policy") {
                    Text("""
                    • Cancelling more than 4 hours before your scheduled slot: full refund.
                    • Cancelling within 4 hours of your scheduled slot: 50% refund.
                    • Not being available for a confirmed visit (no-show): no refund — the vet held that slot exclusively for you.
                    • Refunds are issued to your original payment method, typically within 5-7 business days.
                    This policy is enforced consistently as stated at booking; see Help centre for how to request an exception through support.
                    """)
                }

                LegalSection(title: "Liability") {
                    Text("You must provide safe, reasonable access to your pet for a visit. Veterinary care carries inherent risk, which the vet will explain before any procedure. By booking a visit you accept the liability waiver presented before your first booking (see Consent). VetCircuit's liability as a marketplace, to the extent permitted by law, is limited to refunding amounts paid for the specific visit in question.")
                }

                LegalSection(title: "Reviews and conduct") {
                    Text("Reviews must reflect a genuine visit and may not contain defamatory, abusive, or personally identifying third-party content. VetCircuit may moderate or remove reviews that violate this. Abusive conduct toward a vet, or fraudulent bookings, may result in account suspension.")
                }

                LegalSection(title: "Disputes and support") {
                    Text("If something goes wrong with a visit, use \"Report a problem with this visit\" from that visit's details, or Contact support from Help centre. We aim to acknowledge tickets promptly and resolve disputes fairly, including issuing refunds or credits where warranted.")
                }

                LegalSection(title: "Account termination") {
                    Text("You may delete your account at any time (Profile → Privacy & consent). We may suspend or terminate accounts that violate these terms, engage in fraud, or pose a safety risk to vets or other users.")
                }

                LegalSection(title: "Changes to these terms") {
                    Text("We may update these terms as the product evolves; material changes will be reflected here with an updated date, and continued use of the app after a change constitutes acceptance.")
                }

                Text("These terms are a good-faith draft for VetCircuit and are not a substitute for advice from a qualified lawyer.")
                    .font(.brandCaption).foregroundStyle(.secondary).italic()
            }
            .padding()
        }
        .auroraScreenBackground()
        .navigationTitle("Terms of Service")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack { TermsOfServiceView() }
}
