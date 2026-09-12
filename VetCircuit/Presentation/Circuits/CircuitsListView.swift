import SwiftUI

@Observable
@MainActor
final class CircuitsListViewModel {
    var circuits: [Circuit] = []
    var isLoading = false
    var errorMessage: String?
    var searchArea: String = ""

    private let getCircuitsUseCase = DependencyContainer.shared.getCircuitsUseCase()

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            circuits = try await getCircuitsUseCase.execute(area: searchArea.isEmpty ? nil : searchArea)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct CircuitsListView: View {
    @State private var viewModel = CircuitsListViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading && viewModel.circuits.isEmpty {
                    ProgressView()
                } else if let errorMessage = viewModel.errorMessage {
                    EmptyStateView(
                        systemImage: "wifi.slash", title: "Couldn't load circuits",
                        message: errorMessage, actionTitle: "Retry"
                    ) { Task { await viewModel.load() } }
                } else if viewModel.circuits.isEmpty {
                    EmptyStateView(
                        systemImage: "map", title: "No circuits available in your area yet",
                        message: "We're expanding fast. Join the waitlist and we'll notify you the moment a vet starts a circuit nearby.",
                        actionTitle: "Join waitlist"
                    ) { }
                } else {
                    List(viewModel.circuits) { circuit in
                        NavigationLink(value: circuit) {
                            CircuitRow(circuit: circuit)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Book a visit")
            .searchable(text: $viewModel.searchArea, prompt: "Search by area")
            .onSubmit(of: .search) { Task { await viewModel.load() } }
            .navigationDestination(for: Circuit.self) { circuit in
                BookingView(circuit: circuit)
            }
            .task { await viewModel.load() }
            .refreshable { await viewModel.load() }
        }
    }
}

struct CircuitRow: View {
    let circuit: Circuit

    var body: some View {
        Card {
            HStack(spacing: 14) {
                Image(systemName: "stethoscope")
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor.opacity(0.15))
                    .foregroundStyle(Color.accentColor)
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text(circuit.vet?.name ?? "Veterinarian")
                        .font(.headline)
                    Text(circuit.clusterArea)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let vet = circuit.vet {
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                            Text(String(format: "%.1f", vet.rating) + " (\(vet.reviewCount))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if vet.verificationStatus == .verified {
                                Image(systemName: "checkmark.seal.fill").font(.caption2).foregroundStyle(.blue)
                            }
                        }
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
        }
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    CircuitsListView()
}
