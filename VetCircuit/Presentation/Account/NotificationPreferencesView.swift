import SwiftUI

@Observable
@MainActor
final class NotificationPreferencesViewModel {
    var preferences: NotificationPreferences?
    var isLoading = false
    var errorMessage: String?

    private let useCase = DependencyContainer.shared.manageNotificationPreferencesUseCase()

    func load(userId: UUID) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            preferences = try await useCase.load(userId: userId)
        } catch {
            errorMessage = UserFacingError.message(for: error)
        }
    }

    /// Saves on every toggle rather than a separate "Save" button — a
    /// preference screen with unsaved state is the kind of thing users
    /// assume already took effect the moment they tapped it.
    func save() async {
        guard let preferences else { return }
        do {
            self.preferences = try await useCase.save(preferences)
            Haptics.tap()
        } catch {
            Haptics.error()
            errorMessage = UserFacingError.message(for: error)
        }
    }
}

/// O1: per-category notification opt-out, not a single system-level toggle —
/// so a customer can keep booking/chat pushes while turning off promotions.
struct NotificationPreferencesView: View {
    @Environment(SessionStore.self) private var session
    @State private var viewModel = NotificationPreferencesViewModel()

    var body: some View {
        List {
            if let errorMessage = viewModel.errorMessage {
                ErrorBanner(message: errorMessage)
            }

            if let binding = preferencesBinding {
                Section("Visits") {
                    Toggle("Booking updates", isOn: binding.bookingUpdates)
                    Toggle("Chat messages", isOn: binding.chatMessages)
                }

                Section("Health & billing") {
                    Toggle("Vaccination reminders", isOn: binding.vaccinationReminders)
                }

                Section {
                    Toggle("Offers & promotions", isOn: binding.promotions)
                } footer: {
                    Text("Booking updates and chat messages keep you informed about visits already scheduled — we recommend leaving these on.")
                }
            } else if viewModel.isLoading {
                ProgressView()
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

    private var preferencesBinding: Binding<NotificationPreferences>? {
        guard viewModel.preferences != nil else { return nil }
        return Binding(
            get: { viewModel.preferences! },
            set: { newValue in
                viewModel.preferences = newValue
                Task { await viewModel.save() }
            }
        )
    }
}

#Preview {
    NavigationStack { NotificationPreferencesView().environment(SessionStore()) }
}
