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
    // C1: address-first discovery — replaces v1's free-text "area". The
    // circuits list is scoped to whichever address is selected, not the
    // whole city; an unserved address yields zero circuits (the empty state
    // routes to Addresses/waitlist, C10) instead of silently showing
    // everything.
    var addresses: [Address] = []
    var selectedAddress: Address?
    /// C2: the list is supposed to show slot *and* price alongside rating.
    /// The catalog was already being fetched to drive filtering and then
    /// thrown away; keeping it lets each row show what a visit actually
    /// starts at instead of making the customer open a vet to find out.
    var catalog: [Service] = []

    /// Cheapest thing anyone can book in this area, used as the "from" price
    /// on every row. Deliberately catalog-wide rather than per-vet: a per-vet
    /// override (D5) needs a round trip per circuit, and quoting a number the
    /// row can't stand behind is worse than quoting a floor and saying so.
    var startingPriceMinorUnits: Int? {
        catalog.compactMap(\.startingPriceMinorUnits).min()
    }

    private let getCircuitsUseCase = DependencyContainer.shared.getCircuitsUseCase()
    private let getCatalogUseCase = DependencyContainer.shared.getCatalogUseCase()
    private let getVisitHistoryUseCase = DependencyContainer.shared.getVisitHistoryUseCase()
    private let searchUseCase = DependencyContainer.shared.searchUseCase()
    private let rebookLastVisitUseCase = DependencyContainer.shared.rebookLastVisitUseCase()
    private let manageAddressesUseCase = DependencyContainer.shared.manageAddressesUseCase()

    var isSearching: Bool { !searchArea.trimmingCharacters(in: .whitespaces).isEmpty }

    /// C1: loads the user's addresses (if not already loaded) and picks a
    /// default: the address flagged `isDefault`, else the first one — so a
    /// fresh launch already scopes discovery to somewhere real rather than
    /// showing every circuit in every cluster.
    private func loadAddressesIfNeeded(userId: UUID?) async {
        guard let userId, addresses.isEmpty else { return }
        await refreshAddresses(userId: userId)
    }

    /// Re-fetches addresses (e.g. after the "Manage addresses" sheet is
    /// dismissed, where one may have just been added or its cluster
    /// re-matched) and re-picks a default if the previous selection vanished.
    func refreshAddresses(userId: UUID?) async {
        guard let userId else { return }
        addresses = (try? await manageAddressesUseCase.list(ownerId: userId)) ?? []
        if let selectedAddress, addresses.contains(where: { $0.id == selectedAddress.id }) { return }
        selectedAddress = addresses.first { $0.isDefault } ?? addresses.first
    }

    func selectAddress(_ address: Address) {
        selectedAddress = address
    }

    func load(vertical: Vertical, userId: UUID?) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        await loadAddressesIfNeeded(userId: userId)
        do {
            let catalog = (try? await getCatalogUseCase.execute(vertical: vertical)) ?? []
            self.catalog = catalog
            var previouslyBooked: Set<UUID> = []
            if let userId, let history = try? await getVisitHistoryUseCase.execute(userId: userId) {
                previouslyBooked = Set(history.map(\.vetId))
            }
            // No address on file yet (e.g. brand-new account) falls back to
            // area: nil so discovery isn't a dead end before onboarding adds
            // one; an address that exists but isn't served (`clusterArea ==
            // nil`) deliberately scopes to a cluster no circuit will match.
            let area = selectedAddress?.clusterArea ?? (addresses.isEmpty ? nil : "__unserved__")
            circuits = try await getCircuitsUseCase.execute(
                area: area, vertical: vertical,
                filter: filter, sort: sort, catalog: catalog, previouslyBookedVetIds: previouslyBooked
            )
            recentCircuits = RecentlyViewedStore.shared.recentCircuits(from: circuits)
            if isSearching { await search(vertical: vertical) }
        } catch {
            errorMessage = UserFacingError.message(for: error)
        }
    }

    func search(vertical: Vertical) async {
        guard isSearching else { searchResult = nil; return }
        do {
            searchResult = try await searchUseCase.execute(term: searchArea, vertical: vertical)
        } catch {
            errorMessage = UserFacingError.message(for: error)
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
    @State private var showingAddresses = false
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
                    // C1/C10: an unserved (or unselected) address is a
                    // "come back once we launch here" moment, not a dead end
                    // — route to Addresses, where each unserved address
                    // already offers a waitlist join (AddressListView).
                    EmptyStateView(
                        systemImage: "map", title: "No circuits available in your area yet",
                        message: viewModel.addresses.isEmpty
                            ? "Add an address to see the circuits serving it."
                            : "No vets here yet. Join the waitlist and we'll tell you the moment one starts nearby.",
                        actionTitle: viewModel.addresses.isEmpty ? "Add an address" : "View addresses"
                    ) { showingAddresses = true }
                } else {
                    ScrollView {
                        VStack(spacing: 14) {
                            ScrollOffsetProbe()
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
                            Text("Not an emergency service — for anything life-threatening, call a clinic directly.")
                                .font(.brandCaption)
                                .foregroundStyle(Theme.textSecondary)
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
                                        CircuitRow(
                                            circuit: circuit,
                                            startingPriceMinorUnits: viewModel.startingPriceMinorUnits
                                        )
                                    }
                                    .buttonStyle(PressableStyle())
                                    .appearAnimation(delay: Theme.staggerDelay(index))
                                    // Fades rows slightly as they leave the
                                    // viewport. Opacity only: a scroll
                                    // transition that scales or blurs moves
                                    // the row's hit-test geometry while the
                                    // user is reaching for it.
                                    .scrollTransition { content, phase in
                                        content.opacity(phase.isIdentity ? 1 : 0.65)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    .floatingTabBarScroll()
                    .auroraScreenBackground()
                }
            }
            .animation(Theme.crossFade, value: viewModel.isLoading)
            .animation(Theme.crossFade, value: viewModel.circuits.map(\.id))
            .navigationTitle(selectedVertical.displayName)
            .toolbar {
                // C1: address-first discovery — the picker is the primary way
                // to change what "your area" means, not a hidden setting.
                ToolbarItem(placement: .principal) {
                    Menu {
                        ForEach(viewModel.addresses) { address in
                            Button {
                                viewModel.selectAddress(address)
                                reload()
                            } label: {
                                Label(address.label, systemImage: viewModel.selectedAddress?.id == address.id ? "checkmark" : "")
                            }
                        }
                        Divider()
                        Button("Manage addresses") { showingAddresses = true }
                    } label: {
                        Label(viewModel.selectedAddress?.label ?? "Choose an address", systemImage: "mappin.and.ellipse")
                            .font(.brandCaption)
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        ServiceCatalogView(vertical: selectedVertical, pet: MockData.user.pets.first)
                    } label: {
                        Label("Services", systemImage: "list.bullet.rectangle")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    // C7: map view of cluster coverage.
                    NavigationLink {
                        CoverageMapView()
                    } label: {
                        Label("Coverage map", systemImage: "map")
                            .labelStyle(.iconOnly)
                    }
                    .accessibilityLabel("Coverage map")
                    .accessibilityHint("Shows the areas served by circuits")
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
                    .accessibilityLabel("Sort")
                    .accessibilityHint("Choose how circuits are ordered, currently \(viewModel.sort.displayName)")
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
                    .accessibilityLabel(viewModel.filter.isEmpty ? "Filters" : "Filters, active")
                    .accessibilityHint("Opens filters for service type, date, price, and more")
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
                    .accessibilityLabel("Not sure what you need?")
                    .accessibilityHint("Opens triage to help pick the right service")
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
                    // C9: recorded on arrival rather than via a tap gesture
                    // racing the NavigationLink — the destination appearing
                    // *is* the proof the circuit was viewed.
                    .onAppear { viewModel.recordView(circuit) }
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
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showingAddresses, onDismiss: {
                Task {
                    await viewModel.refreshAddresses(userId: session.currentUser?.id)
                    reload()
                }
            }) {
                NavigationStack { AddressListView() }
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
            ContentUnavailableView.search(text: viewModel.searchArea)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if let circuits = result?.circuits, !circuits.isEmpty {
                        Text("Vets & circuits").font(.brandHeadline).padding(.horizontal, 4)
                        ForEach(circuits) { circuit in
                            NavigationLink(value: circuit) {
                                CircuitRow(circuit: circuit, startingPriceMinorUnits: viewModel.startingPriceMinorUnits)
                            }
                                .buttonStyle(PressableStyle())
                        }
                    }
                    if let services = result?.services, !services.isEmpty {
                        Text("Services").font(.brandHeadline).padding(.horizontal, 4).padding(.top, 8)
                        ForEach(services) { service in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(service.name).font(.brandBody)
                                Text(service.summary).font(.brandCaption).foregroundStyle(Theme.textSecondary)
                            }
                            .padding(12)
                            .glassCard()
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .floatingTabBarScroll()
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
    @State private var hasDateFilter: Bool
    @State private var hasMaxPrice: Bool
    @State private var onOrAfterDate: Date
    @State private var maxPrice: Int

    init(filter: Binding<CircuitFilter>, onApply: @escaping () -> Void) {
        self._filter = filter
        self.onApply = onApply
        let initial = filter.wrappedValue
        self._draft = State(initialValue: initial)
        self._hasDateFilter = State(initialValue: initial.onOrAfter != nil)
        self._hasMaxPrice = State(initialValue: initial.maxPriceMinorUnits != nil)
        self._onOrAfterDate = State(initialValue: initial.onOrAfter ?? .now)
        self._maxPrice = State(initialValue: initial.maxPriceMinorUnits ?? 100_000)
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
                    Toggle("From a specific date", isOn: $hasDateFilter)
                        .onChange(of: hasDateFilter) { _, isOn in
                            draft.onOrAfter = isOn ? onOrAfterDate : nil
                        }
                    if hasDateFilter {
                        DatePicker("On or after", selection: $onOrAfterDate, displayedComponents: .date)
                            .onChange(of: onOrAfterDate) { _, newValue in
                                draft.onOrAfter = newValue
                            }
                    }
                    Picker("Time of day", selection: $draft.timeOfDay) {
                        Text("Any").tag(CircuitFilter.TimeOfDay?.none)
                        ForEach(CircuitFilter.TimeOfDay.allCases) { time in
                            Text(time.displayName).tag(CircuitFilter.TimeOfDay?.some(time))
                        }
                    }
                }
                Section("Price & rating") {
                    Toggle("Max price", isOn: $hasMaxPrice)
                        .onChange(of: hasMaxPrice) { _, isOn in
                            draft.maxPriceMinorUnits = isOn ? maxPrice : nil
                        }
                    if hasMaxPrice {
                        Stepper(CurrencyFormatter.rupees(maxPrice), value: $maxPrice, in: 0...500_000, step: 10_000)
                            .onChange(of: maxPrice) { _, newValue in
                                draft.maxPriceMinorUnits = newValue
                            }
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
                    Button("Clear") {
                        draft = CircuitFilter()
                        hasDateFilter = false
                        hasMaxPrice = false
                        onOrAfterDate = .now
                        maxPrice = 100_000
                    }
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
                        .font(.brandCaption).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.textTertiary)
            }
            .padding(14)
            .glassCard()
            .accessibilityElement(children: .combine)
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
                                Text(circuit.vet?.name ?? "Veterinarian")
                                    .font(.brandBody).lineLimit(1).minimumScaleFactor(0.8)
                                Text(circuit.clusterArea)
                                    .font(.caption).foregroundStyle(Theme.textSecondary)
                                    .lineLimit(1).minimumScaleFactor(0.85)
                            }
                            .padding(12)
                            .frame(width: 160, alignment: .leading)
                            .glassCard()
                            .accessibilityElement(children: .combine)
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
    /// C2: the area's floor price. Optional because the catalog may still be
    /// loading — the row renders without it rather than showing "₹0".
    var startingPriceMinorUnits: Int? = nil

    /// The soonest slot with capacity left. This is the single most useful
    /// thing on the row: "can this vet see my dog soon?" is the question the
    /// list exists to answer.
    private var nextSlot: ScheduleSlot? {
        circuit.schedule
            .filter { $0.isBookable() }
            .min { $0.startTime < $1.startTime }
    }

    private var slotText: String {
        guard let nextSlot else { return "No open slots this week" }
        let day = Calendar.current.isDateInToday(nextSlot.startTime)
            ? "Today"
            : Calendar.current.isDateInTomorrow(nextSlot.startTime)
                ? "Tomorrow"
                : nextSlot.startTime.formatted(.dateTime.weekday(.abbreviated))
        return "\(day), \(nextSlot.startTime.formatted(date: .omitted, time: .shortened))"
    }

    private var isScarce: Bool {
        guard let nextSlot else { return false }
        return nextSlot.remainingCapacity <= 1
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(Theme.gradient)
                    if let photoURL = circuit.vet?.photoURL {
                        AsyncImage(url: photoURL) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Image(systemName: "stethoscope").font(.title3).foregroundStyle(.white)
                        }
                        .clipShape(Circle())
                    } else {
                        Image(systemName: "stethoscope")
                            .font(.title3)
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 50, height: 50)
                .shadow(color: Theme.primary.opacity(0.3), radius: 8, y: 4)
                .allowsHitTesting(false)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(circuit.vet?.name ?? "Veterinarian")
                            .font(.brandHeadline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            // This is the name somebody chooses a vet by.
                            // Shrinking slightly beats an ellipsis through
                            // the middle of it.
                            .minimumScaleFactor(0.8)
                        // L3: the verified badge sits with the name, where a
                        // customer decides whether to trust the row.
                        if circuit.vet?.verificationStatus == .verified {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.caption)
                                .foregroundStyle(Theme.primaryLight)
                        }
                    }

                    Label(circuit.clusterArea, systemImage: "mappin.and.ellipse")
                        .font(.brandCaption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                    if let vet = circuit.vet {
                        HStack(spacing: 6) {
                            Image(systemName: "star.fill")
                                .font(.caption)
                                .foregroundStyle(Theme.goldTier)
                            Text(String(format: "%.1f", vet.rating))
                                .font(.brandMono(.caption))
                            Text("(\(vet.reviewCount))")
                                .font(.brandCaption2)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }

                Spacer(minLength: 4)

                VStack(alignment: .trailing, spacing: 4) {
                    if let startingPriceMinorUnits {
                        Text("from").brandEyebrow()
                        Text(CurrencyFormatter.rupees(startingPriceMinorUnits))
                            .font(.brandMono(.title3, weight: .bold))
                            .foregroundStyle(.primary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            GlassSeam()

            HStack(spacing: 10) {
                Label(slotText, systemImage: "clock.fill")
                    .font(.brandCallout.weight(.semibold))
                    .foregroundStyle(nextSlot == nil ? Color.secondary : Theme.emeraldLight)
                    .lineLimit(1)
                    // "Tomorrow, 4:30 PM" is the answer the screen exists to
                    // give. Losing its tail to an ellipsis makes the row
                    // useless at exactly the sizes where it is hardest to
                    // read anyway.
                    .minimumScaleFactor(0.75)

                Spacer(minLength: 4)

                if isScarce, let nextSlot {
                    // F2: capacity is per-slot, and "1 spot left" is the kind
                    // of detail that decides a booking. Shown only when it is
                    // actually scarce, so it never reads as a growth-hack.
                    TagChip(
                        text: nextSlot.remainingCapacity == 1 ? "1 spot left" : "Filling up",
                        systemImage: "flame.fill", tint: Theme.warning
                    )
                } else if let languages = circuit.vet?.languages, !languages.isEmpty {
                    TagChip(text: languages.prefix(2).joined(separator: ", "), systemImage: "globe", tint: Theme.primary)
                }
            }
        }
        .padding(16)
        .glassCard()
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = [circuit.vet?.name ?? "Veterinarian", circuit.clusterArea]
        if let vet = circuit.vet {
            parts.append("rated \(String(format: "%.1f", vet.rating)) from \(vet.reviewCount) reviews")
            if vet.verificationStatus == .verified { parts.append("verified") }
        }
        parts.append("next slot \(slotText)")
        if let startingPriceMinorUnits {
            parts.append("from \(CurrencyFormatter.rupees(startingPriceMinorUnits))")
        }
        return parts.joined(separator: ", ")
    }
}

#Preview {
    CircuitsListView()
}
