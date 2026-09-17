import Foundation

// The widget's half of the App Group bridge: read only.
//
// This deliberately shares a name with the app target's `WidgetDataBridge`,
// which owns the writing half plus the `summarize(...)` that builds a summary
// out of `Visit`/`Pet`/`Vaccination` — Domain types this extension does not
// compile. Two enums, one per target, each with the half its process needs.
//
// It lives in its own file because `SharedVisitSummary.swift` is now compiled
// into BOTH targets so the payload cannot drift. Leaving this reader in there
// dragged it into the app as well, where it collided with the writer of the
// same name. Only the payload is shared; each side keeps its own accessor.
enum WidgetDataBridge {
    static let appGroupID = "group.com.vetcircuit.app"
    private static let storageKey = "vc.widget.next_visit_summary"

    static func read() -> SharedVisitSummary {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = defaults.data(forKey: storageKey),
              let summary = try? JSONDecoder().decode(SharedVisitSummary.self, from: data)
        else { return .empty }
        return summary
    }
}
