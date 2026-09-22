import SwiftUI

/// C6: what's included, duration, what to prepare, price, add-ons, FAQs —
/// the "showing details" screen that didn't exist at all before this.
struct ServiceDetailView: View {
    let service: Service
    let pet: Pet?
    /// K5: lets a 1-tap "book follow-up"/"book vaccination" action land
    /// directly on the right variant (the free follow-up, or whichever
    /// vaccine the pet is due for) instead of the catalog's usual default.
    var preselectedVariantId: UUID? = nil

    @Environment(SessionStore.self) private var session
    @State private var selectedVariantId: UUID?
    @State private var pets: [Pet] = []
    /// D6: multi-pet in one visit — every selected pet lands on the same
    /// cart line so PricingEngine's `additionalPetCount` (2nd pet at a
    /// reduced fee) is exercised for real instead of being unreachable code.
    @State private var selectedPetIds: Set<UUID> = []
    /// D3: add-ons attachable to a booking — the data model already carried
    /// `CartItem.addonIds`, but nothing let a customer populate it.
    @State private var selectedAddonIds: Set<UUID> = []
    @State private var isAddingToCart = false
    @State private var addedToCart = false
    @State private var isShowingCart = false
    @State private var errorMessage: String?

    private let manageCartUseCase = DependencyContainer.shared.manageCartUseCase()
    private let managePetsUseCase = DependencyContainer.shared.managePetsUseCase()

    private var selectedVariant: ServiceVariant? {
        service.variants.first { $0.id == selectedVariantId } ?? service.variants.first
    }

    private func loadPets() async {
        guard let userId = session.currentUser?.id else {
            pets = pet.map { [$0] } ?? []
            return
        }
        do {
            pets = try await managePetsUseCase.list(ownerId: userId)
        } catch {
            pets = pet.map { [$0] } ?? []
        }
        if selectedPetIds.isEmpty {
            selectedPetIds = Set([pet?.id ?? pets.first?.id].compactMap { $0 })
        }
    }

    private func togglePet(_ id: UUID) {
        Haptics.selection()
        if selectedPetIds.contains(id) {
            // Always leave at least one pet selected — an empty selection
            // isn't a valid cart line (ManageCartUseCase rejects it anyway).
            guard selectedPetIds.count > 1 else { return }
            selectedPetIds.remove(id)
        } else {
            selectedPetIds.insert(id)
        }
    }

    private func toggleAddon(_ id: UUID) {
        Haptics.selection()
        if selectedAddonIds.contains(id) {
            selectedAddonIds.remove(id)
        } else {
            selectedAddonIds.insert(id)
        }
    }

