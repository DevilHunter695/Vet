import SwiftUI

/// C6: what's included, duration, what to prepare, price, add-ons, FAQs —
/// the "showing details" screen that didn't exist at all before this.
struct ServiceDetailView: View {
    let service: Service
    let pet: Pet?

    @Environment(SessionStore.self) private var session
    @State private var selectedVariantId: UUID?
    @State private var isAddingToCart = false
    @State private var addedToCart = false
    @State private var errorMessage: String?

    private let manageCartUseCase = DependencyContainer.shared.manageCartUseCase()

    private var selectedVariant: ServiceVariant? {
        service.variants.first { $0.id == selectedVariantId } ?? service.variants.first
    }

    private func addToCart() async {
        guard let variant = selectedVariant, let pet, let userId = session.currentUser?.id else { return }
        isAddingToCart = true
        errorMessage = nil
        defer { isAddingToCart = false }
        do {
            let cart = try await manageCartUseCase.current(userId: userId)
            let item = CartItem(id: UUID(), serviceId: service.id, variantId: variant.id, petIds: [pet.id])
            _ = try await manageCartUseCase.addItem(item, to: cart)
            Haptics.success()
            withAnimation(Theme.springSoft) { addedToCart = true }
        } catch {
            Haptics.error()
            errorMessage = error.localizedDescription
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(service.category.displayName, systemImage: service.category.systemImage)
                        .font(.brandCaption).foregroundStyle(Theme.primary)
                    Text(service.name).font(.brandLargeTitle)
                    Text(service.summary).font(.brandBody).foregroundStyle(.secondary)
                }
                .appearAnimation()

                if let prepare = service.whatToPrepare {
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("What to prepare", systemImage: "checklist")
                                .font(.brandHeadline).foregroundStyle(Theme.primary)
                            Text(prepare).font(.brandBody)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .appearAnimation(delay: 0.05)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Choose a variant").font(.brandHeadline)
                    ForEach(service.variants) { variant in
                        VariantRow(variant: variant, isSelected: variant.id == selectedVariant?.id) {
                            Haptics.selection()
                            selectedVariantId = variant.id
                        }
                    }
                }
                .appearAnimation(delay: 0.1)

                if !service.addons.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Popular add-ons").font(.brandHeadline)
                        ForEach(service.addons) { addon in
                            HStack {
                                Text(addon.name).font(.brandBody)
                                Spacer()
                                Text(CurrencyFormatter.rupees(addon.priceMinorUnits))
                                    .font(.brandBody).foregroundStyle(.secondary)
                            }
                            .padding()
                            .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .shadow(color: Theme.cardShadow, radius: 6, y: 2)
                        }
                    }
                    .appearAnimation(delay: 0.15)
                }

                if service.eligibility.requiresPrescriberVet {
                    Label("Performed only by a VCI-registered veterinarian, not a para-vet.", systemImage: "checkmark.seal.fill")
                        .font(.brandCaption)
                        .foregroundStyle(Theme.inProgress)
                        .appearAnimation(delay: 0.2)
                }

                if let errorMessage {
                    ErrorBanner(message: errorMessage)
                }

                PrimaryButton(title: addedToCart ? "Added to cart" : "Add to cart", isLoading: isAddingToCart) {
                    Task { await addToCart() }
                }
                .disabled(pet == nil || addedToCart)
                .appearAnimation(delay: 0.25)
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { selectedVariantId = service.variants.first?.id }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { CartView() } label: { Image(systemName: "cart") }
            }
        }
    }
}

private struct VariantRow: View {
    let variant: ServiceVariant
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(variant.name).font(.brandHeadline).foregroundStyle(.primary)
                    Text("\(variant.durationMinutes) min").font(.brandCaption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(variant.priceMinorUnits == 0 ? "Free" : CurrencyFormatter.rupees(variant.priceMinorUnits))
                    .font(.brandHeadline)
                    .foregroundStyle(isSelected ? Theme.primary : .secondary)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Theme.primary : Color(.tertiaryLabel))
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? Theme.primary.opacity(0.08) : Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isSelected ? Theme.primary : .clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(PressableStyle())
        .animation(Theme.springQuick, value: isSelected)
    }
}

#Preview {
    NavigationStack { ServiceDetailView(service: MockData.services[0], pet: MockData.user.pets.first) }
}
