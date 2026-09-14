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
                                SectionHeader(
                                    title: category.displayName,
                                    subtitle: services.count == 1 ? nil : "\(services.count) options",
                                    systemImage: category.systemImage
                                )

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
        .auroraScreenBackground()
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

/// D1/D2: a catalog row has to answer "what is it, how long does it take, and
/// what does it start at" — a name and a price alone make the customer open
/// every service in turn to compare them.
private struct ServiceRow: View {
    let service: Service

    /// The shortest variant's duration, since the price shown is also the
    /// cheapest variant's — the two have to describe the same thing.
    private var shortestDurationMinutes: Int? {
        service.variants.map(\.durationMinutes).min()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(service.name)
                        .font(.brandHeadline)
                        .foregroundStyle(.primary)
                    Text(service.summary)
                        .font(.brandCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    if let price = service.startingPriceMinorUnits {
                        Text("from").brandEyebrow()
                        Text(CurrencyFormatter.rupees(price))
                            .font(.brandMono(.callout, weight: .bold))
                            .foregroundStyle(Theme.primary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }

            HStack(spacing: 8) {
                if let minutes = shortestDurationMinutes {
                    TagChip(text: "\(minutes) min", systemImage: "clock", tint: Theme.primary)
                }
                if service.variants.count > 1 {
                    TagChip(text: "\(service.variants.count) options", systemImage: "square.stack", tint: Theme.emerald)
                }
                if !service.addons.isEmpty {
                    TagChip(text: "Add-ons", systemImage: "plus.circle", tint: Theme.accent)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .glassCard()
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    NavigationStack { ServiceCatalogView(vertical: .vet, pet: MockData.user.pets.first) }
}
