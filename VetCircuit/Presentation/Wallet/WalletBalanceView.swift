import SwiftUI

@Observable
@MainActor
final class WalletBalanceViewModel {
    var balanceMinorUnits: Int?
    var entries: [WalletLedgerEntry] = []
    var isLoading = false
    var errorMessage: String?

    private let getWalletBalanceUseCase = DependencyContainer.shared.getWalletBalanceUseCase()

    func load(userId: UUID) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            async let balanceResult = getWalletBalanceUseCase.balance(userId: userId)
            async let entriesResult = getWalletBalanceUseCase.entries(userId: userId)
            balanceMinorUnits = try await balanceResult
            entries = try await entriesResult
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// G6: read-only view of the append-only wallet ledger — there is
/// deliberately no "add funds" button here; credits only ever arrive via
/// refunds, compensation, or a tip/promo mechanism (plan §G6 note).
struct WalletBalanceView: View {
    @Environment(SessionStore.self) private var session
    @State private var viewModel = WalletBalanceViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Wallet balance").font(.brandCaption).foregroundStyle(Theme.textSecondary)
                        Text(CurrencyFormatter.rupees(viewModel.balanceMinorUnits ?? 0))
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.primary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let errorMessage = viewModel.errorMessage {
                    ErrorBanner(message: errorMessage)
                }

                if viewModel.isLoading && viewModel.entries.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else if viewModel.entries.isEmpty {
                    EmptyStateView(systemImage: "wallet.pass", title: "No activity yet",
                                   message: "Credits from refunds or offers show up here.")
                } else {
                    Text("Recent activity").font(.brandHeadline)
                    ForEach(viewModel.entries) { entry in
                        WalletEntryRow(entry: entry)
                    }
                }
            }
            .padding()
        }
        .auroraScreenBackground()
        .floatingTabBarInset()
        .navigationTitle("Wallet")
        .navigationBarTitleDisplayMode(.inline)
        .task { if let user = session.currentUser { await viewModel.load(userId: user.id) } }
    }
}

private struct WalletEntryRow: View {
    let entry: WalletLedgerEntry
    private var isCredit: Bool { entry.amountMinorUnits >= 0 }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.reason).font(.brandBody)
                Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.brandCaption).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Text((isCredit ? "+" : "-") + CurrencyFormatter.rupees(abs(entry.amountMinorUnits)))
                .font(.brandHeadline)
                .foregroundStyle(isCredit ? Theme.success : Theme.danger)
        }
        .padding()
        .glassCard()
    }
}

#Preview {
    NavigationStack { WalletBalanceView().environment(SessionStore()) }
}
