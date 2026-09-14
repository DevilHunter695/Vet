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
    var errorMessage: String?
    var boughtPackageId: UUID?

    private let browsePackagesUseCase = DependencyContainer.shared.browsePackagesUseCase()
    private let buyPackageUseCase = DependencyContainer.shared.buyPackageUseCase()
    private let getCatalogUseCase = DependencyContainer.shared.getCatalogUseCase()
    private let getMyPackageRedemptionsUseCase = DependencyContainer.shared.getMyPackageRedemptionsUseCase()

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
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func buy(_ package: Package, petIds: [UUID], userId: UUID) async {
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
                EmptyStateView(systemImage: "exclamationmark.triangle", title: "Couldn't load packages", message: errorMessage)
            } else if viewModel.packages.isEmpty {
                EmptyStateView(systemImage: "shippingbox", title: "No packages yet", message: "Bundled plans will show up here.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if !viewModel.myRedemptions.isEmpty {
                            MyPackagesSection(entitlements: viewModel.myRedemptions)
                        }

                        Text("Save by bundling the visits your pet will need anyway.")
                            .font(.brandBody).foregroundStyle(.secondary)
                        ForEach(Array(viewModel.packages.enumerated()), id: \.element.id) { index, package in
                            PackageCard(
                                package: package,
                                discount: package.discountMinorUnits(catalog: viewModel.catalog),
                                isBought: viewModel.boughtPackageId == package.id,
                                isBuying: viewModel.isBuying
                            ) {
                                guard let userId = session.currentUser?.id else { return }
                                let petIds = pet.map { [$0.id] } ?? []
                                Task { await viewModel.buy(package, petIds: petIds, userId: userId) }
                            }
                            .appearAnimation(delay: Theme.staggerDelay(index))
                        }

                        if let errorMessage = viewModel.errorMessage {
                            ErrorBanner(message: errorMessage)
                        }
                    }
                    .padding()
                }
            }
        }
        .auroraScreenBackground()
        .navigationTitle("Packages")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load(vertical: vertical, userId: session.currentUser?.id) }
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
                            .foregroundStyle(.secondary)
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
    let isBought: Bool
    let isBuying: Bool
    let action: () -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(package.name).font(.brandHeadline)
                    Text(package.packageDescription).font(.brandBody).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)

                HStack {
                    Text(CurrencyFormatter.rupees(package.priceMinorUnits))
                        .font(.brandHeadline).foregroundStyle(Theme.primary)
                    if discount > 0 {
                        Text("Save \(CurrencyFormatter.rupees(discount))")
                            .font(.brandCaption)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Theme.success.opacity(0.15), in: Capsule())
                            .foregroundStyle(Theme.success)
                    }
                    Spacer()
                }
                .accessibilityElement(children: .combine)

                PrimaryButton(title: isBought ? "Added to cart" : "Add package to cart", isLoading: isBuying, action: action)
                    .disabled(isBought)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#Preview {
    NavigationStack { PackagesView(vertical: .vet, pet: MockData.user.pets.first).environment(SessionStore()) }
}
