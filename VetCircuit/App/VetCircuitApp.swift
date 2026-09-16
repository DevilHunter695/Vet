import SwiftUI
import SwiftData

/// User-facing override of the system appearance. Kept as a plain string in
/// `AppStorage` (not an enum) so it round-trips through `UserDefaults`
/// directly; `colorScheme` is what actually feeds `.preferredColorScheme`.
enum AppearanceOption: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var systemImage: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// N7: holds a deep link until the screen that can act on it is on screen.
/// See the doc comment on `DeepLink` (Domain/DeepLinkParser.swift) for why
/// this exists instead of a real Router: MainTabView runs three independent
/// `NavigationStack`s today, so there is no single navigation path to push
/// onto from `.onOpenURL` — each tab instead reads and clears this store
/// when it can act on the pending link.
@MainActor
@Observable
final class PendingDeepLinkStore {
    var pending: DeepLink?

    func handle(_ url: URL) {
        let link = DeepLinkParser.parse(url)
        guard link != .unknown else { return }
        pending = link
    }

    /// Call once a tab has acted on `pending` so the same link doesn't
    /// re-trigger navigation on the next appearance.
    func consume() -> DeepLink? {
        defer { pending = nil }
        return pending
    }
}

@main
struct VetCircuitApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var session = SessionStore()
    @State private var pendingDeepLink = PendingDeepLinkStore()
    // N7: the shared Router — see App/Router.swift for exactly which tabs'
    // NavigationStacks it drives and which deep links it can push onto them.
    @State private var router = Router()
    @AppStorage("vc.appearance") private var appearanceRaw: String = AppearanceOption.system.rawValue

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
                .environment(pendingDeepLink)
                .environment(router)
                .tint(Theme.primary)
                .preferredColorScheme((AppearanceOption(rawValue: appearanceRaw) ?? .system).colorScheme)
                .task { await session.bootstrap() }
                .task { await PushNotificationManager.shared.requestAuthorizationAndRegister() }
                // N7: both the custom scheme and (once configured in the
                // Associated Domains entitlement) a universal link land
                // here. `pendingDeepLink` still carries `.book`, which
                // CircuitsListView resolves itself against its own loaded
                // circuits (see Router's doc comment for why); `router`
                // now also switches tab *and* pushes the specific Route for
                // `.visit`/`.chat`/`.household`.
                .onOpenURL { url in
                    pendingDeepLink.handle(url)
                    router.handle(DeepLinkParser.parse(url))
                }
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
    @Environment(\.scenePhase) private var scenePhase
    @State private var appConfigGate: CheckAppConfigUseCase.Gate?
    @State private var biometricLock = BiometricLockGateModel()

    private let checkAppConfigUseCase = DependencyContainer.shared.checkAppConfigUseCase()

    /// O7: the app's own declared version — compared against the server's
    /// `minSupportedVersion`, never hardcoded, so this keeps working as the
    /// bundle's version string is bumped release to release.
    private var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    var body: some View {
        Group {
            if case .maintenance(let message) = appConfigGate {
                ForceUpdateView(mode: .maintenance(message: message))
                    .transition(.opacity)
            } else if case .forceUpgrade(let minVersion) = appConfigGate {
                ForceUpdateView(mode: .forceUpgrade(minVersion: minVersion))
                    .transition(.opacity)
            } else if session.isBootstrapping {
                ZStack {
                    Theme.heroGradient.ignoresSafeArea()
                    PawMascot(size: 88)
                }
            } else if let user = session.currentUser, user.isLockedOut {
                // A11: checked before the biometric gate and before the tab
                // bar — a blocked/deactivated user should never even reach
                // the "unlock with Face ID" screen for content they can't use.
                AccountBlockedView(status: user.accountStatus) {
                    Task { await session.signOut() }
                }
                .transition(.opacity)
            } else if session.currentUser != nil && BiometricLockSetting.isEnabled && !biometricLock.isUnlocked {
                // A10: local device gate, evaluated per cold launch and per
                // foreground return (below) — sits above MainTabView exactly
                // like the maintenance/force-upgrade gate above it.
                BiometricLockGateView(model: biometricLock)
                    .transition(.opacity)
            } else if session.currentUser != nil {
                MainTabView()
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            } else {
                SignInView()
                    .transition(.opacity)
            }
        }
        .animation(Theme.springSoft, value: session.currentUser != nil)
        .animation(Theme.crossFade, value: session.isBootstrapping)
        // O7/O8: fetched once at launch, before we even know whether there's a
        // session — a killed binary must be gated for signed-out users too.
        .task { appConfigGate = await checkAppConfigUseCase.execute(currentVersion: currentAppVersion) }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background { biometricLock.lock() }
        }
    }
}

struct MainTabView: View {
    @Environment(PendingDeepLinkStore.self) private var pendingDeepLink
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.selectedTab) {
            CircuitsListView()
                .tabItem { Label("Book", systemImage: router.selectedTab == 0 ? "calendar.badge.plus" : "calendar") }
                .tag(0)

            VisitHistoryView()
                .tabItem { Label("Visits", systemImage: router.selectedTab == 1 ? "clock.fill" : "clock.arrow.circlepath") }
                .tag(1)

            ProfileView()
                .tabItem { Label("Profile", systemImage: router.selectedTab == 2 ? "person.crop.circle.fill" : "person.circle") }
                .tag(2)
        }
        .onChange(of: router.selectedTab) { _, _ in Haptics.selection() }
        // N7: `.book` is the one DeepLink case Router.handle(_:) doesn't act
        // on — CircuitsListView resolves it itself against its own loaded
        // circuits (unchanged from before this Router existed). Every other
        // case (`.visit`, `.chat`, `.household`) now switches tab *and*
        // pushes its Route via `router.handle(_:)` in `.onOpenURL`, so
        // nothing else needs handling here.
        .onChange(of: pendingDeepLink.pending) { _, link in
            if case .book = link { router.selectedTab = 0 }
        }
    }
}
