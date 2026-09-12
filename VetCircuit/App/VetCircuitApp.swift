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
                .tint(Theme.primary)
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
                ZStack {
                    Theme.heroGradient.ignoresSafeArea()
                    PawMascot(size: 88)
                }
            } else if session.currentUser != nil {
                MainTabView()
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            } else {
                SignInView()
                    .transition(.opacity)
            }
        }
        .animation(Theme.springSoft, value: session.currentUser != nil)
        .animation(Theme.easeIn, value: session.isBootstrapping)
    }
}

struct MainTabView: View {
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            CircuitsListView()
                .tabItem { Label("Book", systemImage: selectedTab == 0 ? "calendar.badge.plus" : "calendar") }
                .tag(0)

            VisitHistoryView()
                .tabItem { Label("Visits", systemImage: selectedTab == 1 ? "clock.fill" : "clock.arrow.circlepath") }
                .tag(1)

            ProfileView()
                .tabItem { Label("Profile", systemImage: selectedTab == 2 ? "person.crop.circle.fill" : "person.circle") }
                .tag(2)
        }
    }
}
