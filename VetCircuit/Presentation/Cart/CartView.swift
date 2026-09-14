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
    // E5: loyalty point redemption converts into wallet credit, which the
    // toggle above already spends at quote time — this just moves points.
    var loyaltyPoints = 0
    var redeemPointsInput = ""
    var redeemMessage: String?
    /// E9: reuse a saved gateway-tokenized card/UPI method instead of
    /// re-entering one each time. Purely a UI selection today — the actual
    /// hosted checkout URL flow (StartCheckoutUseCase) doesn't yet take a
    /// payment-method parameter, same gap noted on PaymentRepository.
    var selectedPaymentMethodId: UUID?

    // E6-E10/G6: the real checkout pipeline. `checkoutURL` drives the
    // hosted-checkout sheet; `pendingVisit` is the (unpaid, `.requested`)
    // visit created the moment checkout starts, kept around so a
    // dismissed/pending/failed payment can be resumed rather than the
    // booking silently vanishing; `confirmedVisit` is set once payment
    // actually succeeds and the visit is confirmed + linked to it.
    var checkoutURL: URL?
    /// E8: the customer's choice at checkout — pay now (prepaid, via
    /// `checkoutURL`) or pay after the visit (cash/UPI to the vet on-site).
    var payAfterVisit = false
    private(set) var pendingVisit: Visit?
    var confirmedVisit: Visit?
    var isCheckingOut = false
    private(set) var canRetryPayment = false
    private var lastQuote: Quote?
    private var retryAttempts = 0
    private var checkoutIdempotencyKey = UUID().uuidString

    private let manageCartUseCase = DependencyContainer.shared.manageCartUseCase()
    private let getQuoteUseCase = DependencyContainer.shared.getQuoteUseCase()
    private let getCatalogUseCase = DependencyContainer.shared.getCatalogUseCase()
    private let getWalletBalanceUseCase = DependencyContainer.shared.getWalletBalanceUseCase()
    private let getLoyaltyAccountUseCase = DependencyContainer.shared.getLoyaltyAccountUseCase()
    private let redeemLoyaltyPointsUseCase = DependencyContainer.shared.redeemLoyaltyPointsUseCase()
    private let circuitRepository = DependencyContainer.shared.circuitRepository
    private let bookingCheckoutUseCase = DependencyContainer.shared.bookingCheckoutUseCase()
    private let retryPaymentUseCase = DependencyContainer.shared.retryPaymentUseCase()
    private let paymentRepository = DependencyContainer.shared.paymentRepository
    private let sendTransactionalNotificationUseCase = DependencyContainer.shared.sendTransactionalNotificationUseCase()

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
            async let loyaltyResult = getLoyaltyAccountUseCase.execute(userId: userId)
            cart = try await cartResult
            services = try await vetServices + elderServices + physioServices
            walletBalanceMinorUnits = try await balanceResult
            loyaltyPoints = try await loyaltyResult.points
            couponCodeInput = cart?.couponCode ?? ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// E5: redeem loyalty points into wallet credit, then refresh both
    /// balances so the "use wallet balance" toggle immediately reflects it.
    func redeemPoints(userId: UUID) async {
        guard let points = Int(redeemPointsInput) else { return }
        do {
            let account = try await redeemLoyaltyPointsUseCase.execute(userId: userId, points: points)
            loyaltyPoints = account.points
            walletBalanceMinorUnits = try await getWalletBalanceUseCase.balance(userId: userId)
            redeemPointsInput = ""
            redeemMessage = "Redeemed \(points) points into your wallet."
            Haptics.success()
        } catch {
            redeemMessage = error.localizedDescription
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

    /// E1: change quantity on a cart line.
    func setQuantity(_ quantity: Int, for item: CartItem) async {
        guard let cart else { return }
        do {
            self.cart = try await manageCartUseCase.setQuantity(quantity, forItemId: item.id, in: cart)
            quote = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// E1: clear the whole cart in one action.
    func clearCart(userId: UUID) async {
        do {
            try await manageCartUseCase.clear(userId: userId)
            cart = Cart(id: cart?.id ?? UUID(), userId: userId)
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

    /// The cart is currently priced for exactly one appointment slot on one
    /// circuit (`Cart.circuitId`/`slotId`), which is what `BookVisitUseCase`
    /// needs — but `createVisit` (still) books a single pet per visit. A
    /// cart with more than one distinct pet across its items is a real,
    /// named gap this pipeline doesn't close: it books the *first* item's
    /// first pet and the rest of the cart's pets are left out. Multi-pet,
    /// single-visit booking is tracked as a separate structural change to
    /// `VisitRepository.createVisit`, out of scope here.
    var primaryPetId: UUID? { cart?.items.first?.petIds.first }
    /// D4: the same "books only the first item" limitation `primaryPetId`
    /// already documents — so the visit this pipeline actually books is
    /// tagged with *that* item's service/variant/redemption, not lost
    /// entirely the way it was before this existed.
    private var primaryItem: CartItem? { cart?.items.first }

    /// E6+E8+E10+G6: get (or reuse) a real signed quote, book the visit as
    /// pending payment against it, and open the hosted-checkout sheet.
    func proceedToCheckout(user: User) async {
        guard let cart else { return }
        guard let circuitId = cart.circuitId, let slotId = cart.slotId else {
            errorMessage = "Pick a time slot from a circuit before checking out."
            return
        }
        guard let petId = primaryPetId else {
            errorMessage = "Add a pet to a cart item before checking out."
            return
        }
        isCheckingOut = true
        errorMessage = nil
        defer { isCheckingOut = false }
        do {
            var currentQuote = quote
            if currentQuote == nil || currentQuote?.isExpired == true {
                currentQuote = try await getQuoteUseCase.execute(cart: cart, useWalletBalance: useWalletBalance)
                quote = currentQuote
            }
            guard let quote = currentQuote else { return }
            let circuit = try await circuitRepository.circuit(id: circuitId)
            guard let slot = circuit.schedule.first(where: { $0.id == slotId }) else {
                throw DomainError.notFound("Time slot")
            }
            lastQuote = quote
            if payAfterVisit {
                // E8: booked and confirmed immediately — no hosted checkout,
                // no webhook to wait on.
                let visit = try await bookingCheckoutUseCase.startPayAfterVisit(
                    petId: petId, vetId: circuit.vetId, circuitId: circuitId, slot: slot,
                    quote: quote, idempotencyKey: checkoutIdempotencyKey,
                    serviceId: primaryItem?.serviceId, variantId: primaryItem?.variantId,
                    packageRedemptionId: primaryItem?.packageRedemptionId
                )
                confirmedVisit = visit
                await settleCartAfterBooking(bookedItem: primaryItem, user: user)
                _ = try? await sendTransactionalNotificationUseCase.execute(
                    user: user, category: .visitConfirmed,
                    body: "Your visit is confirmed for \(visit.scheduledAt.formatted(date: .abbreviated, time: .shortened)). Pay the vet on-site."
                )
            } else {
                let session = try await bookingCheckoutUseCase.start(
                    petId: petId, vetId: circuit.vetId, circuitId: circuitId, slot: slot,
                    quote: quote, idempotencyKey: checkoutIdempotencyKey,
                    serviceId: primaryItem?.serviceId, variantId: primaryItem?.variantId,
                    packageRedemptionId: primaryItem?.packageRedemptionId
                )
                pendingVisit = session.visit
                checkoutURL = session.checkoutURL
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Runs once the checkout sheet is dismissed — covers a completed
    /// payment, a failed one, or the customer just backing out.
    func resolveCheckout(user: User) async {
        guard let visit = pendingVisit else { return }
        do {
            let (updatedVisit, outcome) = try await bookingCheckoutUseCase.resolve(visitId: visit.id, priorAttempts: retryAttempts)
            switch outcome {
            case .confirmVisit:
                pendingVisit = nil
                canRetryPayment = false
                confirmedVisit = updatedVisit
                // The order this visit came from is done — clear it (or, for
                // a package purchase with more entitlements left to book,
                // just the line that was actually booked; see
                // `settleCartAfterBooking`) rather than re-showing paid items.
                await settleCartAfterBooking(bookedItem: primaryItem, user: user)
                // E10: order confirmation receipt (push, or SMS per J8's
                // fallback) — best-effort, the booking already succeeded.
                _ = try? await sendTransactionalNotificationUseCase.execute(
                    user: user, category: .visitConfirmed,
                    body: "Your visit is confirmed for \(updatedVisit.scheduledAt.formatted(date: .abbreviated, time: .shortened))."
                )
            case .awaitingPayment:
                pendingVisit = updatedVisit
                errorMessage = "We haven't heard back from the payment yet. Your cart and slot are still held — resume checkout below when you're ready."
            case .paymentFailed(let canRetry, let reason):
                pendingVisit = updatedVisit
                retryAttempts += 1
                canRetryPayment = canRetry
                errorMessage = reason ?? "That payment didn't go through."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// D4: a package purchase can expand into several cart lines that each
    /// represent a *separate future booking* against the same
    /// `PackageRedemption` (e.g. 4 consult-visit lines, booked one at a time,
    /// each at its own slot) — but this pipeline still only ever books
    /// `primaryItem` per checkout (the pre-existing "cart is one
    /// circuit/one slot" limitation `primaryPetId` documents above). Wiping
    /// the *whole* cart on success, as a plain à la carte checkout always
    /// did, would silently discard the other, not-yet-booked package lines
    /// along with their still-valid entitlements. So: remove only the item
    /// that was actually booked, and fall back to a full clear only once
    /// nothing is left — preserving the pre-existing "always start the next
    /// order from empty" behavior for every non-package cart exactly as
    /// before (a single-item cart has nothing left after removing that item).
    private func settleCartAfterBooking(bookedItem: CartItem?, user: User) async {
        if let bookedItem, let cart, cart.items.count > 1 {
            self.cart = try? await manageCartUseCase.removeItem(id: bookedItem.id, from: cart)
        } else {
            try? await manageCartUseCase.clear(userId: user.id)
            self.cart = Cart(id: UUID(), userId: user.id, addressId: nil, circuitId: nil, slotId: nil)
        }
        self.quote = nil
    }

    /// G3: re-opens checkout for the same pending visit, gated by
    /// `PaymentRetryPolicy` via `RetryPaymentUseCase`.
    func retryCheckout() async {
        guard let visit = pendingVisit, let quote = lastQuote else { return }
        guard !quote.isExpired else {
            errorMessage = "This price quote has expired — refresh the price and check out again."
            canRetryPayment = false
            return
        }
        isCheckingOut = true
        errorMessage = nil
        defer { isCheckingOut = false }
        do {
            guard let paymentId = try await paymentRepository.latestPaymentId(forVisit: visit.id) else {
                errorMessage = "Couldn't find the previous payment attempt — please check out again."
                return
            }
            checkoutURL = try await retryPaymentUseCase.execute(visitId: visit.id, paymentId: paymentId, quote: quote, priorAttempts: retryAttempts)
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
                                price: viewModel.variant(for: item).map { CurrencyFormatter.rupees($0.priceMinorUnits * item.quantity) } ?? "",
                                quantity: Binding(
                                    get: { item.quantity },
                                    set: { newValue in Task { await viewModel.setQuantity(newValue, for: item) } }
                                )
                            ) {
                                Haptics.warning()
                                Task { await viewModel.remove(item) }
                            }
                        }

                        if cart.items.count > 1, let user = session.currentUser {
                            Button(role: .destructive) {
                                Haptics.warning()
                                Task { await viewModel.clearCart(userId: user.id) }
                            } label: {
                                Label("Clear cart", systemImage: "trash")
                            }
                            .font(.brandCaption)
                        }

                        CouponEntryRow(code: $viewModel.couponCodeInput, message: viewModel.couponMessage) {
                            viewModel.applyCoupon()
                        }

                        SavedPaymentMethodPickerRow(selectedMethodId: $viewModel.selectedPaymentMethodId)

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

                        // E5: loyalty point redemption at checkout.
                        if viewModel.loyaltyPoints >= LoyaltyRedemptionPolicy.minimumRedeemablePoints, let user = session.currentUser {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("\(viewModel.loyaltyPoints) loyalty points available").font(.brandBody)
                                HStack {
                                    TextField("Points to redeem", text: $viewModel.redeemPointsInput)
                                        .keyboardType(.numberPad)
                                        .textFieldStyle(.roundedBorder)
                                    Button("Redeem") { Task { await viewModel.redeemPoints(userId: user.id) } }
                                        .disabled(Int(viewModel.redeemPointsInput) == nil)
                                }
                                if let redeemMessage = viewModel.redeemMessage {
                                    Text(redeemMessage).font(.brandCaption).foregroundStyle(.secondary)
                                }
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
                            if viewModel.canRetryPayment {
                                PrimaryButton(title: "Retry payment", isLoading: viewModel.isCheckingOut) {
                                    Task { await viewModel.retryCheckout() }
                                }
                            }
                        }

                        PrimaryButton(title: viewModel.quote == nil ? "Get price" : "Refresh price", isLoading: viewModel.isQuoting) {
                            Task { await viewModel.getQuote() }
                        }

                        // E6+E8: only once a real signed quote is in hand
                        // does checkout become available — never a
                        // client-computed amount going to checkout.
                        if viewModel.quote != nil {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("How do you want to pay?").font(.brandBody.bold())
                                Picker("Payment", selection: $viewModel.payAfterVisit) {
                                    Text("Pay now").tag(false)
                                    Text("Pay after visit").tag(true)
                                }
                                .pickerStyle(.segmented)
                                if viewModel.payAfterVisit {
                                    Text("Cash or UPI to the vet on-site.")
                                        .font(.brandCaption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            PrimaryButton(title: viewModel.payAfterVisit ? "Book — pay after visit" : "Book & pay", isLoading: viewModel.isCheckingOut) {
                                guard let user = session.currentUser else { return }
                                Task { await viewModel.proceedToCheckout(user: user) }
                            }
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
        .sheet(item: $viewModel.checkoutURL, onDismiss: {
            guard let user = session.currentUser else { return }
            Task { await viewModel.resolveCheckout(user: user) }
        }) { url in
            CheckoutWebView(url: url)
        }
        .navigationDestination(item: $viewModel.confirmedVisit) { visit in
            BookingConfirmedView(visit: visit)
        }
    }
}

private struct CartItemRow: View {
    let name: String
    let variantName: String
    let price: String
    // E1: change quantity — repeats this exact line item, distinct from
    // D6's per-line pet multi-select.
    @Binding var quantity: Int
    let onRemove: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.brandHeadline)
                Text(variantName).font(.brandCaption).foregroundStyle(.secondary)
                Stepper("Qty: \(quantity)", value: $quantity, in: 1...20)
                    .font(.brandCaption)
                    .fixedSize()
                    .accessibilityLabel("Quantity")
                    .accessibilityValue("\(quantity)")
            }
            Spacer()
            Text(price).font(.brandBody).foregroundStyle(.secondary)
                .accessibilityLabel("Price \(price)")
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.neutral)
            }
            .accessibilityLabel("Remove \(name) from cart")
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
