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
                    ActionRow2(title: "Corporate / RWA bulk plan", systemImage: "building.2.fill")
                }
                .buttonStyle(PressableStyle())

                if let errorMessage = viewModel.errorMessage {
                    ErrorBanner(message: errorMessage)
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
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
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(entry.planType.displayName).font(.brandHeadline)
                    Spacer()
                    Text(CurrencyFormatter.rupees(entry.priceMinorUnits)).font(.brandHeadline).foregroundStyle(Theme.primary)
                }
                Text(entry.billingPeriodLabel).font(.brandCaption).foregroundStyle(.secondary)

                Divider()

                ForEach(entry.inclusions, id: \.self) { inclusion in
                    Label(inclusion, systemImage: "checkmark.circle.fill")
                        .font(.brandCaption)
                        .foregroundStyle(.secondary)
                }

                // H1: fair-use limit stated plainly, before commitment.
                Label(entry.fairUseSummary, systemImage: "info.circle")
                    .font(.brandCaption)
                    .foregroundStyle(Theme.warning)

                PrimaryButton(title: "Subscribe", isLoading: isSubscribing, action: onSubscribe)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ActionRow2: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage).foregroundStyle(Theme.primary)
            Text(title).font(.brandHeadline).foregroundStyle(.primary)
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: Theme.cardShadow, radius: 8, y: 3)
    }
}

#Preview {
    NavigationStack { PlanCatalogView() }
        .environment(SessionStore())
}
