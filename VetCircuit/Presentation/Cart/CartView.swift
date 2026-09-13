import SwiftUI

@Observable
@MainActor
final class CartViewModel {
    var cart: Cart?
    var services: [Service] = []
    var quote: Quote?
    var isLoading = false
    var isQuoting = false
    var errorMessage: String?

    // E4: the field just holds intent; the coupon is only ever validated
    // (and its discount computed) inside the signed quote, never locally.
    var couponCodeInput = ""
    var couponMessage: String?

    // G6: customer's toggle intent — the real balance is fetched fresh here
    // so the label can show a rupee amount, but the *applied* amount always
    // comes back from the quote, never trusted from this fetch.
    var walletBalanceMinorUnits = 0
    var useWalletBalance = false

    private let manageCartUseCase = DependencyContainer.shared.manageCartUseCase()
    private let getQuoteUseCase = DependencyContainer.shared.getQuoteUseCase()
    private let getCatalogUseCase = DependencyContainer.shared.getCatalogUseCase()
    private let getWalletBalanceUseCase = DependencyContainer.shared.getWalletBalanceUseCase()

    func load(userId: UUID) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            async let cartResult = manageCartUseCase.current(userId: userId)
            async let vetServices = getCatalogUseCase.execute(vertical: .vet)
            async let elderServices = getCatalogUseCase.execute(vertical: .elderCare)
            async let physioServices = getCatalogUseCase.execute(vertical: .physio)
            async let balanceResult = getWalletBalanceUseCase.balance(userId: userId)
            cart = try await cartResult
            services = try await vetServices + elderServices + physioServices
            walletBalanceMinorUnits = try await balanceResult
            couponCodeInput = cart?.couponCode ?? ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func remove(_ item: CartItem) async {
        guard let cart else { return }
        do {
            self.cart = try await manageCartUseCase.removeItem(id: item.id, from: cart)
            quote = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func applyCoupon() {
        guard var cart else { return }
        let trimmed = couponCodeInput.trimmingCharacters(in: .whitespacesAndNewlines)
        cart.couponCode = trimmed.isEmpty ? nil : trimmed
        self.cart = cart
        couponMessage = trimmed.isEmpty ? nil : "Applied at checkout if valid — see the breakdown below."
        quote = nil
    }

    /// E3: transparent, itemized price breakdown — non-negotiable for trust
    /// per plan §9. This is the *only* place a price appears; it comes back
    /// from the server-signed quote, never computed here.
    func getQuote() async {
        guard let cart else { return }
        isQuoting = true
        errorMessage = nil
        defer { isQuoting = false }
        do {
            quote = try await getQuoteUseCase.execute(cart: cart, useWalletBalance: useWalletBalance)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func service(for item: CartItem) -> Service? { services.first { $0.id == item.serviceId } }
    func variant(for item: CartItem) -> ServiceVariant? { service(for: item)?.variants.first { $0.id == item.variantId } }
}

/// E1 (cart) + E3 (transparent, itemized price breakdown). Checkout/payment
/// (E7-E10) and the book_visit() transaction are still ahead in the gap list;
/// this screen gets selections into a real quote, which is the prerequisite.
struct CartView: View {
    @Environment(SessionStore.self) private var session
    @State private var viewModel = CartViewModel()

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.cart == nil {
                ProgressView()
            } else if let cart = viewModel.cart, cart.items.isEmpty {
                EmptyStateView(systemImage: "cart", title: "Your cart is empty",
                               message: "Add a service from the catalog to get a price.")
            } else if let cart = viewModel.cart {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(cart.items) { item in
                            CartItemRow(
                                name: viewModel.service(for: item)?.name ?? "Service",
                                variantName: viewModel.variant(for: item)?.name ?? "",
                                price: viewModel.variant(for: item).map { CurrencyFormatter.rupees($0.priceMinorUnits) } ?? ""
                            ) {
                                Haptics.warning()
                                Task { await viewModel.remove(item) }
                            }
                        }

                        CouponEntryRow(code: $viewModel.couponCodeInput, message: viewModel.couponMessage) {
                            viewModel.applyCoupon()
                        }

                        if viewModel.walletBalanceMinorUnits > 0 {
                            Toggle(isOn: Binding(
                                get: { viewModel.useWalletBalance },
                                set: { viewModel.useWalletBalance = $0; viewModel.quote = nil }
                            )) {
                                Text("Use \(CurrencyFormatter.rupees(viewModel.walletBalanceMinorUnits)) wallet balance")
                                    .font(.brandBody)
                            }
                            .padding()
                            .glassCard()
                        }

                        if let quote = viewModel.quote {
                            PriceBreakdownView(breakdown: quote.breakdown)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }

                        if let errorMessage = viewModel.errorMessage {
                            ErrorBanner(message: errorMessage)
                        }

                        PrimaryButton(title: viewModel.quote == nil ? "Get price" : "Refresh price", isLoading: viewModel.isQuoting) {
                            Task { await viewModel.getQuote() }
                        }
                    }
                    .padding()
                }
                .animation(Theme.crossFade, value: viewModel.quote)
            }
        }
        .navigationTitle("Cart")
        .navigationBarTitleDisplayMode(.inline)
        .task { if let user = session.currentUser { await viewModel.load(userId: user.id) } }
    }
}

private struct CartItemRow: View {
    let name: String
    let variantName: String
    let price: String
    let onRemove: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.brandHeadline)
                Text(variantName).font(.brandCaption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(price).font(.brandBody).foregroundStyle(.secondary)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.neutral)
            }
        }
        .padding()
        .glassCard()
    }
}

/// E3: itemized breakdown, displayed verbatim — plan §9 rule 1: "Price is
/// always visible before commitment, itemized, with taxes in the total."
struct PriceBreakdownView: View {
    let breakdown: PriceBreakdown

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(breakdown.lineItems) { item in
                    HStack {
                        Text(item.label).font(.brandBody).foregroundStyle(.secondary)
                        Spacer()
                        Text(item.amountMinorUnits < 0 ? "-\(CurrencyFormatter.rupees(-item.amountMinorUnits))" : CurrencyFormatter.rupees(item.amountMinorUnits))
                            .font(.brandBody)
                    }
                }
                Divider()
                HStack {
                    Text("Total").font(.brandHeadline)
                    Spacer()
                    Text(CurrencyFormatter.rupees(breakdown.totalMinorUnits)).font(.brandHeadline).foregroundStyle(Theme.primary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// E4: "Have a promo code?" — deliberately no client-side validity check;
/// the code is just carried on the cart and the server-signed quote is the
/// only place that says whether it actually discounted anything.
private struct CouponEntryRow: View {
    @Binding var code: String
    let message: String?
    let onApply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Have a promo code?", text: $code)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.brandBody)
                Button("Apply", action: onApply)
                    .font(.brandBody.bold())
                    .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let message {
                Text(message).font(.brandCaption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .glassCard()
    }
}

#Preview {
    NavigationStack { CartView().environment(SessionStore()) }
}
