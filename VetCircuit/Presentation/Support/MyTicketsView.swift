import SwiftUI

@Observable
@MainActor
final class MyTicketsViewModel {
    var tickets: [SupportTicket] = []
    var errorMessage: String?

    private let contactSupportUseCase = DependencyContainer.shared.contactSupportUseCase()

    func load(userId: UUID) async {
        do {
            tickets = try await contactSupportUseCase.myTickets(userId: userId)
        } catch {
            errorMessage = error.localizedDescription
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
            if viewModel.tickets.isEmpty && viewModel.errorMessage == nil {
                Text("No support tickets yet.").foregroundStyle(.secondary)
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
                        Text(ticket.body).font(.brandCaption).foregroundStyle(.secondary).lineLimit(2)
                        Text(ticket.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
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
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

#Preview {
    NavigationStack { MyTicketsView().environment(SessionStore()) }
}
