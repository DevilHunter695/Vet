import SwiftUI

@Observable
@MainActor
final class ServiceCatalogViewModel {
    var services: [Service] = []
    var isLoading = false
    var errorMessage: String?

    private let getCatalogUseCase = DependencyContainer.shared.getCatalogUseCase()

    func load(vertical: Vertical, species: Pet.Species?) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            services = try await getCatalogUseCase.execute(vertical: vertical, forSpecies: species)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// D1-D2: browse the service catalog with real categories, variants, and
/// add-ons — replaces v1's undifferentiated "book a visit" with the "what
/// exactly am I buying" screen customers actually expect (plan §1.1, §C6).
struct ServiceCatalogView: View {
    let vertical: Vertical
    let pet: Pet?

    @State private var viewModel = ServiceCatalogViewModel()

    private var groupedByCategory: [(ServiceCategory, [Service])] {
        ServiceCategory.allCases
            .filter { $0.vertical == vertical }
            .compactMap { category in
                let matches = viewModel.services.filter { $0.category == category }
                return matches.isEmpty ? nil : (category, matches)
            }
    }

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.services.isEmpty {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(0..<4, id: \.self) { _ in ShimmerView().frame(height: 72) }
                    }
                    .padding()
                }
            } else if let errorMessage = viewModel.errorMessage {
                EmptyStateView(systemImage: "exclamationmark.triangle", title: "Couldn't load services", message: errorMessage)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(Array(groupedByCategory.enumerated()), id: \.element.0) { index, entry in
                            let (category, services) = entry
                            VStack(alignment: .leading, spacing: 10) {
                                Label(category.displayName, systemImage: category.systemImage)
                                    .font(.brandHeadline)
                                    .foregroundStyle(Theme.primary)

                                ForEach(services) { service in
                                    NavigationLink {
                                        ServiceDetailView(service: service, pet: pet)
                                    } label: {
                                        ServiceRow(service: service)
                                    }
                                    .buttonStyle(PressableStyle())
                                }
                            }
                            .appearAnimation(delay: Theme.staggerDelay(index))
                        }
                    }
                    .padding()
                }
                .animation(Theme.crossFade, value: viewModel.services.map(\.id))
            }
        }
        .navigationTitle("Services")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // D4: packages/bundles, one tap from the à la carte catalog.
                NavigationLink { PackagesView(vertical: vertical, pet: pet) } label: {
                    Label("Packages", systemImage: "shippingbox")
                }
            }
        }
        .task { await viewModel.load(vertical: vertical, species: pet?.species) }
    }
}

private struct ServiceRow: View {
    let service: Service

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(service.name).font(.brandHeadline).foregroundStyle(.primary)
                Text(service.summary)
                    .font(.brandCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if let price = service.startingPriceMinorUnits {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("from").font(.caption2).foregroundStyle(.tertiary)
                    Text(CurrencyFormatter.rupees(price)).font(.brandHeadline).foregroundStyle(Theme.primary)
                }
            }
        }
        .padding()
        .glassCard()
    }
}

#Preview {
    NavigationStack { ServiceCatalogView(vertical: .vet, pet: MockData.user.pets.first) }
}
