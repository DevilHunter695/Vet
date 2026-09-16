import SwiftUI
import WidgetKit

@Observable
@MainActor
final class VisitHistoryViewModel {
    var visits: [Visit] = []
    var isLoading = false
    var errorMessage: String?
    /// F4 + plan §9 rule 3: shown as a confirmation before the customer
    /// commits to cancelling, so the money/time consequence is never a surprise.
    var pendingCancellation: (visit: Visit, outcome: CancellationPolicy.Outcome)?
    /// A visit row that says only "14 Mar, 4:00 PM" makes the customer open
    /// it to find out which pet it was for. These maps let the list answer
    /// "who, with whom" without a round trip per row.
    var petsById: [UUID: Pet] = [:]
    var vetsById: [UUID: Vet] = [:]

    private let circuitRepository = DependencyContainer.shared.circuitRepository

    func pet(for visit: Visit) -> Pet? { petsById[visit.petId] }
    func vet(for visit: Visit) -> Vet? { vetsById[visit.vetId] }

    /// I1: the visit that deserves the "happening now" treatment. The old
    /// version only matched requested/confirmed/enRoute, so a vet who had
    /// actually *arrived* or started the visit dropped out of the card and
    /// into plain history — exactly when the card matters most.
    var activeVisit: Visit? {
        let live = visits.filter { $0.status.isLive }
        if let soonestLive = live.min(by: { $0.scheduledAt < $1.scheduledAt }) { return soonestLive }
        return visits
            .filter { $0.status.isUpcoming }
            .min { $0.scheduledAt < $1.scheduledAt }
    }

    var upcomingVisits: [Visit] {
        visits
            .filter { $0.status.isUpcoming && $0.id != activeVisit?.id }
            .sorted { $0.scheduledAt < $1.scheduledAt }
    }

    var pastVisits: [Visit] {
        visits
            .filter { !$0.status.isUpcoming && $0.id != activeVisit?.id }
            .sorted { $0.scheduledAt > $1.scheduledAt }
    }

    var completedCount: Int { visits.filter { $0.status == .completed }.count }

    private let getVisitHistoryUseCase = DependencyContainer.shared.getVisitHistoryUseCase()
    private let cancelVisitUseCase = DependencyContainer.shared.cancelVisitUseCase()
    private let vaccinationRepository = DependencyContainer.shared.vaccinationRepository
    private let sendPostVisitSummaryUseCase = DependencyContainer.shared.sendPostVisitSummaryUseCase()
    private let flagVisitNoShowUseCase = DependencyContainer.shared.flagVisitNoShowUseCase()

