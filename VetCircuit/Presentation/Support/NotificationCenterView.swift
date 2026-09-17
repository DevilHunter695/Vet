import SwiftUI

/// J7: the in-app notification *history* — distinct from
/// `NotificationPreferencesView`'s per-channel opt-in/out toggles.
@Observable
@MainActor
final class NotificationCenterViewModel {
    var notifications: [AppNotification] = []
    var errorMessage: String?

    private let getNotificationCenterUseCase = DependencyContainer.shared.getNotificationCenterUseCase()

    /// False until the first load finishes.
    ///
    /// Without it the empty state rendered instantly on every open, so on a
    /// slow connection the first thing anybody saw was the app stating as
    /// fact something it had not yet checked.
    private(set) var hasLoaded = false

    func load(userId: UUID) async {
        defer { hasLoaded = true }
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
            if viewModel.hasLoaded && viewModel.notifications.isEmpty && viewModel.errorMessage == nil {
                // No action here: there is nothing to create, so the useful
                // next step is choosing what gets sent at all.
                EmptyStateView(
                    systemImage: "bell",
                    title: "Nothing to catch up on",
                    message: "Booking confirmations, vet-on-the-way alerts and visit summaries will collect here."
                )
                .listRowBackground(Color.clear)
            }
            ForEach(viewModel.notifications) { notification in
                Button {
                    Task { await viewModel.markRead(notification) }
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Circle()
                            .fill(notification.isRead ? Color.clear : Theme.primary)
                            .frame(width: 8, height: 8)
                            .padding(.top, 6)
                            .accessibilityHidden(true)
                            .animation(.easeOut(duration: 0.2), value: notification.isRead)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(notification.title).font(.brandHeadline).foregroundStyle(.primary)
                            Text(notification.body).font(.brandCaption).foregroundStyle(Theme.textSecondary)
                            Text((notification.sentAt ?? notification.createdAt).formatted(date: .abbreviated, time: .shortened))
                                .font(.brandCaption).foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityLabel((notification.isRead ? "" : "Unread. ") + notification.title + ". " + notification.body)
                .accessibilityHint(notification.isRead ? "" : "Double tap to mark as read")
            }
        }
        // The aurora is the app's ground everywhere else; a List that keeps
        // its own opaque system background would read as a different app.
        .scrollContentBackground(.hidden)
        .auroraScreenBackground()
        .floatingTabBarInset()
        .navigationTitle("Notifications")
        .task { if let user = session.currentUser { await viewModel.load(userId: user.id) } }
    }
}

#Preview {
    NavigationStack { NotificationCenterView().environment(SessionStore()) }
}
