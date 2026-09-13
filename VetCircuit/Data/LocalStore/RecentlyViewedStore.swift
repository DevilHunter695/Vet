import Foundation

// MARK: - C9 recently viewed (plan §3 C9) — "highest-converting element in
// repeat marketplaces". This is per-device browsing history, not synced
// server state, so plain `UserDefaults` fits better than the SwiftData
// `LocalStore` (which mirrors *server-authoritative* records like visits/chat
// for offline reading — see Data/LocalStore/LocalModels.swift) — there is no
// server row to reconcile against here.
@MainActor
final class RecentlyViewedStore {
    static let shared = RecentlyViewedStore()

    private let defaultsKey = "vc.recently_viewed_circuit_ids"
    private let maxEntries = 10
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Most-recent-first list of circuit ids, capped at `maxEntries`.
    private(set) var circuitIds: [UUID] {
        get {
            (defaults.array(forKey: defaultsKey) as? [String])?.compactMap(UUID.init) ?? []
        }
        set {
            defaults.set(newValue.map(\.uuidString), forKey: defaultsKey)
        }
    }

    func recordView(circuitId: UUID) {
        var ids = circuitIds
        ids.removeAll { $0 == circuitId }
        ids.insert(circuitId, at: 0)
        if ids.count > maxEntries { ids = Array(ids.prefix(maxEntries)) }
        circuitIds = ids
    }

    /// Resolves the stored ids against a currently-loaded circuit list —
    /// callers already have `circuits` in memory (from `GetCircuitsUseCase`),
    /// so this stays a pure lookup rather than its own repository round trip.
    func recentCircuits(from circuits: [Circuit], limit: Int = 5) -> [Circuit] {
        let byId = Dictionary(uniqueKeysWithValues: circuits.map { ($0.id, $0) })
        return circuitIds.compactMap { byId[$0] }.prefix(limit).map { $0 }
    }
}
