import SwiftUI

/// The membership card: current plan + manage link when subscribed, or an
/// inclusions-forward pitch to join when not. Extracted from `ProfileView`
/// (whose body was otherwise a ~140-line stack) into its own file per the
/// "one type per file" rule — it owns no state of its own.
struct ProfileSubscriptionSection: View {
    let subscription: Subscription?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Membership", systemImage: "crown.fill")

            if let subscription, subscription.status != .cancelled {
                VStack(spacing: 12) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(subscription.planType.displayName)
                                .font(.brandTitle3)
                            Text("Renews \(subscription.renewalDate.formatted(date: .abbreviated, time: .omitted))")
                                .font(.brandCaption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        TagChip(
                            text: subscription.status.rawValue.capitalized,
                            systemImage: subscription.status == .active ? "checkmark.circle.fill" : "pause.circle.fill",
                            tint: subscription.status == .active ? Theme.success : Theme.warning
                        )
                    }
                    if subscription.planType.isBulk {
                        GlassSeam()
                        InfoRow(label: "Seats", value: "\(subscription.seatCount)", systemImage: "person.3", isMonospaced: true)
                    }
                    NavigationLink {
                        ManageSubscriptionView()
                    } label: {
                        HStack {
                            Text("Manage membership").font(.brandCaption)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption2)
                        }
                        .foregroundStyle(Theme.primary)
                        .frame(minHeight: 30)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                }
                .padding(16)
                .featuredGlassCard()
            } else {
                // H1: full inclusions + fair-use limits shown before purchase,
                // rather than a bare "Subscribe" button.
                NavigationLink {
                    PlanCatalogView()
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "sparkles")
                            .font(.title2)
                            .foregroundStyle(Theme.emeraldLight)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Join VetCircuit Care").font(.brandHeadline)
                            Text("Free visits, priority slots and member pricing from \(CurrencyFormatter.rupees(PlanCatalogEntry.lowestHeadlineMonthlyMinorUnits))/month.")
                                .font(.brandCaption)
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                    .padding(16)
                    .featuredGlassCard(tint: Theme.emerald)
                    .contentShape(RoundedRectangle(cornerRadius: Spacing.corner, style: .continuous))
                }
                .buttonStyle(PressableStyle())
            }
        }
        .animation(Theme.crossFade, value: subscription?.id)
    }
}
