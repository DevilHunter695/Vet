import Foundation

/// The one visit that is actually happening, held at app level.
///
/// The tab bar's accessory needs this from every screen, and every screen's
/// own view model only knows about its own data — `VisitHistoryViewModel`
/// computes an `activeVisit`, but that is gone the moment you leave the
/// Visits tab, which is precisely when the accessory earns its place.
///
/// Deliberately narrow: it answers "is a vet on the way right now, and who",
/// and nothing else. It is not a second source of truth for visit data — the
/// screens keep loading their own — it is a small, cheap projection for
/// chrome that has to outlive any one screen.
@MainActor
@Observable
final class LiveVisitStore {
    private(set) var liveVisit: Visit?

    private let getVisitHistoryUseCase = DependencyContainer.shared.getVisitHistoryUseCase()

    /// `isLive` is en route, arrived or in progress — the window in which a
    /// pet owner genuinely wants this pinned in front of them. An upcoming
    /// visit next Tuesday is not that, and putting it here would leave the
    /// accessory permanently on screen, which is how chrome stops being read.
    func refresh(userId: UUID?) async {
        guard let userId else {
            liveVisit = nil
            return
        }
        guard let visits = try? await getVisitHistoryUseCase.execute(userId: userId) else { return }
        liveVisit = visits.filter { $0.status.isLive }.min { $0.scheduledAt < $1.scheduledAt }
    }

    func clear() {
        liveVisit = nil
    }
}
