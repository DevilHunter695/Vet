import SwiftUI

/// D4: packages/bundles ("Puppy first-year: 4 visits + 3 vaccines") browsed
/// the same way the à la carte catalog is. Buying one expands into individual
/// cart lines (`BuyPackageUseCase`) *and* creates a real, redeemable
/// `PackageRedemption` per included service — this screen's "My packages"
/// section shows genuine "3 of 4 visits used" progress derived from those
/// rows (`GetMyPackageRedemptionsUseCase`), not a static purchased flag.
@Observable
@MainActor
final class PackagesViewModel {
    var packages: [Package] = []
    var catalog: [Service] = []
    var myRedemptions: [GetMyPackageRedemptionsUseCase.RedeemableEntitlement] = []
    var isLoading = false
    var isBuying = false
    /// The pet the screen was pushed with, if any — preselected on load.
    var preselectedPetId: UUID?
    var errorMessage: String?
    var boughtPackageId: UUID?
    /// D4: buying a package needs at least one pet (`BuyPackageUseCase`
    /// rejects an empty list). This screen is reachable from the catalog
    /// toolbar with no pet in hand, in which case the button used to throw
    /// "Choose at least one pet." into a banner at the very bottom of a long
    /// scroll — indistinguishable from nothing happening. Load the owner's
    /// pets here and let them pick right on the screen.
    var pets: [Pet] = []
    var selectedPetIds: Set<UUID> = []

    private let browsePackagesUseCase = DependencyContainer.shared.browsePackagesUseCase()
    private let buyPackageUseCase = DependencyContainer.shared.buyPackageUseCase()
    private let getCatalogUseCase = DependencyContainer.shared.getCatalogUseCase()
    private let getMyPackageRedemptionsUseCase = DependencyContainer.shared.getMyPackageRedemptionsUseCase()
    private let managePetsUseCase = DependencyContainer.shared.managePetsUseCase()

    func load(vertical: Vertical, userId: UUID?) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            async let packagesResult = browsePackagesUseCase.execute(vertical: vertical)
            async let catalogResult = getCatalogUseCase.execute(vertical: vertical)
            packages = try await packagesResult
            catalog = try await catalogResult
            if let userId {
                myRedemptions = try await getMyPackageRedemptionsUseCase.execute(userId: userId)
                pets = try await managePetsUseCase.list(ownerId: userId)
                if selectedPetIds.isEmpty, let preselected = preselectedPetId ?? pets.first?.id {
                    selectedPetIds = [preselected]
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func buy(_ package: Package, userId: UUID) async {
        let petIds = Array(selectedPetIds)
        guard !petIds.isEmpty else {
            Haptics.error()
            errorMessage = pets.isEmpty
                ? "Add a pet to your profile first — a package is bought against a specific pet."
                : "Pick which pet this package is for."
            return
        }
        isBuying = true
        errorMessage = nil
        defer { isBuying = false }
        do {
            _ = try await buyPackageUseCase.execute(packageId: package.id, petIds: petIds, userId: userId)
            myRedemptions = try await getMyPackageRedemptionsUseCase.execute(userId: userId)
            Haptics.success()
            withAnimation(Theme.springSoft) { boughtPackageId = package.id }
        } catch {
            Haptics.error()
            errorMessage = error.localizedDescription
        }
    }
}

struct PackagesView: View {
    let vertical: Vertical
    let pet: Pet?

    @Environment(SessionStore.self) private var session
    @State private var viewModel = PackagesViewModel()
    @State private var isShowingCart = false

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.packages.isEmpty {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(0..<3, id: \.self) { _ in ShimmerView().frame(height: 120) }
                    }
                    .padding()
                }
            } else if let errorMessage = viewModel.errorMessage, viewModel.packages.isEmpty {
                // An error state with no way out is a dead end dressed up
                // as an explanation. EmptyStateView has always taken an
                // action; these three screens just never passed one.
                EmptyStateView(
                    systemImage: "exclamationmark.triangle", title: "Couldn't load packages",
                    message: errorMessage, actionTitle: "Try again"
                ) {
                    Task { await viewModel.load(vertical: vertical, userId: session.currentUser?.id) }
                }
            } else if viewModel.packages.isEmpty {
                EmptyStateView(systemImage: "shippingbox", title: "No packages yet", message: "Bundled plans will show up here.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if !viewModel.myRedemptions.isEmpty {
                            MyPackagesSection(entitlements: viewModel.myRedemptions)
                        }

                        Text("Save by bundling the visits your pet will need anyway.")
                            .font(.brandBody).foregroundStyle(Theme.textSecondary)

                        // Which pet the entitlement is created against. Without
                        // this the buy button just failed silently for anyone
                        // who opened Packages from the catalog toolbar.
                        if viewModel.pets.count > 1 {
                            VStack(alignment: .leading, spacing: 8) {
                                SectionHeader(title: "Who is this for?", systemImage: "pawprint.fill")
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(viewModel.pets) { pet in
                                            let isOn = viewModel.selectedPetIds.contains(pet.id)
                                            PillButton(title: pet.name, systemImage: isOn ? "checkmark" : nil, tint: Theme.primary, filled: isOn) {
                                                Haptics.selection()
                                                if isOn {
                                                    viewModel.selectedPetIds.remove(pet.id)
                                                } else {
                                                    viewModel.selectedPetIds.insert(pet.id)
                                                }
                                            }
                                        }
                                    }
                                    .padding(.horizontal, 2)
                                }
                            }
                        }

                        if let errorMessage = viewModel.errorMessage {
                            ErrorBanner(message: errorMessage)
                        }

                        ForEach(Array(viewModel.packages.enumerated()), id: \.element.id) { index, package in
                            PackageCard(
                                package: package,
                                discount: package.discountMinorUnits(catalog: viewModel.catalog),
                                services: viewModel.catalog,
                                isBought: viewModel.boughtPackageId == package.id,
                                isBuying: viewModel.isBuying,
                                onViewCart: { isShowingCart = true }
                            ) {
                                guard let userId = session.currentUser?.id else {
                                    viewModel.errorMessage = "Sign in to buy a package."
                                    return
                                }
                                Task { await viewModel.buy(package, userId: userId) }
                            }
                            .appearAnimation(delay: Theme.staggerDelay(index))
                        }
                    }
                    .padding()
                }
            }
        }
        .auroraScreenBackground()
        .floatingTabBarInset()
        .navigationTitle("Packages")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $isShowingCart) { CartView() }
        .toolbar { ToolbarItem(placement: .topBarTrailing) { CartToolbarButton() } }
        .task {
            viewModel.preselectedPetId = pet?.id
            await viewModel.load(vertical: vertical, userId: session.currentUser?.id)
        }
    }
}

