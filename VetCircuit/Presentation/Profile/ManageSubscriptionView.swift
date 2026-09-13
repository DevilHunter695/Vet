import SwiftUI

/// H3: upgrade/downgrade/pause/cancel + next renewal, all funnelled through
/// `ManageSubscriptionUseCase` so the validation in `SubscriptionManagementPolicy`
/// is the only place that decides what's allowed — this view just presents it.
@Observable
@MainActor
final class ManageSubscriptionViewModel {
    var subscription: Subscription?
    var errorMessage: String?
    var pendingAction: PendingAction?

    /// Illustrative individual-plan pricing for the confirmation copy (plan
    /// §9 rule 3: consequences stated in money and time) — mirrors
    /// CorporatePlanView's per-seat placeholder, since there's no live
    /// pricing catalog for subscriptions yet (plan §H1 is still 🔨).
    static func priceMinorUnits(for plan: Subscription.PlanType) -> Int {
        switch plan {
        case .monthly: return 59900
        case .quarterly: return 159900
        case .annual: return 549900
        case .corporate: return 0
        }
    }

    struct PendingAction: Identifiable {
        enum Kind { case upgrade(Subscription.PlanType), downgrade(Subscription.PlanType), pause, cancel }
        let kind: Kind
        var id: String {
            switch kind {
            case .upgrade(let p): return "upgrade-\(p.rawValue)"
            case .downgrade(let p): return "downgrade-\(p.rawValue)"
            case .pause: return "pause"
            case .cancel: return "cancel"
            }
        }
    }

    private let manageSubscriptionUseCase = DependencyContainer.shared.manageSubscriptionUseCase()
    private let subscriptionRepository = DependencyContainer.shared.subscriptionRepository

