import SwiftUI

/// H1: plan catalog with visible inclusions & fair-use limits, shown before
/// purchase. Subscribing routes through `SubscribeToPlanUseCase` and hands
/// the resulting hosted-checkout URL to `CheckoutWebView`, the same pattern
/// `ProfileView`'s subscribe flow already used.
@Observable
@MainActor
final class PlanCatalogViewModel {
    var isSubscribing: Set<Subscription.PlanType> = []
    var errorMessage: String?
    var checkoutURL: URL?

    private let subscribeToPlanUseCase = DependencyContainer.shared.subscribeToPlanUseCase()

    func subscribe(userId: UUID, plan: Subscription.PlanType, seatCount: Int = 1) async {
        isSubscribing.insert(plan)
        errorMessage = nil
        defer { isSubscribing.remove(plan) }
        do {
            checkoutURL = try await subscribeToPlanUseCase.execute(userId: userId, plan: plan, seatCount: seatCount)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct PlanCatalogView: View {
    @Environment(SessionStore.self) private var session
    @State private var viewModel = PlanCatalogViewModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Membership").brandEyebrow()
                    Text("Pay less, wait less")
                        .font(.brandTitle)
                        .brandDisplayText()
                    Text("Members get included visits, priority slots on every circuit, and member pricing on everything else. Cancel any time — there's no lock-in.")
                        .font(.brandCallout)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 4)

                ForEach(PlanCatalogEntry.all.filter { !$0.planType.isBulk }) { entry in
                    PlanCatalogCard(
                        entry: entry,
                        isSubscribing: viewModel.isSubscribing.contains(entry.planType)
                    ) {
                        Haptics.tap()
                        guard let user = session.currentUser else { return }
                        Task { await viewModel.subscribe(userId: user.id, plan: entry.planType) }
                    }
                }

                NavigationLink {
                    CorporatePlanView { seatCount in
                        guard let user = session.currentUser else { return }
                        Task { await viewModel.subscribe(userId: user.id, plan: .corporate, seatCount: seatCount) }
                    }
                } label: {
                    ActionRow2(
                        title: "Corporate / RWA bulk plan",
                        subtitle: "One plan covering every household in your complex or office",
                        systemImage: "building.2.fill"
                    )
                }
                .buttonStyle(PressableStyle())

                if let errorMessage = viewModel.errorMessage {
                    ErrorBanner(message: errorMessage)
                }
            }
            .padding()
        }
        .auroraScreenBackground()
        .navigationTitle("Plans")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $viewModel.checkoutURL) { url in
            CheckoutWebView(url: url)
        }
    }
}

private struct PlanCatalogCard: View {
    let entry: PlanCatalogEntry
    let isSubscribing: Bool
    let onSubscribe: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.planType.displayName)
                    .font(.brandTitle3)
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(CurrencyFormatter.rupees(entry.priceMinorUnits))
                        .font(.brandMono(.title3, weight: .bold))
                        .foregroundStyle(Theme.primary)
                        .brandDisplayText()
                    Text(entry.billingPeriodLabel)
                        .font(.brandCaption2)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            Divider().opacity(0.4)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(entry.inclusions, id: \.self) { inclusion in
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.success)
                        Text(inclusion)
                            .font(.brandCallout)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }

            // H1: fair-use limit stated plainly, before commitment — not
            // buried in terms the customer reads after paying.
            CalloutNote(text: entry.fairUseSummary, systemImage: "info.circle.fill", tint: Theme.warning)

            PrimaryButton(title: "Subscribe", isLoading: isSubscribing, action: onSubscribe)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .featuredGlassCard()
    }
}

private struct ActionRow2: View {
    let title: String
    var subtitle: String? = nil
    let systemImage: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.primary)
                .frame(width: 34, height: 34)
                .background(Theme.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.brandHeadline).foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.brandCaption2)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Theme.textTertiary)
        }
        .padding(16)
        .glassCard(cornerRadius: 16)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

#Preview {
    NavigationStack { PlanCatalogView() }
        .environment(SessionStore())
}
