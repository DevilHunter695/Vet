import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

// MARK: - I3 Live Activity / Dynamic Island for "vet en route" (plan §3 I3,
// P1 — "iOS-native differentiator, huge perceived-quality win").
//
// `VetEnRouteAttributes` is defined identically here and in
// VetCircuitWidget/VetEnRouteAttributes.swift — there's no shared-framework
// target in this project, so (mirroring `SharedVisitSummary`'s existing
// app/widget duplication for N6) each target keeps its own copy of the same
// Codable layout, which is all ActivityKit needs to agree on the wire
// format. VetCircuitWidget/VetEnRouteLiveActivity.swift supplies the actual
// Lock Screen/Dynamic Island `ActivityConfiguration` views, now that a
// widget extension target exists (it didn't when this row was last audited).
#if canImport(ActivityKit)
@available(iOS 16.1, *)
struct VetEnRouteAttributes: ActivityAttributes {
    /// Mirrors `Visit.VisitStatus`'s en-route-adjacent cases only — kept
    /// separate rather than reusing that enum directly since the widget
    /// extension's copy of this file can't import the main app's Domain layer.
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
        var etaMinutes: Int?
        var status: LiveStatus
    }

    var visitId: UUID
    var vetName: String
}

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

    static func start(visitId: UUID, vetName: String, etaMinutes: Int?, status: Visit.VisitStatus) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, let liveStatus = liveStatus(for: status) else { return }
        // A visit can only have one live tracking session at a time; ending
        // any stale activity first avoids the Island showing two vets.
        end()
        let attributes = VetEnRouteAttributes(visitId: visitId, vetName: vetName)
        let state = VetEnRouteAttributes.ContentState(etaMinutes: etaMinutes, status: liveStatus)
        do {
            currentActivity = try Activity.request(attributes: attributes, content: .init(state: state, staleDate: nil))
        } catch {
            // Live Activities are additive reassurance (like LiveTrackingView's
            // map, per its own doc comment) — a failure to start one must
            // never block or crash the actual tracking flow.
        }
    }

    static func update(etaMinutes: Int?, status: Visit.VisitStatus) {
        guard let currentActivity, let liveStatus = liveStatus(for: status) else { return }
        let state = VetEnRouteAttributes.ContentState(etaMinutes: etaMinutes, status: liveStatus)
        Task { await currentActivity.update(.init(state: state, staleDate: nil)) }
    }

    static func end() {
        guard let activity = currentActivity else { return }
        currentActivity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
#endif