    func load(userId: UUID) async {
        do {
            subscription = try await subscriptionRepository.currentSubscription(userId: userId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func confirm(userId: UUID) async {
        guard let subscriptionId = subscription?.id, let pendingAction else { return }
        do {
            switch pendingAction.kind {
            case .upgrade(let plan):
                subscription = try await manageSubscriptionUseCase.upgrade(subscriptionId: subscriptionId, userId: userId, to: plan)
            case .downgrade(let plan):
                subscription = try await manageSubscriptionUseCase.downgrade(subscriptionId: subscriptionId, userId: userId, to: plan)
            case .pause:
                subscription = try await manageSubscriptionUseCase.pause(subscriptionId: subscriptionId, userId: userId)
            case .cancel:
                try await manageSubscriptionUseCase.cancel(subscriptionId: subscriptionId, userId: userId)
                subscription?.status = .cancelled
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        self.pendingAction = nil
    }

    func resume(userId: UUID) async {
        guard let subscriptionId = subscription?.id else { return }
        do {
            subscription = try await manageSubscriptionUseCase.resume(subscriptionId: subscriptionId, userId: userId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct ManageSubscriptionView: View {
    @Environment(SessionStore.self) private var session
    @State private var viewModel = ManageSubscriptionViewModel()

    var body: some View {
        List {
            if let subscription = viewModel.subscription {
                Section("Current plan") {
                    LabeledContent("Plan", value: subscription.planType.displayName)
                    LabeledContent("Status", value: subscription.status.rawValue.capitalized)
                    LabeledContent("Renews", value: subscription.renewalDate.formatted(date: .abbreviated, time: .omitted))
                    if subscription.planType.isBulk {
                        LabeledContent("Seats", value: "\(subscription.seatCount)")
                    }
                }
                .appearAnimation()

                if subscription.status == .active {
                    Section("Change plan") {
                        ForEach(upgradeTargets(from: subscription.planType), id: \.self) { plan in
                            Button {
                                Haptics.tap()
                                viewModel.pendingAction = .init(kind: .upgrade(plan))
                            } label: {
                                Label("Upgrade to \(plan.displayName)", systemImage: "arrow.up.circle")
                            }
                        }
                        ForEach(downgradeTargets(from: subscription.planType), id: \.self) { plan in
                            Button {
                                Haptics.tap()
                                viewModel.pendingAction = .init(kind: .downgrade(plan))
                            } label: {
                                Label("Downgrade to \(plan.displayName)", systemImage: "arrow.down.circle")
                            }
                        }
                        if upgradeTargets(from: subscription.planType).isEmpty && downgradeTargets(from: subscription.planType).isEmpty {
                            Text("No plan changes available for a corporate/RWA plan here — see the corporate plan screen.")
                                .font(.brandCaption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section {
                        Button {
                            Haptics.tap()
                            viewModel.pendingAction = .init(kind: .pause)
                        } label: {
                            Label("Pause subscription", systemImage: "pause.circle")
                        }
                    }
                } else if subscription.status == .paused {
                    Section {
                        Button {
                            Haptics.confirm()
                            Task { if let user = session.currentUser { await viewModel.resume(userId: user.id) } }
                        } label: {
                            Label("Resume subscription", systemImage: "play.circle")
                        }
                    } footer: {
                        Text("Paused: no charges until you resume. Your benefits are on hold too.")
                    }
                }

                if subscription.status != .cancelled {
                    Section {
                        Button(role: .destructive) {
                            Haptics.warning()
                            viewModel.pendingAction = .init(kind: .cancel)
                        } label: {
                            Label("Cancel subscription", systemImage: "xmark.circle")
                        }
                        .tint(Theme.danger)
                    }
                }
            } else {
                EmptyStateView(systemImage: "creditcard", title: "No active subscription",
                               message: "Subscribe to a plan from your profile to manage it here.")
            }

            if let errorMessage = viewModel.errorMessage {
                Section { Text(errorMessage).foregroundStyle(Theme.danger) }
            }
        }
        .navigationTitle("Manage subscription")
        .navigationBarTitleDisplayMode(.inline)
        .task { if let user = session.currentUser { await viewModel.load(userId: user.id) } }
        .confirmationDialog(
            "Are you sure?",
            isPresented: Binding(get: { viewModel.pendingAction != nil }, set: { if !$0 { viewModel.pendingAction = nil } }),
            presenting: viewModel.pendingAction
        ) { pending in
            Button(confirmTitle(pending), role: isDestructive(pending) ? .destructive : nil) {
                Task { if let user = session.currentUser { await viewModel.confirm(userId: user.id) } }
            }
            Button("Never mind", role: .cancel) {}
        } message: { pending in
            Text(consequenceCopy(pending, subscription: viewModel.subscription))
        }
    }

    private func upgradeTargets(from plan: Subscription.PlanType) -> [Subscription.PlanType] {
        guard !plan.isBulk else { return [] }
        let ladder: [Subscription.PlanType] = [.monthly, .quarterly, .annual]
        guard let index = ladder.firstIndex(of: plan) else { return [] }
        return Array(ladder[(index + 1)...])
    }

    private func downgradeTargets(from plan: Subscription.PlanType) -> [Subscription.PlanType] {
        guard !plan.isBulk else { return [] }
        let ladder: [Subscription.PlanType] = [.monthly, .quarterly, .annual]
        guard let index = ladder.firstIndex(of: plan) else { return [] }
        return Array(ladder[..<index])
    }

    private func confirmTitle(_ pending: ManageSubscriptionViewModel.PendingAction) -> String {
        switch pending.kind {
        case .upgrade(let plan): return "Upgrade to \(plan.displayName)"
        case .downgrade(let plan): return "Downgrade to \(plan.displayName)"
        case .pause: return "Pause subscription"
        case .cancel: return "Cancel subscription"
        }
    }

    private func isDestructive(_ pending: ManageSubscriptionViewModel.PendingAction) -> Bool {
        switch pending.kind {
        case .cancel, .pause: return true
        default: return false
        }
    }

    /// Plan §9 rule 3: state the consequence in money and time, never a bare "are you sure".
    private func consequenceCopy(_ pending: ManageSubscriptionViewModel.PendingAction, subscription: Subscription?) -> String {
        guard let subscription else { return "" }
        let renewalText = subscription.renewalDate.formatted(date: .abbreviated, time: .omitted)
        switch pending.kind {
        case .upgrade(let plan):
            let newPrice = CurrencyFormatter.rupees(ManageSubscriptionViewModel.priceMinorUnits(for: plan))
            return "You'll be charged \(newPrice) at your next renewal on \(renewalText), and your plan becomes \(plan.displayName) immediately."
        case .downgrade(let plan):
            let newPrice = CurrencyFormatter.rupees(ManageSubscriptionViewModel.priceMinorUnits(for: plan))
            return "Your plan changes to \(plan.displayName) now; you'll be charged \(newPrice) at your next renewal on \(renewalText)."
        case .pause:
            return "No charges while paused, and no visits/credits accrue either. You can resume any time before \(renewalText); resuming later than that restarts your billing cycle."
        case .cancel:
            return "Your plan stays active until \(renewalText), then it will not renew. No refund applies for the current period."
        }
    }
}

#Preview {
    NavigationStack { ManageSubscriptionView() }
        .environment(SessionStore())
}
