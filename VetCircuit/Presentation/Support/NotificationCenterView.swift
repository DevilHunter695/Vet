import SwiftUI

/// J7: the in-app notification *history* — distinct from
/// `NotificationPreferencesView`'s per-channel opt-in/out toggles.
@Observable
@MainActor
final class NotificationCenterViewModel {
    var notifications: [AppNotification] = []
    var errorMessage: String?

    private let getNotificationCenterUseCase = DependencyContainer.shared.getNotificationCenterUseCase()

    func load(userId: UUID) async {
        do {
            notifications = try await getNotificationCenterUseCase.execute(userId: userId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func markRead(_ notification: AppNotification) async {
        guard !notification.isRead else { return }
        guard let index = notifications.firstIndex(where: { $0.id == notification.id }) else { return }
        notifications[index].readAt = .now
        try? await getNotificationCenterUseCase.markRead(id: notification.id)
    }
}

struct NotificationCenterView: View {
    @Environment(SessionStore.self) private var session
    @State private var viewModel = NotificationCenterViewModel()

    var body: some View {
        List {
            if let errorMessage = viewModel.errorMessage {
                ErrorBanner(message: errorMessage)
            }
            if viewModel.notifications.isEmpty && viewModel.errorMessage == nil {
                Text("No notifications yet.").foregroundStyle(.secondary)
            }
            ForEach(viewModel.notifications) { notification in
                Button {
                    Task { await viewModel.markRead(notification) }
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Circle()
                            .fill(notification.isRead ? Color.clear : Theme.primary)
                            .frame(width: 8, height: 8)
                            .padding(.top, 5)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(notification.title).font(.brandHeadline).foregroundStyle(.primary)
                            Text(notification.body).font(.brandCaption).foregroundStyle(.secondary)
                            Text((notification.sentAt ?? notification.createdAt).formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle("Notifications")
        .task { if let user = session.currentUser { await viewModel.load(userId: user.id) } }
    }
}

#Preview {
    NavigationStack { NotificationCenterView().environment(SessionStore()) }
}