    private func addToCart() async {
        guard let variant = selectedVariant, !selectedPetIds.isEmpty else { return }
        guard let userId = session.currentUser?.id else {
            Haptics.error()
            errorMessage = "Sign in to add this to your cart."
            return
        }
        isAddingToCart = true
        errorMessage = nil
        defer { isAddingToCart = false }
        do {
            let cart = try await manageCartUseCase.current(userId: userId)
            let item = CartItem(
                id: UUID(), serviceId: service.id, variantId: variant.id,
                petIds: Array(selectedPetIds), addonIds: Array(selectedAddonIds)
            )
            _ = try await manageCartUseCase.addItem(item, to: cart)
            Haptics.success()
            withAnimation(Theme.springSoft) { addedToCart = true }
        } catch {
            Haptics.error()
            errorMessage = UserFacingError.message(for: error)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(service.category.displayName, systemImage: service.category.systemImage)
                        .font(.brandCaption).foregroundStyle(Theme.primary)
                    Text(service.name).font(.brandLargeTitle)
                    Text(service.summary).font(.brandBody).foregroundStyle(Theme.textSecondary)
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

                if pets.count > 1 {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Pets on this visit").font(.brandHeadline)
                        Text("The 2nd pet onward is charged the reduced multi-pet rate.")
                            .font(.brandCaption).foregroundStyle(Theme.textSecondary)
                        ForEach(pets) { candidate in
                            CheckboxRow(
                                title: candidate.name,
                                subtitle: candidate.breed,
                                isSelected: selectedPetIds.contains(candidate.id)
                            ) { togglePet(candidate.id) }
                        }
                    }
                    .appearAnimation(delay: 0.12)
                }

                if !service.addons.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Add-ons").font(.brandHeadline)
                        ForEach(service.addons) { addon in
                            CheckboxRow(
                                title: addon.name,
                                subtitle: nil,
                                trailing: CurrencyFormatter.rupees(addon.priceMinorUnits),
                                isSelected: selectedAddonIds.contains(addon.id)
                            ) { toggleAddon(addon.id) }
                        }
                    }
                    .appearAnimation(delay: 0.15)
                }

                if !service.faqs.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("FAQs").font(.brandHeadline)
                        ForEach(service.faqs) { faq in
                            FAQRow(faq: faq)
                        }
                    }
                    .appearAnimation(delay: 0.18)
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

                // Once something is in the cart the CTA used to stay
                // permanently disabled, dead-ending anyone who wanted a
                // second variant or another pet. Offer both next steps.
                Group {
                    if addedToCart {
                        VStack(spacing: 10) {
                            PrimaryButton(title: "Go to cart", systemImage: "cart.fill") {
                                isShowingCart = true
                            }
                            SecondaryButton(title: "Add another") {
                                addedToCart = false
                            }
                        }
                    } else {
                        PrimaryButton(title: "Add to cart", isLoading: isAddingToCart, isEnabled: !selectedPetIds.isEmpty) {
                            Task { await addToCart() }
                        }
                    }
                }
                .appearAnimation(delay: 0.25)
            }
            .padding()
        }
        .auroraScreenBackground()
        .floatingTabBarInset()
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $isShowingCart) { CartView() }
        .onAppear { selectedVariantId = preselectedVariantId ?? service.variants.first?.id }
        .task { await loadPets() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                CartToolbarButton()
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
                    Text("\(variant.durationMinutes) min").font(.brandCaption).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Text(variant.priceMinorUnits == 0 ? "Free" : CurrencyFormatter.rupees(variant.priceMinorUnits))
                    .font(.brandMono(.body, weight: .semibold))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
                // The selected row says so, rather than being 8% tinted.
                // A wash that faint is not a selection state on a dark
                // ground - you cannot tell which variant you picked without
                // comparing rows against each other.
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.primary)
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: 18)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Spacing.gutter)
            .padding(.vertical, Spacing.row)
            .background(
                RoundedRectangle(cornerRadius: Spacing.corner, style: .continuous)
                    .fill(isSelected ? Theme.primary.opacity(0.14)
                                     : Color(.secondarySystemGroupedBackground).opacity(0.92))
            )
            .animation(Theme.springQuick, value: isSelected)
        }
        .buttonStyle(PressableStyle())
        .selectable(isSelected: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// Shared checkbox-style row for both the pet multi-select (D6) and the
/// add-on toggles (D3) — same interaction, different content.
private struct CheckboxRow: View {
    let title: String
    var subtitle: String?
    var trailing: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.brandBody).foregroundStyle(.primary)
                    if let subtitle {
                        Text(subtitle).font(.brandCaption).foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(.brandMono(.body, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                // This is called CheckboxRow and it had no checkbox. Pets
                // and add-ons were multi-select with nothing on the row to
                // say what was selected, so the only feedback was whatever
                // .selectable() drew around the edge.
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Theme.primary : Theme.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Spacing.gutter)
            .padding(.vertical, Spacing.row)
            .background(Color(.secondarySystemGroupedBackground).opacity(0.92),
                        in: RoundedRectangle(cornerRadius: Spacing.corner, style: .continuous))
            .animation(Theme.springQuick, value: isSelected)
        }
        .buttonStyle(PressableStyle())
        .selectable(isSelected: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// C6: a simple disclosure row per FAQ — no need for a custom accordion
/// component elsewhere in the app, so this stays local to the one screen
/// that uses it.
private struct FAQRow: View {
    let faq: FAQ
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Text(faq.answer)
                .font(.brandBody)
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 4)
        } label: {
            Text(faq.question).font(.brandBody)
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: Spacing.corner, style: .continuous))
        .animation(Theme.springQuick, value: isExpanded)
    }
}

#Preview {
    NavigationStack { ServiceDetailView(service: MockData.services[0], pet: MockData.user.pets.first) }
}
