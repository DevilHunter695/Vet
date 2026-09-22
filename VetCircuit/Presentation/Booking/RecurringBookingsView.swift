import SwiftUI

// F5: view/pause/cancel a recurring booking rule created from BookingView's
// "Make this recurring" toggle. Spawning the next visit each cycle is a
// scheduled-job concern, not this screen's — see TECHNICAL_PLAN.md's F5 row.

@Observable
@MainActor
final class RecurringBookingsViewModel {
    var rules: [RecurringBookingRule] = []
    var errorMessage: String?

    private let manageRecurringBookingUseCase = DependencyContainer.shared.manageRecurringBookingUseCase()

    /// False until the first load finishes.
    ///
    /// Without it the empty state rendered instantly on every open, so on a
    /// slow connection the first thing anybody saw was the app stating as
    /// fact something it had not yet checked.
    private(set) var hasLoaded = false

    func load(userId: UUID) async {
        defer { hasLoaded = true }
        do {
            rules = try await manageRecurringBookingUseCase.list(userId: userId)
        } catch {
            errorMessage = UserFacingError.message(for: error)
        }
    }

    func toggle(_ rule: RecurringBookingRule) async {
        do {
            let updated = try await manageRecurringBookingUseCase.setActive(id: rule.id, isActive: !rule.isActive)
            if let index = rules.firstIndex(where: { $0.id == rule.id }) { rules[index] = updated }
        } catch {
            errorMessage = UserFacingError.message(for: error)
        }
    }

    func cancel(_ rule: RecurringBookingRule) async {
        do {
            try await manageRecurringBookingUseCase.cancel(id: rule.id)
            rules.removeAll { $0.id == rule.id }
        } catch {
            errorMessage = UserFacingError.message(for: error)
        }
    }
}

struct RecurringBookingsView: View {
    @Environment(SessionStore.self) private var session
    @State private var viewModel = RecurringBookingsViewModel()
    @State private var pendingCancel: RecurringBookingRule?

    var body: some View {
        List {
            if let errorMessage = viewModel.errorMessage {
                ErrorBanner(message: errorMessage)
            }
            if viewModel.hasLoaded && viewModel.rules.isEmpty && viewModel.errorMessage == nil {
                Text("No recurring bookings yet — toggle \"Make this recurring\" when booking a deworming or physio visit.")
                    .foregroundStyle(Theme.textSecondary)
            }
            ForEach(viewModel.rules) { rule in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(rule.cadence.displayName).font(.brandHeadline)
                        Spacer()
                        Text(rule.isActive ? "Active" : "Paused")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background((rule.isActive ? Theme.success : Theme.warning).opacity(0.15))
                            .foregroundStyle(rule.isActive ? Theme.success : Theme.warning)
                            .clipShape(Capsule())
                    }
                    Text("Next: \(rule.nextOccurrenceAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.brandCaption).foregroundStyle(Theme.textSecondary)
                    // Were ~17pt tall and 16pt apart, with the irreversible
                    // one undefended. PillButton is 44pt by construction.
                    HStack(spacing: 10) {
                        PillButton(
                            title: rule.isActive ? "Pause" : "Resume",
                            systemImage: rule.isActive ? "pause.fill" : "play.fill"
                        ) {
                            Task { await viewModel.toggle(rule) }
                        }
                        PillButton(title: "Cancel", systemImage: "xmark", tint: Theme.danger) {
                            pendingCancel = rule
                        }
                        Spacer(minLength: 0)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.vertical, 4)
            }
        }
        // The aurora is the app's ground everywhere else; a List that keeps
        // its own opaque system background would read as a different app.
        .scrollContentBackground(.hidden)
        .auroraScreenBackground()
        .navigationTitle("Recurring bookings")
        .task { if let user = session.currentUser { await viewModel.load(userId: user.id) } }
        .confirmationDialog(
            "Cancel this recurring booking?",
            isPresented: Binding(get: { pendingCancel != nil }, set: { if !$0 { pendingCancel = nil } }),
            titleVisibility: .visible
        ) {
            if let pendingCancel {
                Button("Cancel \(pendingCancel.cadence.displayName.lowercased()) booking", role: .destructive) {
                    let rule = pendingCancel
                    self.pendingCancel = nil
                    Task { await viewModel.cancel(rule) }
                }
            }
            Button("Keep it", role: .cancel) { pendingCancel = nil }
        } message: {
            Text("No further visits. Pause instead to skip a while — that's reversible.")
        }
    }
}

#Preview {
    NavigationStack { RecurringBookingsView().environment(SessionStore()) }
}
