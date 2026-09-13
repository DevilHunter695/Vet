import SwiftUI

@Observable
@MainActor
final class CircuitsListViewModel {
    var circuits: [Circuit] = []
    var isLoading = false
    var errorMessage: String?
    /// C8: was area-only; now also matches vet name and service name, since a
    /// customer typing "Dr. Rao" or "vaccination" shouldn't need to know
    /// those live on different tables.
    var searchArea: String = ""
    var searchResult: SearchUseCase.Result?
    var recentCircuits: [Circuit] = []
    var rebookSuggestion: RebookLastVisitUseCase.Suggestion?
    /// C3/C4: kept on the view model (not re-derived per render) so the
    /// filter sheet and sort menu both read/write the same source of truth.
    var filter = CircuitFilter()
    var sort: CircuitSortOption = .soonest

    private let getCircuitsUseCase = DependencyContainer.shared.getCircuitsUseCase()
    private let getCatalogUseCase = DependencyContainer.shared.getCatalogUseCase()
    private let getVisitHistoryUseCase = DependencyContainer.shared.getVisitHistoryUseCase()
    private let searchUseCase = DependencyContainer.shared.searchUseCase()
    private let rebookLastVisitUseCase = DependencyContainer.shared.rebookLastVisitUseCase()

    var isSearching: Bool { !searchArea.trimmingCharacters(in: .whitespaces).isEmpty }

