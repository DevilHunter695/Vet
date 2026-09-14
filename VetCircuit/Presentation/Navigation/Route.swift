import Foundation

// MARK: - N7: the shared typed route the plan's Router pushes.
//
// Deliberately small: it only names destinations that (a) a deep link needs
// to reach and (b) an existing tab can safely push without restructuring its
// whole navigation model. See `Router` (App/Router.swift) for how a
// `DeepLink` (Domain/DeepLinkParser.swift) turns into one of these plus a
// tab switch, and VisitHistoryView/ProfileView for where each case is
// consumed via `.navigationDestination(for: Route.self)`.
enum Route: Hashable {
    /// Push a specific visit's detail screen (Visits tab). Resolved against
    /// the tab's already-loaded `[Visit]` — see the doc comment on
    /// `VisitHistoryView`'s `navigationDestination`.
    case visitDetail(UUID)
    /// Push straight into a specific visit's chat thread (Visits tab) —
    /// the destination plan §6.1 flagged as unreachable from outside before
    /// this Router existed. Only needs the id: `ChatView` takes `visitId`.
    case chat(visitId: UUID)
    /// Push the household screen (Profile tab). No associated data — the
    /// view loads its own household for the current user.
    case household
}
