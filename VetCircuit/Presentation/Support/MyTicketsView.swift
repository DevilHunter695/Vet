import SwiftUI

@Observable
@MainActor
final class MyTicketsViewModel {
    var tickets: [SupportTicket] = []
    /// False until the first load finishes.
    ///
    /// Without it the empty state rendered instantly on every open, so on a
    /// slow connection "No tickets yet" was the first thing anybody saw —
    /// stating as fact something the app had not yet checked.
    private(set) var hasLoaded = false
    var errorMessage: String?

    private let contactSupportUseCase = DependencyContainer.shared.contactSupportUseCase()

    func load(userId: UUID) async {
        defer { hasLoaded = true }
        do {
            tickets = try await contactSupportUseCase.myTickets(userId: userId)
        } catch {
            errorMessage = UserFacingError.message(for: error)
        }
    }
}

struct MyTicketsView: View {
    @Environment(SessionStore.self) private var session
    @State private var viewModel = MyTicketsViewModel()
    @State private var showingNewTicket = false

    var body: some View {
        List {
            if let errorMessage = viewModel.errorMessage {
                ErrorBanner(message: errorMessage)
            }
            if viewModel.hasLoaded && viewModel.tickets.isEmpty && viewModel.errorMessage == nil {
                EmptyStateView(
                    systemImage: "bubble.left.and.bubble.right",
                    title: "No tickets yet",
                    message: "Anything gone wrong with a visit, a charge or your account — raise it here and you'll get a reply in the app.",
                    actionTitle: "Contact support"
                ) {
                    showingNewTicket = true
                }
                .listRowBackground(Color.clear)
            }
            ForEach(viewModel.tickets) { ticket in
                NavigationLink {
                    TicketDetailView(ticket: ticket)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(ticket.subject).font(.brandHeadline)
                            Spacer()
                            StatusChip(status: ticket.status)
                        }
                        Text(ticket.body).font(.brandCaption).foregroundStyle(Theme.textSecondary).lineLimit(2)
                        Text(ticket.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.brandCaption).foregroundStyle(Theme.textTertiary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        // The aurora is the app's ground everywhere else; a List that keeps
        // its own opaque system background would read as a different app.
        .scrollContentBackground(.hidden)
        .auroraScreenBackground()
        .floatingTabBarInset()
        .navigationTitle("My tickets")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingNewTicket = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New ticket")
            }
        }
        .sheet(isPresented: $showingNewTicket, onDismiss: {
            Task { if let user = session.currentUser { await viewModel.load(userId: user.id) } }
        }) {
            ContactSupportView()
        }
        .task { if let user = session.currentUser { await viewModel.load(userId: user.id) } }
    }
}

private struct StatusChip: View {
    let status: SupportTicket.Status

    private var color: Color {
        switch status {
        case .open: return Theme.danger
        case .inProgress: return Theme.inProgress
        case .resolved: return Theme.success
        }
    }

    var body: some View {
        Text(status.displayName)
            .font(.brandCaption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

#Preview {
    NavigationStack { MyTicketsView().environment(SessionStore()) }
}
