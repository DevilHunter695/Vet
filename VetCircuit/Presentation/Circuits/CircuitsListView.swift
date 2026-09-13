import SwiftUI

@Observable
@MainActor
final class CircuitsListViewModel {
    var circuits: [Circuit] = []
    var isLoading = false
    var errorMessage: String?
    var searchArea: String = ""

    private let getCircuitsUseCase = DependencyContainer.shared.getCircuitsUseCase()

    func load(vertical: Vertical) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            circuits = try await getCircuitsUseCase.execute(area: searchArea.isEmpty ? nil : searchArea, vertical: vertical)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct CircuitsListView: View {
    @State private var viewModel = CircuitsListViewModel()
    @AppStorage("vc.selected_vertical") private var selectedVerticalRaw: String = Vertical.vet.rawValue

    private var selectedVertical: Vertical { Vertical(rawValue: selectedVerticalRaw) ?? .vet }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading && viewModel.circuits.isEmpty {
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(0..<4, id: \.self) { _ in
                                ShimmerView().frame(height: 84)
                            }
                        }
                        .padding()
                    }
                } else if let errorMessage = viewModel.errorMessage {
                    EmptyStateView(
                        systemImage: "wifi.slash", title: "Couldn't load circuits",
                        message: errorMessage, actionTitle: "Retry"
                    ) { Task { await viewModel.load(vertical: selectedVertical) } }
                } else if viewModel.circuits.isEmpty {
                    EmptyStateView(
                        systemImage: "map", title: "No circuits available in your area yet",
                        message: "We're expanding fast. Join the waitlist and we'll notify you the moment a vet starts a circuit nearby.",
                        actionTitle: "Join waitlist"
                    ) { }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            ForEach(Array(viewModel.circuits.enumerated()), id: \.element.id) { index, circuit in
                                NavigationLink(value: circuit) {
                                    CircuitRow(circuit: circuit)
                                }
                                .buttonStyle(PressableStyle())
                                .appearAnimation(delay: Theme.staggerDelay(index))
                                .scrollTransition { content, phase in
                                    content
                                        .opacity(phase.isIdentity ? 1 : 0.6)
                                        .scaleEffect(phase.isIdentity ? 1 : 0.94)
                                        .blur(radius: phase.isIdentity ? 0 : 2)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    .background(Color(.systemGroupedBackground))
                }
            }
            .animation(Theme.crossFade, value: viewModel.isLoading)
            .animation(Theme.crossFade, value: viewModel.circuits.map(\.id))
            .navigationTitle(selectedVertical.displayName)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        TriageView()
                    } label: {
                        Label("Not sure?", systemImage: "questionmark.circle")
                            .labelStyle(.iconOnly)
                            .font(.title3)
                            .foregroundStyle(Theme.primary)
                    }
                }
            }
            .searchable(text: $viewModel.searchArea, prompt: "Search by area")
            .onSubmit(of: .search) { Task { await viewModel.load(vertical: selectedVertical) } }
            .navigationDestination(for: Circuit.self) { circuit in
                BookingView(circuit: circuit)
            }
            .task { await viewModel.load(vertical: selectedVertical) }
            .refreshable { await viewModel.load(vertical: selectedVertical) }
            .onChange(of: selectedVerticalRaw) {
                Task { await viewModel.load(vertical: selectedVertical) }
            }
        }
    }
}

/// An independent, self-contained "glass" card — not a list row. Each vet
/// gets its own floating, translucent surface rather than sharing one
/// continuous list background, with a single chevron (no duplicate
/// disclosure indicator from an enclosing List).
struct CircuitRow: View {
    let circuit: Circuit

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Theme.gradient)
                Image(systemName: "stethoscope")
                    .font(.title3)
                    .foregroundStyle(.white)
            }
            .frame(width: 48, height: 48)
            .shadow(color: Theme.primary.opacity(0.25), radius: 6, y: 3)

            VStack(alignment: .leading, spacing: 4) {
                Text(circuit.vet?.name ?? "Veterinarian")
                    .font(.brandHeadline)
                    .foregroundStyle(.primary)
                Text(circuit.clusterArea)
                    .font(.brandCaption)
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
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.systemBackground).opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.5), lineWidth: 1)
        )
        .shadow(color: Theme.cardShadow, radius: 14, y: 6)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    CircuitsListView()
}
