import SwiftUI
import SwiftData

@main
struct VetCircuitApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var session = SessionStore()

    var sharedModelContainer: ModelContainer = {
        let schema = Schema(LocalStoreSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Could not create SwiftData ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .task { await session.bootstrap() }
                .task { await PushNotificationManager.shared.requestAuthorizationAndRegister() }
        }
        .modelContainer(sharedModelContainer)
    }
}

/// Holds the current authenticated user across the app lifecycle.
@MainActor
@Observable
final class SessionStore {
    var currentUser: User? {
        didSet { UserDefaults.standard.set(currentUser?.id.uuidString, forKey: "vc.current_user_id") }
    }
    var isBootstrapping = true

    func bootstrap() async {
        currentUser = await DependencyContainer.shared.authRepository.currentUser()
        isBootstrapping = false
    }

    func signOut() async {
        try? await DependencyContainer.shared.authRepository.signOut()
        currentUser = nil
    }
}

struct RootView: View {
    @Environment(SessionStore.self) private var session

    var body: some View {
        Group {
            if session.isBootstrapping {
                ProgressView()
            } else if session.currentUser != nil {
                MainTabView()
            } else {
                SignInView()
            }
        }
    }
}

struct MainTabView: View {
    var body: some View {
        TabView {
            CircuitsListView()
                .tabItem { Label("Book", systemImage: "calendar.badge.plus") }

            VisitHistoryView()
                .tabItem { Label("Visits", systemImage: "clock.arrow.circlepath") }

            ProfileView()
                .tabItem { Label("Profile", systemImage: "person.circle") }
        }
    }
}
