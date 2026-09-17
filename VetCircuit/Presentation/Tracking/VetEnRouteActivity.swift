import Foundation
#if canImport(ActivityKit)
@preconcurrency import ActivityKit
#endif

// MARK: - I3 Live Activity / Dynamic Island for "vet en route" (plan §3 I3,
// P1 — "iOS-native differentiator, huge perceived-quality win").
//
// VetCircuitWidget/VetEnRouteLiveActivity.swift supplies the Lock Screen and
// Dynamic Island views; this file owns starting, updating and ending the
// Activity from the app side.
#if canImport(ActivityKit)
// `VetEnRouteAttributes` itself lives in
// VetCircuitWidget/VetEnRouteAttributes.swift and is compiled into BOTH
// targets (see project.yml), exactly like `SharedVisitSummary`.
//
// It used to be declared twice, and the comment here cited the other
// duplicate as precedent for doing so. ActivityKit only requires the two
// types to be structurally identical Codable layouts — which is precisely
// the kind of requirement that holds until somebody edits one side. The
// surest way to keep two definitions identical is to have one.

/// Thin wrapper so call sites (LiveTrackingViewModel) don't touch
/// `Activity<T>` directly — keeps ActivityKit usage in one place, and gives
/// the eventual widget-extension work one obvious file to look at.
@available(iOS 16.1, *)
@MainActor
enum VetEnRouteActivityManager {
    private static var currentActivity: Activity<VetEnRouteAttributes>?

    /// Maps the real domain status to the widget-safe mirror — nil for any
    /// status this Activity has no business representing (it only exists
    /// while a visit is actively en route/arrived/in progress).
    private static func liveStatus(for status: Visit.VisitStatus) -> VetEnRouteAttributes.LiveStatus? {
        switch status {
        case .enRoute: return .enRoute
        case .arrived: return .arrived
        case .inProgress: return .inProgress
        default: return nil
        }
    }

    /// Turns "N minutes away" into the clock time that means, so the widget
    /// can render a figure that keeps itself honest between pushes.
    private static func arrival(in minutes: Int?, from now: Date = .now) -> Date? {
        guard let minutes, minutes >= 0 else { return nil }
        return now.addingTimeInterval(TimeInterval(minutes * 60))
    }

    /// When to let the system mark the Activity stale.
    ///
    /// Without this the Lock Screen shows the last known ETA forever, with
    /// nothing to say it stopped being updated — which is worse than showing
    /// nothing, because it looks current. A little past the expected arrival
    /// is the point after which this Activity is no longer telling the truth.
    private static func staleDate(for arrival: Date?, from now: Date = .now) -> Date {
        (arrival ?? now).addingTimeInterval(10 * 60)
    }

    static func start(visitId: UUID, vetName: String, etaMinutes: Int?, status: Visit.VisitStatus) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, let liveStatus = liveStatus(for: status) else { return }
        // A visit can only have one live tracking session at a time; ending
        // any stale activity first avoids the Island showing two vets.
        end()
        let attributes = VetEnRouteAttributes(visitId: visitId, vetName: vetName)
        let expected = arrival(in: etaMinutes)
        let state = VetEnRouteAttributes.ContentState(
            etaMinutes: etaMinutes, expectedArrival: expected, status: liveStatus
        )
        do {
            currentActivity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: staleDate(for: expected))
            )
        } catch {
            // Live Activities are additive reassurance (like LiveTrackingView's
            // map, per its own doc comment) — a failure to start one must
            // never block or crash the actual tracking flow.
        }
    }

    static func update(etaMinutes: Int?, status: Visit.VisitStatus) {
        guard let currentActivity, let liveStatus = liveStatus(for: status) else { return }
        let expected = arrival(in: etaMinutes)
        let state = VetEnRouteAttributes.ContentState(
            etaMinutes: etaMinutes, expectedArrival: expected, status: liveStatus
        )
        let stale = staleDate(for: expected)
        Task { await currentActivity.update(.init(state: state, staleDate: stale)) }
    }

    static func end() {
        guard let activity = currentActivity else { return }
        currentActivity = nil
        Task { @MainActor [activity] in await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
#endif