/// D4: "3 of 4 visits used" — real progress per purchased entitlement,
/// derived from `PackageRedemption.usedCount`/`totalCount`
/// (`PackageRedemptionPolicy.progressLabel`), not a static purchased flag.
private struct MyPackagesSection: View {
    let entitlements: [GetMyPackageRedemptionsUseCase.RedeemableEntitlement]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("My packages").font(.brandHeadline)
            ForEach(entitlements) { entitlement in
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(entitlement.packageName) — \(entitlement.serviceName)")
                            .font(.brandBody)
                        ProgressView(value: Double(entitlement.redemption.usedCount), total: Double(entitlement.redemption.totalCount))
                            .tint(entitlement.redemption.isExhausted ? Theme.success : Theme.primary)
                            .accessibilityHidden(true)
                        Text(entitlement.progressLabel)
                            .font(.brandCaption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

private struct PackageCard: View {
    let package: Package
    let discount: Int
    /// Resolved so the card can actually list what is inside the bundle
    /// instead of only naming it — a customer will not spend ₹3,499 on a
    /// sentence.
    let services: [Service]
    let isBought: Bool
    let isBuying: Bool
    let onViewCart: () -> Void
    let action: () -> Void

    private var lines: [(name: String, quantity: Int)] {
        package.items.compactMap { item in
            guard let service = services.first(where: { $0.id == item.serviceId }) else { return nil }
            return (service.name, item.quantity)
        }
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(package.name).font(.brandHeadline)
                    Text(package.packageDescription).font(.brandBody).foregroundStyle(Theme.textSecondary)
                }
                .accessibilityElement(children: .combine)

                HStack {
                    Text(CurrencyFormatter.rupees(package.priceMinorUnits))
                        .font(.brandHeadline).foregroundStyle(Theme.primary)
                    if discount > 0 {
                        Text("Save \(CurrencyFormatter.rupees(discount))")
                            .font(.brandCaption)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Theme.success.opacity(0.15), in: Capsule())
                            .foregroundStyle(Theme.success)
                    }
                    Spacer()
                }
                .accessibilityElement(children: .combine)

                if !lines.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(lines, id: \.name) { line in
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(Theme.emeraldLight)
                                Text("\(line.quantity)× \(line.name)")
                                    .font(.brandCallout)
                                    .foregroundStyle(Theme.textSecondary)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                }

                if isBought {
                    // A disabled "Added to cart" button is a dead end: the
                    // purchase worked but there was nowhere to go next.
                    VStack(spacing: 8) {
                        CalloutNote(text: "Added to your cart — pick a slot at checkout.", systemImage: "checkmark.circle.fill")
                        PrimaryButton(title: "View cart", systemImage: "cart.fill", action: onViewCart)
                    }
                } else {
                    PrimaryButton(title: "Add package to cart", isLoading: isBuying, action: action)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#Preview {
    NavigationStack { PackagesView(vertical: .vet, pet: MockData.user.pets.first).environment(SessionStore()) }
}
