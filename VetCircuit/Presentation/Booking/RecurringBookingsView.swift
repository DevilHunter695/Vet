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

    func load(userId: UUID) async {
        do {
            rules = try await manageRecurringBookingUseCase.list(userId: userId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggle(_ rule: RecurringBookingRule) async {
        do {
            let updated = try await manageRecurringBookingUseCase.setActive(id: rule.id, isActive: !rule.isActive)
            if let index = rules.firstIndex(where: { $0.id == rule.id }) { rules[index] = updated }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancel(_ rule: RecurringBookingRule) async {
        do {
            try await manageRecurringBookingUseCase.cancel(id: rule.id)
            rules.removeAll { $0.id == rule.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct RecurringBookingsView: View {
    @Environment(SessionStore.self) private var session
    @State private var viewModel = RecurringBookingsViewModel()

    var body: some View {
        List {
            if let errorMessage = viewModel.errorMessage {
                ErrorBanner(message: errorMessage)
            }
            if viewModel.rules.isEmpty && viewModel.errorMessage == nil {
                Text("No recurring bookings yet — toggle \"Make this recurring\" when booking a deworming or physio visit.")
                    .foregroundStyle(.secondary)
            }
            ForEach(viewModel.rules) { rule in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(rule.cadence.displayName).font(.brandHeadline)
                        Spacer()
                        Text(rule.isActive ? "Active" : "Paused")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background((rule.isActive ? Theme.success : Theme.warning).opacity(0.15))
                            .foregroundStyle(rule.isActive ? Theme.success : Theme.warning)
                            .clipShape(Capsule())
                    }
                    Text("Next: \(rule.nextOccurrenceAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.brandCaption).foregroundStyle(.secondary)
                    HStack(spacing: 16) {
                        Button(rule.isActive ? "Pause" : "Resume") {
                            Task { await viewModel.toggle(rule) }
                        }
                        Button("Cancel", role: .destructive) {
                            Task { await viewModel.cancel(rule) }
                        }
                    }
                    .font(.brandCaption.weight(.semibold))
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
    }
}

#Preview {
    NavigationStack { RecurringBookingsView().environment(SessionStore()) }
}
