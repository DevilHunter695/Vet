import SwiftUI

@Observable
@MainActor
final class VisitHistoryViewModel {
    var visits: [Visit] = []
    var isLoading = false
    var errorMessage: String?

    private let getVisitHistoryUseCase = DependencyContainer.shared.getVisitHistoryUseCase()
    private let cancelVisitUseCase = DependencyContainer.shared.cancelVisitUseCase()

    func load(userId: UUID) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            visits = try await getVisitHistoryUseCase.execute(userId: userId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancel(_ visit: Visit) async {
        do {
            try await cancelVisitUseCase.execute(visitId: visit.id, currentStatus: visit.status)
            if let index = visits.firstIndex(where: { $0.id == visit.id }) {
                visits[index].status = .cancelled
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
                    ProgressView()
                } else if viewModel.visits.isEmpty {
                    EmptyStateView(systemImage: "calendar.badge.clock", title: "No visits yet",
                                   message: "Once you book a visit, you'll be able to track it here from request to completion.")
                } else {
                    List {
                        if let activeVisit {
                            Section("Happening now") {
                                VisitRow(visit: activeVisit, isPrimary: true) {
                                    Task { await viewModel.cancel(activeVisit) }
                                }
                            }
                        }
                        Section("History") {
                            ForEach(viewModel.visits.filter { $0.id != activeVisit?.id }) { visit in
                                VisitRow(visit: visit, isPrimary: false) {
                                    Task { await viewModel.cancel(visit) }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Your visits")
            .task { if let user = session.currentUser { await viewModel.load(userId: user.id) } }
            .refreshable { if let user = session.currentUser { await viewModel.load(userId: user.id) } }
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
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(visit.scheduledAt.formatted(date: .abbreviated, time: .shortened))
                        .font(isPrimary ? .headline : .subheadline)
                    Spacer()
                    StatusBadge(status: visit.status)
                }
                if isPrimary, visit.status == .enRoute {
                    Text("Vet is on the way").font(.caption).foregroundStyle(.purple)
                }
            }
            .padding(.vertical, 4)
        }
        .swipeActions {
            if visit.status == .requested || visit.status == .confirmed {
                Button("Cancel", role: .destructive, action: onCancel)
            }
        }
    }
}

#Preview {
    VisitHistoryView().environment(SessionStore())
}
