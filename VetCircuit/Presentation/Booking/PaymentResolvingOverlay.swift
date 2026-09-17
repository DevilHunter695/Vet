import SwiftUI

/// Shown while the app is confirming with the server whether a payment
/// succeeded.
///
/// Apple's guidance on feedback is to match how information is delivered to
/// how significant it is, and to "clearly communicate that content is
/// loading" whenever it takes more than a moment. Almost nothing in an app is
/// more significant than the seconds after somebody has paid and does not yet
/// know if it worked — so this is deliberately the most interrupting piece of
/// feedback in the booking flow: it covers the screen, it says plainly what
/// is happening, and it asks them not to leave.
///
/// It does not claim success or failure. It says only what is true right
/// then: we are checking. The three outcomes that follow each have their own
/// honest message.
struct PaymentResolvingOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // A scrim, because this is a moment to focus on rather than one
            // to work around — Apple's rule is to dim for a modal task and
            // stay translucent for a parallel one, and this is not parallel.
            Rectangle()
                .fill(.black.opacity(0.45))
                .ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)

                VStack(spacing: 6) {
                    Text("Confirming your payment")
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)

                    Text("This takes a few seconds. Please don't close the app.")
                        .font(.brandCallout)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(28)
            .frame(maxWidth: 320)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
        // One element, one announcement — VoiceOver should say what is
        // happening, not read a spinner and a paragraph separately.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Confirming your payment. This takes a few seconds. Please don't close the app.")
        .accessibilityAddTraits(.updatesFrequently)
    }
}
