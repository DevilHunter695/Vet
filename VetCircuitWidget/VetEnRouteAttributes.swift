import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

// I3: Live Activity contract shared between the main app (which starts/
// updates/ends the Activity — see VetCircuit/Presentation/Tracking/
// VetEnRouteActivity.swift) and this widget extension (which renders it on
// the Lock Screen/Dynamic Island). There is no shared framework target in
// this project, so this single file is compiled into *both* targets
// (VetCircuit's project.yml sources list it explicitly for the app target,
// and the whole VetCircuitWidget folder for the extension) — ActivityKit
// only needs the two compiled types to be structurally identical Codable
// layouts, which duplicate-compiling the same source guarantees.
#if canImport(ActivityKit)
@available(iOS 16.1, *)
struct VetEnRouteAttributes: ActivityAttributes {
    /// A small, self-contained mirror of the handful of `Visit.VisitStatus`
    /// cases relevant to a Live Activity — deliberately not the real
    /// `Visit.VisitStatus` enum, since that type lives in the main app
    /// target's Domain layer, which this widget extension doesn't compile.
    /// The call site (`VetEnRouteActivityManager`) maps from the real enum.
    enum LiveStatus: String, Codable, Hashable {
        case enRoute, arrived, inProgress

        var displayText: String {
            switch self {
            case .enRoute: return "Vet en route"
            case .arrived: return "Vet has arrived"
            case .inProgress: return "Visit in progress"
            }
        }
    }

    struct ContentState: Codable, Hashable {
        /// Kept for compatibility with any Activity already running when the
        /// app updates — a live Activity's state is decoded by the *new*
        /// binary, so removing a field would break one mid-flight.
        var etaMinutes: Int?
        /// When the vet is actually expected, rather than how many minutes
        /// away they were at the moment of the last push.
        ///
        /// This is the difference between a Live Activity that stays true and
        /// one that lies. `etaMinutes` is frozen the instant it is sent: the
        /// Island shows "5 min" and keeps showing "5 min" until the next
        /// push, so a gap in updates leaves a confidently wrong number on the
        /// Lock Screen. A date lets the view render `Text(_, style:)`, which
        /// the system re-renders continuously with no push at all.
        var expectedArrival: Date?
        var status: LiveStatus

        init(etaMinutes: Int? = nil, expectedArrival: Date? = nil, status: LiveStatus) {
            self.etaMinutes = etaMinutes
            self.expectedArrival = expectedArrival
            self.status = status
        }
    }

    var visitId: UUID
    var vetName: String
}
#endif
