import SwiftUI

/// E7: the slot hold, stated plainly with its clock.
///
/// Placing a hold is the app doing something *for* the customer, and the
/// reassurance has to arrive at the moment it happens — the instant a time is
/// picked. It previously appeared only on the later steps of the booking
/// flow, so picking a slot silently reserved it and the app said nothing
/// until you had already moved on, which is the one moment the reassurance
/// was worth nothing.
struct SlotHoldBanner: View {
    let secondsRemaining: Int

    private var clock: String {
        "\(secondsRemaining / 60):\(String(format: "%02d", secondsRemaining % 60))"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.badge.clock.fill")
                .foregroundStyle(Theme.inProgress)

            VStack(alignment: .leading, spacing: 1) {
                Text("This slot is held for you")
                    .font(.brandCaption)
                Text("No one else can take it for the next \(clock)")
                    .font(.brandCaption)
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer(minLength: 0)

            Text(clock)
                .font(.brandMono(.callout, weight: .bold))
                // Monospaced digits because a countdown redraws every second,
                // and proportional figures make the whole row shift sideways
                // on each tick.
                .foregroundStyle(Theme.inProgress)
                // Hidden from VoiceOver: the sentence above already says how
                // long the hold lasts, and the combined element would
                // otherwise read the same time twice.
                .accessibilityHidden(true)
        }
        .padding(12)
        .background(Theme.inProgress.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .transition(.opacity)
        .accessibilityElement(children: .combine)
    }
}

/// What the countdown turns into when it runs out.
///
/// The hold is genuinely gone at this point — the server released it — so the
/// honest thing is to say so and offer the one action that helps, rather than
/// leaving a reassuring banner frozen at "0:00" and letting the customer find
/// out by tapping Confirm and reading an error.
struct SlotHoldExpiredBanner: View {
    let onExtend: () -> Void

    @State private var isExtending = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.badge.exclamationmark.fill")
                .foregroundStyle(Theme.warning)

            VStack(alignment: .leading, spacing: 1) {
                Text("Your hold on this slot ran out")
                    .font(.brandCaption)
                Text("It's still yours to book if no one else has taken it.")
                    .font(.brandCaption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Button {
                Haptics.tap()
                isExtending = true
                onExtend()
                // The re-hold call swaps this banner out on success; the flag
                // only has to survive long enough to stop a double tap.
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    isExtending = false
                }
            } label: {
                if isExtending {
                    ProgressView()
                } else {
                    Text("Hold again").font(.brandCaption.weight(.semibold))
                }
            }
            .buttonStyle(.bordered)
            .tint(Theme.warning)
            .disabled(isExtending)
        }
        .padding(12)
        .background(Theme.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .transition(.opacity)
    }
}
