import SwiftUI

/// E9: saved payment methods. This app never talks to a real payment
/// gateway SDK yet (see PaymentRepository / StartCheckoutUseCase, still a
/// hosted-checkout-URL flow), so "Add" here fabricates a believable
/// gateway-tokenized card — exactly what a real gateway's tokenization
/// step would hand back, without this app ever touching a PAN/CVV.
@Observable
@MainActor
final class PaymentMethodsViewModel {
    var methods: [SavedPaymentMethod] = []
    var isLoading = false
    var errorMessage: String?

    private let useCase = DependencyContainer.shared.manageSavedPaymentMethodsUseCase()

    func load(userId: UUID) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            methods = try await useCase.list(userId: userId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Stands in for the gateway SDK's tokenize-a-card step. In a real
    /// integration, `gatewayTokenId`/`displayLabel` come back from that SDK
    /// call — this use case (and this app) never sees the underlying PAN.
    func addMockCard(userId: UUID) async {
        let suffix = String(format: "%04d", Int.random(in: 0...9999))
        let brand = ["Visa", "Mastercard", "RuPay"].randomElement() ?? "Visa"
        do {
            try await useCase.save(
                userId: userId,
                gatewayTokenId: "tok_mock_\(UUID().uuidString.prefix(12))",
                displayLabel: "\(brand) •••• \(suffix)",
                makeDefault: methods.isEmpty
            )
            await load(userId: userId)
            Haptics.success()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }

    func remove(_ method: SavedPaymentMethod, userId: UUID) async {
        do {
            try await useCase.remove(id: method.id)
            await load(userId: userId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setDefault(_ method: SavedPaymentMethod, userId: UUID) async {
        do {
            try await useCase.setDefault(id: method.id, userId: userId)
            await load(userId: userId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct PaymentMethodsView: View {
    @Environment(SessionStore.self) private var session
    @State private var viewModel = PaymentMethodsViewModel()

    var body: some View {
        List {
            if let errorMessage = viewModel.errorMessage {
                ErrorBanner(message: errorMessage)
            }
            Section {
                ForEach(viewModel.methods) { method in
                    HStack {
                        Image(systemName: "creditcard.fill").foregroundStyle(Theme.primary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(method.displayLabel).font(.brandBody)
                            Text("Added \(method.createdAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 8)
                        if method.isDefault {
                            TagChip(text: "Default", systemImage: "star.fill", tint: Theme.success)
                        } else {
                            // "Make default" was swipe-only, and the row's
                            // contentShape had no button behind it — tapping
                            // a card did nothing at all.
                            PillButton(title: "Make default", systemImage: "star") {
                                guard let user = session.currentUser else { return }
                                Task { await viewModel.setDefault(method, userId: user.id) }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(method.displayLabel + (method.isDefault ? ", default" : ""))
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            guard let user = session.currentUser else { return }
                            Task { await viewModel.remove(method, userId: user.id) }
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                        if !method.isDefault {
                            Button {
                                guard let user = session.currentUser else { return }
                                Task { await viewModel.setDefault(method, userId: user.id) }
                            } label: {
                                Label("Make default", systemImage: "star")
                            }
                            .tint(Theme.primary)
                        }
                    }
                }
                if viewModel.isLoading && viewModel.methods.isEmpty {
                    ForEach(0..<2, id: \.self) { _ in
                        ShimmerView(cornerRadius: 12).frame(height: 44)
                    }
                } else if viewModel.methods.isEmpty {
                    EmptyStateView(
                        systemImage: "creditcard",
                        title: "No saved cards yet",
                        message: "Save a card and checkout becomes one tap — we only ever store your issuer's token, never the card number.",
                        actionTitle: "Add a card"
                    ) {
                        guard let user = session.currentUser else { return }
                        Task { await viewModel.addMockCard(userId: user.id) }
                    }
                    .listRowBackground(Color.clear)
                }
            } footer: {
                Text("Only a token from your card issuer is stored — VetCircuit never sees or stores your card number or CVV.")
                    .font(.caption2)
            }
        }
        // The aurora is the app's ground everywhere else; a List that keeps
        // its own opaque system background would read as a different app.
        .scrollContentBackground(.hidden)
        .auroraScreenBackground()
        .navigationTitle("Payment methods")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    guard let user = session.currentUser else { return }
                    Task { await viewModel.addMockCard(userId: user.id) }
                } label: {
                    Image(systemName: "plus")
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Add payment method")
            }
        }
        .task { if let user = session.currentUser { await viewModel.load(userId: user.id) } }
    }
}

/// Compact picker embedded in checkout (CartView) so a saved method can be
/// reused instead of re-entering one each time.
struct SavedPaymentMethodPickerRow: View {
    @Environment(SessionStore.self) private var session
    @Binding var selectedMethodId: UUID?
    @State private var viewModel = PaymentMethodsViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Payment method").font(.brandHeadline)
                Spacer()
                NavigationLink("Manage") { PaymentMethodsView() }
                    .font(.brandCaption)
            }
            if viewModel.methods.isEmpty {
                Text("No saved cards — you'll enter payment details at checkout.")
                    .font(.brandCaption).foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.methods) { method in
                    Button {
                        Haptics.selection()
                        withAnimation(Theme.springQuick) { selectedMethodId = method.id }
                    } label: {
                        HStack {
                            Text(method.displayLabel).font(.brandBody).foregroundStyle(.primary)
                            Spacer()
                        }
                        .padding(10)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(PressableStyle())
                    .selectable(isSelected: selectedMethodId == method.id, cornerRadius: 12)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(selectedMethodId == method.id ? .isSelected : [])
                }
            }
        }
        .padding()
        .glassCard()
        .task {
            if let user = session.currentUser {
                await viewModel.load(userId: user.id)
                if selectedMethodId == nil {
                    selectedMethodId = viewModel.methods.first(where: { $0.isDefault })?.id
                }
            }
        }
    }
}

#Preview {
    NavigationStack { PaymentMethodsView().environment(SessionStore()) }
}
