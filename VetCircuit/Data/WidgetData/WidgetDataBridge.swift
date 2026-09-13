import Foundation

/// N6: the payload the Home Screen widget reads. Kept deliberately tiny and
/// display-ready (pre-formatted strings, not raw models) so the widget
/// extension never needs to know about `Visit`, `Vaccination`, or any
/// repository/use-case type from the main app — it only decodes this struct.
///
/// The widget extension can't share `DependencyContainer` (it's a separate
/// process/target with no access to the main app's in-memory mock/live
/// repositories), so this is the whole contract between the two targets:
/// the main app is the only writer, the widget is a read-only consumer via
/// the shared App Group container.
struct SharedVisitSummary: Codable, Equatable {
    enum Kind: String, Codable {
        case upcomingVisit
        case vaccinationDue
        case none
    }

    var kind: Kind
    var petName: String?
    var vetName: String?
    /// For `.upcomingVisit`: the visit's scheduled time. For
    /// `.vaccinationDue`: the vaccine's next-due date.
    var date: Date?
    /// e.g. the circuit's area/vet name, shown as a subtitle for a visit.
    var subtitle: String?
    /// For `.vaccinationDue`, the vaccine name (e.g. "Rabies").
    var vaccineName: String?
    var generatedAt: Date

    static let empty = SharedVisitSummary(kind: .none, petName: nil, vetName: nil, date: nil, subtitle: nil, vaccineName: nil, generatedAt: .now)
}

/// Writes `SharedVisitSummary` to the shared App Group `UserDefaults` suite
/// so `VetCircuitWidget`'s `TimelineProvider` can read it. This is the only
/// side of the bridge the main app target owns; nothing here ever runs in
/// the widget process.
enum WidgetDataBridge {
    /// Must match `com.apple.security.application-groups` in both targets'
    /// entitlements (see project.yml).
    static let appGroupID = "group.com.vetcircuit.app"
    private static let storageKey = "vc.widget.next_visit_summary"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    /// Call whenever the relevant screen loads/refreshes (visit history,
    /// the pet detail/vaccination screen). Best-effort: a signing/App Group
    /// misconfiguration just means the widget shows its placeholder state,
    /// never a crash for the main app.
    static func write(_ summary: SharedVisitSummary) {
        guard let defaults, let data = try? JSONEncoder().encode(summary) else { return }
        defaults.set(data, forKey: storageKey)
        // Reloading the widget's timeline (WidgetKit's own API) is done by
        // the call site, which already imports WidgetKit for its own needs —
        // kept out of this file so it stays usable from non-UI code/tests.
    }

    /// Reads the last-written summary. Used by the widget extension's
    /// `TimelineProvider`; also handy for debugging from the main app.
    static func read() -> SharedVisitSummary {
        guard let defaults,
              let data = defaults.data(forKey: storageKey),
              let summary = try? JSONDecoder().decode(SharedVisitSummary.self, from: data)
        else { return .empty }
        return summary
    }

    /// Picks the next upcoming, non-terminal visit if there is one, else the
    /// soonest-due vaccination across the user's pets, else `.none`.
    static func summarize(visits: [Visit], pets: [Pet], vaccinationsByPet: [UUID: [Vaccination]], now: Date = .now) -> SharedVisitSummary {
        let nonTerminal: Set<Visit.VisitStatus> = [.requested, .confirmed, .assigned, .enRoute, .arrived, .inProgress]
        if let nextVisit = visits
            .filter({ nonTerminal.contains($0.status) && $0.scheduledAt >= now })
            .sorted(by: { $0.scheduledAt < $1.scheduledAt })
            .first {
            let pet = pets.first { $0.id == nextVisit.petId }
            return SharedVisitSummary(
                kind: .upcomingVisit,
                petName: pet?.name,
                vetName: nil,
                date: nextVisit.scheduledAt,
                subtitle: nextVisit.status.displayText,
                vaccineName: nil,
                generatedAt: now
            )
        }

        let dueSoonest = vaccinationsByPet
            .flatMap { petId, vaccinations in vaccinations.map { (petId, $0) } }
            .sorted { $0.1.nextDueAt < $1.1.nextDueAt }
            .first

        if let (petId, vaccination) = dueSoonest {
            let pet = pets.first { $0.id == petId }
            return SharedVisitSummary(
                kind: .vaccinationDue,
                petName: pet?.name,
                vetName: nil,
                date: vaccination.nextDueAt,
                subtitle: nil,
                vaccineName: vaccination.vaccineName,
                generatedAt: now
            )
        }

        return SharedVisitSummary(kind: .none, petName: nil, vetName: nil, date: nil, subtitle: nil, vaccineName: nil, generatedAt: now)
    }
}
