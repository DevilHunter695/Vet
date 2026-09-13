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

    private let getVisitHistoryUseCase = DependencyContainer.shared.getVisitHistoryUseCase()
    private let cancelVisitUseCase = DependencyContainer.shared.cancelVisitUseCase()
    private let vaccinationRepository = DependencyContainer.shared.vaccinationRepository

    func load(userId: UUID) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            visits = try await getVisitHistoryUseCase.execute(userId: userId)
            await refreshWidgetData(userId: userId)
        } catch {
            errorMessage = error.localizedDescription
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

    func confirmCancellation() async {
        guard let pending = pendingCancellation else { return }
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
    @State private var viewModel = VisitHistoryViewModel()

    /// The nearest upcoming, non-terminal visit — surfaced prominently so the
    /// user always sees "what's happening right now" without hunting for it.
    private var activeVisit: Visit? {
        viewModel.visits
            .filter { $0.status == .confirmed || $0.status == .enRoute || $0.status == .requested }
            .sorted { $0.scheduledAt < $1.scheduledAt }
            .first
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading && viewModel.visits.isEmpty {
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(0..<3, id: \.self) { _ in
                                ShimmerView().frame(height: 64)
                            }
                        }
                        .padding()
                    }
                } else if viewModel.visits.isEmpty {
                    EmptyStateView(systemImage: "calendar.badge.clock", title: "No visits yet",
                                   message: "Once you book a visit, you'll be able to track it here from request to completion.")
                } else {
                    List {
                        if let activeVisit {
                            Section("Happening now") {
                                VisitRow(visit: activeVisit, isPrimary: true) {
                                    Task { await viewModel.requestCancellation(activeVisit) }
                                }
                            }
                        }
                        Section("History") {
                            ForEach(Array(viewModel.visits.filter { $0.id != activeVisit?.id }.enumerated()), id: \.element.id) { index, visit in
                                VisitRow(visit: visit, isPrimary: false) {
                                    Task { await viewModel.requestCancellation(visit) }
                                }
                                .appearAnimation(delay: Theme.staggerDelay(index))
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .background(Color(.systemGroupedBackground))
                    .animation(Theme.springQuick, value: viewModel.visits.count)
                }
            }
            .navigationTitle("Your visits")
            .task { if let user = session.currentUser { await viewModel.load(userId: user.id) } }
            .refreshable {
                Haptics.tap()
                if let user = session.currentUser { await viewModel.load(userId: user.id) }
            }
            .confirmationDialog(
                "Cancel this visit?",
                isPresented: Binding(get: { viewModel.pendingCancellation != nil }, set: { if !$0 { viewModel.pendingCancellation = nil } }),
                presenting: viewModel.pendingCancellation
            ) { _ in
                Button("Cancel visit", role: .destructive) {
                    Haptics.warning()
                    Task { await viewModel.confirmCancellation() }
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
}

private struct VisitRow: View {
    let visit: Visit
    let isPrimary: Bool
    let onCancel: () -> Void

    var body: some View {
        NavigationLink {
            VisitDetailView(visit: visit)
        } label: {
            HStack(spacing: 12) {
                if isPrimary {
                    PulsingDot(color: visit.status == .enRoute ? Theme.inProgress : Theme.primary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(visit.scheduledAt.formatted(date: .abbreviated, time: .shortened))
                            .font(isPrimary ? .brandHeadline : .brandBody)
                        Spacer()
                        StatusBadge(status: visit.status)
                    }
                    if isPrimary, visit.status == .enRoute {
                        Text("Vet is on the way").font(.brandCaption).foregroundStyle(Theme.inProgress)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .swipeActions {
            if visit.status == .requested || visit.status == .confirmed {
                Button("Cancel", role: .destructive) {
                    Haptics.warning()
                    onCancel()
                }
                .tint(Theme.danger)
            }
        }
    }
}

private struct PulsingDot: View {
    let color: Color
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle().fill(color).frame(width: 8, height: 8)
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .scaleEffect(pulse ? 1.8 : 1)
                .opacity(pulse ? 0 : 1)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

#Preview {
    VisitHistoryView().environment(SessionStore())
}
