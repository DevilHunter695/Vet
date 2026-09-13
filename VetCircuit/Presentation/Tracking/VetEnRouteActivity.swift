import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

// MARK: - I3 Live Activity / Dynamic Island for "vet en route" (plan §3 I3,
// P1 — "iOS-native differentiator, huge perceived-quality win").
//
// KNOWN GAP, flagged per the task brief rather than guessed at: a Live
// Activity's Dynamic Island/Lock Screen UI is rendered by a **Widget
// Extension target**, which does not exist in this project — `project.yml`
// (repo root) defines a single `VetCircuit` application target and a
// `VetCircuitTests` bundle, nothing else. Adding a `widget` target to
// XcodeGen's config is a real Xcode-project change (a new target, its own
// Info.plist/entitlements, an App Group for the widget-extension/main-app
// hand-off) that risks silently breaking the existing single-target build if
// guessed at without being able to run `xcodegen generate` + a real build
// here. Per the brief: "getting this half right with a clear flag beats a
// confident guess that silently breaks CI."
//
// What *is* committed and safe: the `ActivityAttributes` contract and the
// call site that starts/updates/ends the Activity from the main app target
// (ActivityKit's `Activity<T>.request` works from the app target without a
// widget extension present — it just has nothing to render on the Lock
// Screen/Island until the extension exists). Once a widget extension target
// is added in Xcode (or a maintainer is confident enough in the XcodeGen
// diff to add it directly), it imports this same `VetEnRouteAttributes` type
// (shared via a target membership on this file, or a small shared framework)
// and supplies the actual `ActivityConfiguration` SwiftUI views.
#if canImport(ActivityKit)
@available(iOS 16.1, *)
struct VetEnRouteAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var etaMinutes: Int?
        var status: Visit.VisitStatus
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

    static func start(visitId: UUID, vetName: String, etaMinutes: Int?, status: Visit.VisitStatus) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // A visit can only have one live tracking session at a time; ending
        // any stale activity first avoids the Island showing two vets.
        end()
        let attributes = VetEnRouteAttributes(visitId: visitId, vetName: vetName)
        let state = VetEnRouteAttributes.ContentState(etaMinutes: etaMinutes, status: status)
        do {
            currentActivity = try Activity.request(attributes: attributes, content: .init(state: state, staleDate: nil))
        } catch {
            // Live Activities are additive reassurance (like LiveTrackingView's
            // map, per its own doc comment) — a failure to start one must
            // never block or crash the actual tracking flow.
        }
    }

    static func update(etaMinutes: Int?, status: Visit.VisitStatus) {
        guard let currentActivity else { return }
        let state = VetEnRouteAttributes.ContentState(etaMinutes: etaMinutes, status: status)
        Task { await currentActivity.update(.init(state: state, staleDate: nil)) }
    }

    static func end() {
        guard let activity = currentActivity else { return }
        currentActivity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
#endif