    func load(vertical: Vertical, userId: UUID?) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let catalog = (try? await getCatalogUseCase.execute(vertical: vertical)) ?? []
            var previouslyBooked: Set<UUID> = []
            if let userId, let history = try? await getVisitHistoryUseCase.execute(userId: userId) {
                previouslyBooked = Set(history.map(\.vetId))
            }
            circuits = try await getCircuitsUseCase.execute(
                area: nil, vertical: vertical,
                filter: filter, sort: sort, catalog: catalog, previouslyBookedVetIds: previouslyBooked
            )
            recentCircuits = RecentlyViewedStore.shared.recentCircuits(from: circuits)
            if isSearching { await search(vertical: vertical) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func search(vertical: Vertical) async {
        guard isSearching else { searchResult = nil; return }
        do {
            searchResult = try await searchUseCase.execute(term: searchArea, vertical: vertical)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadRebookSuggestion(userId: UUID) async {
        rebookSuggestion = try? await rebookLastVisitUseCase.execute(userId: userId)
    }

    func recordView(_ circuit: Circuit) {
        RecentlyViewedStore.shared.recordView(circuitId: circuit.id)
    }
}

struct CircuitsListView: View {
    @Environment(SessionStore.self) private var session
    @Environment(PendingDeepLinkStore.self) private var pendingDeepLink
    @State private var viewModel = CircuitsListViewModel()
    @State private var showingFilters = false
    @State private var rebookDestination: Circuit?
    @AppStorage("vc.selected_vertical") private var selectedVerticalRaw: String = Vertical.vet.rawValue

    private var selectedVertical: Vertical { Vertical(rawValue: selectedVerticalRaw) ?? .vet }

    private func reload() {
        Task { await viewModel.load(vertical: selectedVertical, userId: session.currentUser?.id) }
    }

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
                    ) { reload() }
                } else if viewModel.isSearching {
                    searchResultsList
                } else if viewModel.circuits.isEmpty {
                    EmptyStateView(
                        systemImage: "map", title: "No circuits available in your area yet",
                        message: "We're expanding fast. Join the waitlist and we'll notify you the moment a vet starts a circuit nearby.",
                        actionTitle: "Join waitlist"
                    ) { }
                } else {
                    ScrollView {
                        VStack(spacing: 14) {
                            // C11: an explicit, always-visible emergency entry
                            // point — plan §C11 calls this safety-critical,
                            // not something to bury behind "Not sure?".
                            NavigationLink {
                                EmergencyView()
                            } label: {
                                EmergencyBanner()
                            }
                            .buttonStyle(PressableStyle())

                            // L8: a brief disclaimer visible in the main
                            // booking flow, not only reachable via the
                            // emergency path itself.
                            Text("VetCircuit isn't an emergency service. For a life-threatening situation, use the emergency button above or call a clinic directly.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            LazyVStack(spacing: 14) {
                                if let rebook = viewModel.rebookSuggestion {
                                    RebookCard(suggestion: rebook) {
                                        Haptics.tap()
                                        rebookDestination = rebook.circuit
                                    }
                                }
                                if !viewModel.recentCircuits.isEmpty {
                                    RecentlyViewedSection(circuits: viewModel.recentCircuits) { circuit in
                                        viewModel.recordView(circuit)
                                        rebookDestination = circuit
                                    }
                                }
                                ForEach(Array(viewModel.circuits.enumerated()), id: \.element.id) { index, circuit in
                                    NavigationLink(value: circuit) {
                                        CircuitRow(circuit: circuit)
                                    }
                                    .buttonStyle(PressableStyle())
                                    .simultaneousGesture(TapGesture().onEnded { viewModel.recordView(circuit) })
                                    .appearAnimation(delay: Theme.staggerDelay(index))
                                    .scrollTransition { content, phase in
                                        content
                                            .opacity(phase.isIdentity ? 1 : 0.6)
                                            .scaleEffect(phase.isIdentity ? 1 : 0.94)
                                            .blur(radius: phase.isIdentity ? 0 : 2)
                                    }
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
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        ServiceCatalogView(vertical: selectedVertical, pet: MockData.user.pets.first)
                    } label: {
                        Label("Services", systemImage: "list.bullet.rectangle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // C4: sort menu.
                    Menu {
                        Picker("Sort", selection: $viewModel.sort) {
                            ForEach(CircuitSortOption.allCases) { option in
                                Text(option.displayName).tag(option)
                            }
                        }
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                            .labelStyle(.iconOnly)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // C3: filter sheet.
                    Button {
                        Haptics.tap()
                        showingFilters = true
                    } label: {
                        Label("Filters", systemImage: viewModel.filter.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                            .labelStyle(.iconOnly)
                    }
                }
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
            .searchable(text: $viewModel.searchArea, prompt: "Search by vet, area, or service")
            .onSubmit(of: .search) { Task { await viewModel.search(vertical: selectedVertical) } }
            .onChange(of: viewModel.searchArea) { _, newValue in
                if newValue.isEmpty { viewModel.searchResult = nil } else {
                    Task { await viewModel.search(vertical: selectedVertical) }
                }
            }
            .navigationDestination(for: Circuit.self) { circuit in
                BookingView(circuit: circuit)
            }
            .navigationDestination(item: $rebookDestination) { circuit in
                BookingView(circuit: circuit)
            }
            .task { reload() }
            .task { if let user = session.currentUser { await viewModel.loadRebookSuggestion(userId: user.id) } }
            .refreshable {
                Haptics.tap()
                reload()
            }
            .onChange(of: selectedVerticalRaw) { reload() }
            .onChange(of: viewModel.sort) { reload() }
            .sheet(isPresented: $showingFilters) {
                CircuitFilterSheet(filter: $viewModel.filter) { reload() }
            }
            // N7: `vetcircuit://book/<circuitId>` — resolved against the
            // already-loaded circuit list, since this tab is the only one
            // that owns a `Circuit` navigation destination.
            .onChange(of: pendingDeepLink.pending) { _, _ in consumePendingBookLink() }
            .onAppear { consumePendingBookLink() }
        }
    }

    private func consumePendingBookLink() {
        guard case .book(let circuitId) = pendingDeepLink.pending else { return }
        guard let circuit = viewModel.circuits.first(where: { $0.id == circuitId }) else { return }
        _ = pendingDeepLink.consume()
        rebookDestination = circuit
    }

    /// C8: a search term can match a circuit (vet/area) or a service — shown
    /// as two short sections rather than forcing both into one row type.
    @ViewBuilder
    private var searchResultsList: some View {
        let result = viewModel.searchResult
        if (result?.circuits.isEmpty ?? true) && (result?.services.isEmpty ?? true) {
            EmptyStateView(systemImage: "magnifyingglass", title: "No matches", message: "Try a different vet name, area, or service.", actionTitle: nil) { }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if let circuits = result?.circuits, !circuits.isEmpty {
                        Text("Vets & circuits").font(.brandHeadline).padding(.horizontal, 4)
                        ForEach(circuits) { circuit in
                            NavigationLink(value: circuit) { CircuitRow(circuit: circuit) }
                                .buttonStyle(PressableStyle())
                                .simultaneousGesture(TapGesture().onEnded { viewModel.recordView(circuit) })
                        }
                    }
                    if let services = result?.services, !services.isEmpty {
                        Text("Services").font(.brandHeadline).padding(.horizontal, 4).padding(.top, 8)
                        ForEach(services) { service in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(service.name).font(.brandBody)
                                Text(service.summary).font(.brandCaption).foregroundStyle(.secondary)
                            }
                            .padding(12)
                            .glassCard()
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }
}

/// C11: a compact, prominent entry point into the emergency path — its own
/// visual treatment so it never blends in with an ordinary vet row.
private struct EmergencyBanner: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text("This is an emergency").font(.brandHeadline).foregroundStyle(.white)
                Text("Nearest 24×7 clinics & urgent triage").font(.brandCaption).foregroundStyle(.white.opacity(0.85))
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.85))
        }
        .padding(14)
        .background(Theme.danger, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// C3: filter sheet — service type, date, time-of-day, price, rating,
/// species, language, gender. Applies on "Apply", not live, so a partial
/// selection never triggers a reload mid-edit.
private struct CircuitFilterSheet: View {
    @Binding var filter: CircuitFilter
    let onApply: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: CircuitFilter

    init(filter: Binding<CircuitFilter>, onApply: @escaping () -> Void) {
        self._filter = filter
        self.onApply = onApply
        self._draft = State(initialValue: filter.wrappedValue)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Service type") {
                    Picker("Service", selection: $draft.serviceCategory) {
                        Text("Any").tag(ServiceCategory?.none)
                        ForEach(ServiceCategory.allCases) { category in
                            Text(category.displayName).tag(ServiceCategory?.some(category))
                        }
                    }
                }
                Section("Date & time") {
                    Toggle("From a specific date", isOn: Binding(
                        get: { draft.onOrAfter != nil },
                        set: { draft.onOrAfter = $0 ? .now : nil }
                    ))
                    if draft.onOrAfter != nil {
                        DatePicker("On or after", selection: Binding(
                            get: { draft.onOrAfter ?? .now },
                            set: { draft.onOrAfter = $0 }
                        ), displayedComponents: .date)
                    }
                    Picker("Time of day", selection: $draft.timeOfDay) {
                        Text("Any").tag(CircuitFilter.TimeOfDay?.none)
                        ForEach(CircuitFilter.TimeOfDay.allCases) { time in
                            Text(time.displayName).tag(CircuitFilter.TimeOfDay?.some(time))
                        }
                    }
                }
                Section("Price & rating") {
                    Toggle("Max price", isOn: Binding(
                        get: { draft.maxPriceMinorUnits != nil },
                        set: { draft.maxPriceMinorUnits = $0 ? 100_000 : nil }
                    ))
                    if let maxPrice = draft.maxPriceMinorUnits {
                        Stepper(CurrencyFormatter.rupees(maxPrice), value: Binding(
                            get: { maxPrice },
                            set: { draft.maxPriceMinorUnits = $0 }
                        ), in: 0...500_000, step: 10_000)
                    }
                    Picker("Minimum rating", selection: $draft.minRating) {
                        Text("Any").tag(Double?.none)
                        ForEach([4.5, 4.0, 3.5, 3.0], id: \.self) { rating in
                            Text("\(rating, specifier: "%.1f")+").tag(Double?.some(rating))
                        }
                    }
                }
                Section("Vet") {
                    Picker("Species handled", selection: $draft.species) {
                        Text("Any").tag(Pet.Species?.none)
                        ForEach(Pet.Species.allCases, id: \.self) { species in
                            Text(species.rawValue.capitalized).tag(Pet.Species?.some(species))
                        }
                    }
                    Picker("Language", selection: $draft.language) {
                        Text("Any").tag(String?.none)
                        ForEach(["English", "Hindi", "Kannada", "Tamil", "Telugu"], id: \.self) { language in
                            Text(language).tag(String?.some(language))
                        }
                    }
                    Picker("Vet gender", selection: $draft.gender) {
                        Text("Any").tag(Vet.Gender?.none)
                        ForEach(Vet.Gender.allCases) { gender in
                            Text(gender.displayName).tag(Vet.Gender?.some(gender))
                        }
                    }
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear") { draft = CircuitFilter() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Apply") {
                        filter = draft
                        onApply()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

/// C9: one-tap "rebook last visit" — plan §3 C9 calls this the
/// highest-converting element in repeat marketplaces, so it sits above
/// everything else rather than buried in visit history.
private struct RebookCard: View {
    let suggestion: RebookLastVisitUseCase.Suggestion
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Theme.primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rebook your last visit").font(.brandHeadline).foregroundStyle(.primary)
                    Text(suggestion.circuit.vet?.name ?? suggestion.circuit.clusterArea)
                        .font(.brandCaption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(14)
            .glassCard()
        }
        .buttonStyle(PressableStyle())
    }
}

/// C9: recently-viewed circuits, most recent first — pure local browsing
/// history (see RecentlyViewedStore), never synced or shown to anyone else.
private struct RecentlyViewedSection: View {
    let circuits: [Circuit]
    let onSelect: (Circuit) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recently viewed").font(.brandHeadline).padding(.horizontal, 4)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(circuits) { circuit in
                        Button { onSelect(circuit) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(circuit.vet?.name ?? "Veterinarian").font(.brandBody).lineLimit(1)
                                Text(circuit.clusterArea).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .padding(12)
                            .frame(width: 160, alignment: .leading)
                            .glassCard()
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
                .padding(.horizontal, 4)
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
        .glassCard()
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    CircuitsListView()
}