    func load(userId: UUID, currentUser: User?) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            visits = try await getVisitHistoryUseCase.execute(userId: userId)
            await loadNameLookups(userId: userId)
            await refreshWidgetData(userId: userId)
            // I8: best-effort post-visit summary push — see the honest gap
            // on PostVisitSummaryRepository (this is client-detected, not
            // server-triggered the moment a visit actually completes).
            if let currentUser {
                for visit in visits where visit.status == .completed {
                    try? await sendPostVisitSummaryUseCase.execute(user: currentUser, visit: visit)
                }
            }
            // F4: same pattern as the post-visit summary push above — flag
            // (and cancel, per CancellationPolicy's 100%-charged branch) any
            // visit that's sat in requested/confirmed past its scheduled
            // time, deduped locally so it's only acted on once.
            for index in visits.indices where visits[index].status == .requested || visits[index].status == .confirmed {
                if let flagged = try? await flagVisitNoShowUseCase.execute(visit: visits[index]), flagged {
                    withAnimation(Theme.springSoft) { visits[index].status = .cancelledByUser }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Best-effort name resolution for the list rows. A failure here costs a
    /// row its pet/vet name, which is worth far less than failing the load.
    private func loadNameLookups(userId: UUID) async {
        if let pets = try? await DependencyContainer.shared.petRepository.listPets(ownerId: userId) {
            petsById = Dictionary(uniqueKeysWithValues: pets.map { ($0.id, $0) })
        }
        if let circuits = try? await circuitRepository.listCircuits(area: nil) {
            for circuit in circuits {
                if let vet = circuit.vet { vetsById[vet.id] = vet }
            }
        }
    }

    /// N6: this is the write side of the widget bridge — the only place in
    /// the app that populates `SharedVisitSummary`, since this screen is
    /// already the source of truth for "what's my next visit". A reasonable
    /// simplification: the widget then refreshes on WidgetKit's own timeline
    /// schedule rather than via a live push the instant this write happens,
    /// though the `WidgetCenter.reloadTimelines` call below does ask iOS to
    /// refresh promptly when the app is foregrounded.
    private func refreshWidgetData(userId: UUID) async {
        guard let pets = try? await DependencyContainer.shared.petRepository.listPets(ownerId: userId) else { return }
        var vaccinationsByPet: [UUID: [Vaccination]] = [:]
        for pet in pets {
            if let history = try? await vaccinationRepository.history(petId: pet.id) {
                vaccinationsByPet[pet.id] = history
            }
        }
        let summary = WidgetDataBridge.summarize(visits: visits, pets: pets, vaccinationsByPet: vaccinationsByPet)
        WidgetDataBridge.write(summary)
        WidgetCenter.shared.reloadTimelines(ofKind: "VetCircuitNextVisitWidget")
    }

    func requestCancellation(_ visit: Visit) async {
        do {
            let outcome = try await cancelVisitUseCase.preview(visitId: visit.id, scheduledAt: visit.scheduledAt)
            pendingCancellation = (visit, outcome)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// SwiftUI tears `confirmationDialog`'s `isPresented` binding down
    /// *before* it runs the tapped button's action, so a `confirmCancellation()`
    /// that read `pendingCancellation` back off the view model always found it
    /// nil by then and returned without cancelling anything — the "the cancel
    /// button doesn't cancel" bug. The dialog hands the value it is presenting
    /// to both closures, so take it as a parameter instead of re-reading state
    /// that is already gone.
    func confirmCancellation(_ pending: (visit: Visit, outcome: CancellationPolicy.Outcome)) async {
        pendingCancellation = nil
        do {
            try await cancelVisitUseCase.execute(
                visitId: pending.visit.id, currentStatus: pending.visit.status,
                scheduledAt: pending.visit.scheduledAt, paymentId: pending.visit.paymentId
            )
            if let index = visits.firstIndex(where: { $0.id == pending.visit.id }) {
                // Cancelling moves this visit out of "Happening now" and changes
                // its badge — without an explicit animation it just snaps
                // between sections instead of settling there.
                withAnimation(Theme.springSoft) { visits[index].status = .cancelledByUser }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct VisitHistoryView: View {
    @Environment(SessionStore.self) private var session
    @Environment(Router.self) private var router
    @State private var viewModel = VisitHistoryViewModel()

    /// The nearest live-or-upcoming visit, resolved on the view model so the
    /// grouping and the card agree on what "now" means.
    private var activeVisit: Visit? { viewModel.activeVisit }

    var body: some View {
        // N7: path is now driven by the shared Router so `.onOpenURL` can
        // push straight into this tab's `.chat`/`.visitDetail` routes
        // instead of only switching to this tab — see Router.handle(_:).
        NavigationStack(path: Bindable(router).visitsPath) {
            Group {
                if viewModel.isLoading && viewModel.visits.isEmpty {
                    loadingPlaceholder
                } else if viewModel.visits.isEmpty {
                    EmptyStateView(
                        systemImage: "calendar.badge.clock", title: "No visits yet",
                        message: "Once you book a visit, you'll track it here from request to completion — with the vet's ETA, a live map, and the full record afterwards."
                    )
                } else {
                    visitList
                }
            }
            .auroraScreenBackground()
            .navigationTitle("Your visits")
            // N7: `.chat` needs only the id (ChatView(visitId:)); `.visitDetail`
            // is resolved against the already-loaded `visits` array, same as
            // CircuitsListView already resolves `.book` against its own
            // loaded circuits.
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .visitDetail(let id):
                    if let visit = viewModel.visits.first(where: { $0.id == id }) {
                        VisitDetailView(visit: visit)
                    }
                case .chat(let visitId):
                    ChatView(visitId: visitId)
                case .household:
                    EmptyView()
                }
            }
            .task { if let user = session.currentUser { await viewModel.load(userId: user.id, currentUser: user) } }
            .refreshable {
                Haptics.tap()
                if let user = session.currentUser { await viewModel.load(userId: user.id, currentUser: user) }
            }
            .confirmationDialog(
                "Cancel this visit?",
                isPresented: Binding(get: { viewModel.pendingCancellation != nil }, set: { if !$0 { viewModel.pendingCancellation = nil } }),
                presenting: viewModel.pendingCancellation
            ) { pending in
                Button("Cancel visit", role: .destructive) {
                    Haptics.warning()
                    Task { await viewModel.confirmCancellation(pending) }
                }
                Button("Keep visit", role: .cancel) {}
            } message: { pending in
                // Plan §9 rule 3: state the consequence in money and time, never a bare "are you sure".
                if pending.outcome.isPastVisitTime {
                    Text("This visit's time has passed — no refund applies.")
                } else if pending.outcome.refundPercent == 100 {
                    Text("Cancelling now refunds \(CurrencyFormatter.rupees(pending.outcome.refundMinorUnits)) in full.")
                } else {
                    Text("Cancelling now refunds \(CurrencyFormatter.rupees(pending.outcome.refundMinorUnits)) of \(CurrencyFormatter.rupees(pending.outcome.paidMinorUnits)) (within \(Int(CancellationPolicy.freeWindowHours))h of the visit).")
                }
            }
        }
    }

    private var loadingPlaceholder: some View {
        ScrollView {
            VStack(spacing: 14) {
                ShimmerView(cornerRadius: 20).frame(height: 150)
                ForEach(0..<3, id: \.self) { _ in
                    ShimmerView(cornerRadius: 18).frame(height: 84)
                }
            }
            .padding(16)
        }
        .scrollContentBackground(.hidden)
    }

    private var visitList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                if let activeVisit {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(
                            title: activeVisit.status.isLive ? "Happening now" : "Up next",
                            systemImage: activeVisit.status.isLive ? "dot.radiowaves.left.and.right" : "calendar"
                        )
                        ActiveVisitCard(
                            visit: activeVisit,
                            pet: viewModel.pet(for: activeVisit),
                            vet: viewModel.vet(for: activeVisit),
                            onCancel: { Task { await viewModel.requestCancellation(activeVisit) } }
                        )
                    }
                    .appearAnimation()
                }

                if !viewModel.upcomingVisits.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(
                            title: "Upcoming",
                            subtitle: "\(viewModel.upcomingVisits.count) more booked",
                            systemImage: "calendar.badge.clock"
                        )
                        ForEach(viewModel.upcomingVisits) { visit in
                            VisitRow(
                                visit: visit,
                                pet: viewModel.pet(for: visit),
                                vet: viewModel.vet(for: visit),
                                onCancel: { Task { await viewModel.requestCancellation(visit) } }
                            )
                        }
                    }
                }

                if !viewModel.pastVisits.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(
                            title: "History",
                            subtitle: viewModel.completedCount == 0
                                ? nil
                                : "\(viewModel.completedCount) visit\(viewModel.completedCount == 1 ? "" : "s") completed",
                            systemImage: "clock.arrow.circlepath"
                        )
                        ForEach(Array(viewModel.pastVisits.enumerated()), id: \.element.id) { index, visit in
                            VisitRow(
                                visit: visit,
                                pet: viewModel.pet(for: visit),
                                vet: viewModel.vet(for: visit),
                                onCancel: { Task { await viewModel.requestCancellation(visit) } }
                            )
                            .appearAnimation(delay: Theme.staggerDelay(index))
                        }
                    }
                }

                if let error = viewModel.errorMessage {
                    ErrorBanner(message: error)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .scrollContentBackground(.hidden)
        .animation(Theme.springQuick, value: viewModel.visits.count)
    }
}

/// I1: the "happening now" card. Not a row with a badge — a surface that
/// answers, without a tap: which pet, which vet, when, how far along, and
/// what the customer can do about it right now (track, message, cancel).
private struct ActiveVisitCard: View {
    let visit: Visit
    let pet: Pet?
    let vet: Vet?
    let onCancel: () -> Void

