import WidgetKit
import SwiftUI
#if canImport(ActivityKit)
import ActivityKit

/// I3: the actual Lock Screen/Dynamic Island rendering for the "vet en
/// route" Live Activity — the piece that was structurally impossible
/// without a widget extension target, which now exists (see N6). The
/// content itself comes from `VetEnRouteAttributes` (VetEnRouteAttributes.swift,
/// compiled into both this target and the main app).
@available(iOS 16.1, *)
struct VetEnRouteLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VetEnRouteAttributes.self) { context in
            // Lock Screen / banner presentation.
            HStack(spacing: 12) {
                Image(systemName: "stethoscope")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.vetName).font(.headline)
                    Text(context.state.status.displayText).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if let etaMinutes = context.state.etaMinutes {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(etaMinutes) min").font(.headline)
                        Text("ETA").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
            .activityBackgroundTint(Color(.systemBackground))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "stethoscope")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let etaMinutes = context.state.etaMinutes {
                        Text("\(etaMinutes) min")
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("\(context.attributes.vetName) · \(context.state.status.displayText)")
                        .font(.caption)
                }
            } compactLeading: {
                Image(systemName: "stethoscope")
            } compactTrailing: {
                if let etaMinutes = context.state.etaMinutes {
                    Text("\(etaMinutes)m")
                }
            } minimal: {
                Image(systemName: "stethoscope")
            }
        }
    }
}
#endif
