import SwiftUI
#if canImport(ActivityKit)
import ActivityKit
import WidgetKit

// I3: the Lock Screen and Dynamic Island faces of the "vet en route" Live
// Activity. `VetEnRouteActivityManager` (main app) drives the state.
//
// The governing idea: a Live Activity is read at a glance, from a locked
// phone, by somebody waiting. So every figure on it must be true *between*
// pushes, not only at the instant one arrives. That is why the ETA is
// rendered from `expectedArrival` with a system text style — the system
// re-renders those continuously, with no push and no wake — rather than from
// the frozen `etaMinutes` integer, which is already wrong a minute later.

@available(iOS 16.1, *)
struct VetEnRouteLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VetEnRouteAttributes.self) { context in
            LockScreenVetEnRouteView(context: context)
                .widgetURL(VetEnRouteLink.url(for: context.attributes.visitId))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(context.attributes.vetName)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } icon: {
                        Image(systemName: "stethoscope")
                            .foregroundStyle(.teal)
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    VetEnRouteETA(state: context.state, style: .compact)
                        .font(.title3.monospacedDigit().bold())
                        .foregroundStyle(.teal)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.status.displayText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } compactLeading: {
                Image(systemName: "stethoscope")
                    .foregroundStyle(.teal)
            } compactTrailing: {
                VetEnRouteETA(state: context.state, style: .compact)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.teal)
            } minimal: {
                // The minimal presentation is what survives when another app
                // is sharing the Island, so it carries the one thing somebody
                // waiting actually wants — the time — and falls back to the
                // glyph only when there is no time to show.
                VetEnRouteMinimal(state: context.state)
            }
            .keylineTint(.teal)
            .widgetURL(VetEnRouteLink.url(for: context.attributes.visitId))
        }
    }
}

/// The deep link both presentations open, matching `DeepLinkParser`'s
/// `vetcircuit://visit/<uuid>` route.
@available(iOS 16.1, *)
enum VetEnRouteLink {
    static func url(for visitId: UUID) -> URL? {
        URL(string: "vetcircuit://visit/\(visitId.uuidString)")
    }
}

/// The ETA, rendered so it stays true without a push.
@available(iOS 16.1, *)
struct VetEnRouteETA: View {
    enum Style { case compact, sentence }

    let state: VetEnRouteAttributes.ContentState
    var style: Style = .sentence

    var body: some View {
        if state.status == .enRoute, let arrival = state.expectedArrival, arrival > .now {
            switch style {
            case .compact:
                // A live countdown the system ticks itself.
                Text(timerInterval: Date.now...arrival, countsDown: true)
                    .multilineTextAlignment(.trailing)
            case .sentence:
                Text("Arriving \(Text(arrival, style: .relative))")
            }
        } else {
            // Arrived, in progress, or no estimate: a stale countdown here
            // would be actively misleading, so say the state instead.
            Text(state.status.displayText)
        }
    }
}

/// The Island's minimal presentation: time if there is one, glyph if not.
@available(iOS 16.1, *)
struct VetEnRouteMinimal: View {
    let state: VetEnRouteAttributes.ContentState

    var body: some View {
        if state.status == .enRoute, let arrival = state.expectedArrival, arrival > .now {
            Text(timerInterval: Date.now...arrival, countsDown: true)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.teal)
        } else {
            Image(systemName: "stethoscope")
                .foregroundStyle(.teal)
        }
    }
}

/// The Lock Screen / banner presentation.
@available(iOS 16.1, *)
struct LockScreenVetEnRouteView: View {
    let context: ActivityViewContext<VetEnRouteAttributes>

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "stethoscope")
                .font(.title3)
                .foregroundStyle(.teal)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(context.attributes.vetName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)

                VetEnRouteETA(state: context.state, style: .sentence)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Text(context.state.status.displayText)
                .font(.caption2.bold())
                .foregroundStyle(.teal)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
        .padding()
        .activityBackgroundTint(.black.opacity(0.35))
        .activitySystemActionForegroundColor(.teal)
    }
}
#endif