    private var headline: String {
        switch visit.status {
        case .requested: return "Waiting for a vet to accept"
        case .confirmed: return "Booked and confirmed"
        case .assigned: return "\(vet?.name ?? "Your vet") is assigned"
        case .enRoute: return "\(vet?.name ?? "Your vet") is on the way"
        case .arrived: return "\(vet?.name ?? "Your vet") has arrived"
        case .inProgress: return "Visit in progress"
        default: return visit.status.displayText
        }
    }

    private var relativeTime: String {
        let interval = visit.scheduledAt.timeIntervalSinceNow
        if interval <= 0 { return "Scheduled for now" }
        let minutes = Int(interval / 60)
        if minutes < 60 { return "In \(max(1, minutes)) min" }
        let hours = minutes / 60
        if hours < 24 { return "In \(hours) hr \(minutes % 60) min" }
        return "In \(hours / 24) day\(hours / 24 == 1 ? "" : "s")"
    }

    /// I2: how far through the eight-state machine this visit is, as a
    /// fraction — the timeline in miniature, so the card shows progress
    /// rather than a single word.
    private var progress: CGFloat {
        switch visit.status {
        case .requested: return 0.12
        case .confirmed: return 0.28
        case .assigned: return 0.45
        case .enRoute: return 0.65
        case .arrived: return 0.82
        case .inProgress: return 0.93
        case .completed, .resolved: return 1
        default: return 0
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                if visit.status.isLive {
                    PulsingDot(color: Theme.inProgress)
                        .padding(.top, 6)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(headline)
                        .font(.brandTitle3)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(visit.scheduledAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.brandCaption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 4)
                StatusBadge(status: visit.status)
            }

            if !visit.status.isLive {
                Text(relativeTime)
                    .font(.brandMono(.callout, weight: .bold))
                    .foregroundStyle(Theme.emeraldLight)
            }

            VisitProgressBar(progress: progress)
                .frame(height: 6)

            HStack(spacing: 10) {
                if let pet {
                    TagChip(text: pet.name, systemImage: "pawprint.fill", tint: Theme.primary)
                }
                if let vet {
                    TagChip(text: vet.name, systemImage: "stethoscope", tint: Theme.emerald)
                }
                Spacer(minLength: 0)
            }

            Divider().opacity(0.35)

            HStack(spacing: 10) {
                NavigationLink {
                    VisitDetailView(visit: visit)
                } label: {
                    Text("Open visit")
                        .font(.brandCaption)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                        .foregroundStyle(.white)
                        .background(Theme.gradient, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle(scale: 0.96))

                NavigationLink {
                    ChatView(visitId: visit.id)
                } label: {
                    Label("Message", systemImage: "bubble.left.fill")
                        .font(.brandCaption)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                        .foregroundStyle(Theme.primary)
                        .background(Theme.primary.opacity(0.12), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle(scale: 0.96))

                if visit.status == .requested || visit.status == .confirmed {
                    Button {
                        Haptics.warning()
                        onCancel()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .foregroundStyle(Theme.danger)
                            .background(Theme.danger.opacity(0.12), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(PressableStyle(scale: 0.92))
                    .accessibilityLabel("Cancel visit")
                }
            }
        }
        .padding(18)
        .featuredGlassCard(tint: visit.status.isLive ? Theme.inProgress : Theme.emerald)
    }
}

/// The eight-state machine as a single bar. Separate from `ProgressTrack` in
/// ProfileView because this one is always brand-gradient and never tinted per
/// tier — the state, not the colour, is the information.
private struct VisitProgressBar: View {
    let progress: CGFloat

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule()
                    .fill(Theme.gradient)
                    .frame(width: max(0, geo.size.width * progress))
                    .shadow(color: Theme.primary.opacity(0.5), radius: 6, y: 2)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .animation(Theme.springSoft, value: progress)
    }
}

private struct VisitRow: View {
    let visit: Visit
    let pet: Pet?
    let vet: Vet?
    let onCancel: () -> Void

    private var canCancel: Bool {
        visit.status == .requested || visit.status == .confirmed
    }

    var body: some View {
        NavigationLink {
            VisitDetailView(visit: visit)
        } label: {
            HStack(spacing: 14) {
                // A calendar block reads faster than a sentence-cased date
                // when scanning a column of past visits.
                VStack(spacing: 1) {
                    Text(visit.scheduledAt.formatted(.dateTime.month(.abbreviated)))
                        .font(.brandCaption2)
                        .foregroundStyle(Theme.primary)
                    Text(visit.scheduledAt.formatted(.dateTime.day()))
                        .font(.brandMono(.title3, weight: .bold))
                }
                .frame(width: 46, height: 46)
                .background(Theme.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(pet?.name ?? "Visit")
                        .font(.brandHeadline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(
                        [vet?.name, visit.scheduledAt.formatted(date: .omitted, time: .shortened)]
                            .compactMap { $0 }.joined(separator: " · ")
                    )
                    .font(.brandCaption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                }

                Spacer(minLength: 4)

                VStack(alignment: .trailing, spacing: 6) {
                    StatusBadge(status: visit.status)
                    if visit.hasStructuredRecord {
                        Text("Record ready").brandEyebrow()
                    }
                }
            }
            .padding(14)
            .glassCard(cornerRadius: 18)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(PressableStyle(scale: 0.985))
        // These rows are cards in a LazyVStack, not List rows, so
        // `swipeActions` would compile and quietly do nothing. Long-press is
        // the affordance that actually works here; the visit that is most
        // likely to be cancelled is the active one, and that card carries an
        // explicit cancel button.
        .contextMenu {
            if canCancel {
                Button("Cancel visit", systemImage: "xmark.circle", role: .destructive) {
                    Haptics.warning()
                    onCancel()
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(pet?.name ?? "Visit"), \(visit.scheduledAt.formatted(date: .abbreviated, time: .shortened)), \(visit.status.displayText)")
    }
}


private struct PulsingDot: View {
    let color: Color
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().fill(color).frame(width: 8, height: 8)
            if !reduceMotion {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                    .scaleEffect(pulse ? 2.4 : 1)
                    .opacity(pulse ? 0 : 0.8)
            }
        }
        // Purely decorative, and it overflows its 8pt frame while pulsing —
        // exactly the kind of layer that should never intercept a tap.
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

#Preview {
    VisitHistoryView().environment(SessionStore()).environment(Router())
}
