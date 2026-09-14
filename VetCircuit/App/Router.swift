import SwiftUI

// MARK: - N7: the shared Router the plan's §6.1 gap called out as missing.
//
// Holds the selected tab plus one `NavigationPath` per tab that has been
// converted to push typed `Route`s (see `Route.swift`). A deep link now
// switches tabs *and* pushes the specific nested screen in one step, instead
// of only landing on the right tab (see `handle(_:)` and how
// `VetCircuitApp.onOpenURL` calls it).
//
// Honest scope: only the Visits and Profile tabs were converted — see the
// doc comment on `handle(_:)` for why the Book tab keeps its existing
// `PendingDeepLinkStore`-based resolution instead of also moving onto this
// Router.
@MainActor
@Observable
final class Router {
    enum Tab: Int {
        case book = 0
        case visits = 1
        case profile = 2
    }

    var selectedTab: Int = Tab.book.rawValue
    var visitsPath = NavigationPath()
    var profilePath = NavigationPath()

    /// Switches tab and, where a converted tab owns the target screen,
    /// pushes the specific `Route` for it — resetting that tab's path first
    /// so a deep link always lands on a clean stack rather than piling onto
    /// whatever the user happened to be looking at.
    ///
    /// `.book` and `.unknown` are deliberately no-ops here: `CircuitsListView`
    /// (Book tab) still resolves `.book(circuitId:)` itself against its own
    /// loaded `[Circuit]` via `PendingDeepLinkStore`, exactly as before this
    /// Router existed. Converting that tab too would mean giving its
    /// `Circuit`-keyed `navigationDestination` and search-result/rebook
    /// sheet navigation a `Route` case as well — a larger change than this
    /// pass takes on; see N7's plan row for the honest accounting.
    func handle(_ deepLink: DeepLink) {
        switch deepLink {
        case .visit(let id):
            selectedTab = Tab.visits.rawValue
            visitsPath = NavigationPath()
            visitsPath.append(Route.visitDetail(id))
        case .chat(let visitId):
            selectedTab = Tab.visits.rawValue
            visitsPath = NavigationPath()
            visitsPath.append(Route.chat(visitId: visitId))
        case .household:
            selectedTab = Tab.profile.rawValue
            profilePath = NavigationPath()
            profilePath.append(Route.household)
        case .book, .unknown:
            break
        }
    }
}
