import WidgetKit
import SwiftUI

/// N6: the entry the timeline hands to the widget's SwiftUI view. It only
/// carries the already-formatted `SharedVisitSummary` — this target never
/// touches `DependencyContainer`, a repository, or a use-case; those live in
/// the main app, which is the only writer of the shared data (see
/// `VetCircuit/Data/WidgetData/WidgetDataBridge.swift`).
struct NextVisitEntry: TimelineEntry {
    let date: Date
    let summary: SharedVisitSummary
}

/// Reads the shared App Group storage the main app wrote to and turns it
/// into a timeline. There is no live push from the app to the widget process
/// today — that's a reasonable, documented simplification (see N6's plan
/// note): the widget refreshes itself on the schedule below, and separately
/// whenever `WidgetCenter.reloadTimelines` is called from the main app
/// (VisitHistoryView, on every load).
struct NextVisitTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> NextVisitEntry {
        NextVisitEntry(date: .now, summary: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (NextVisitEntry) -> Void) {
        completion(NextVisitEntry(date: .now, summary: context.isPreview ? .placeholder : WidgetDataBridge.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NextVisitEntry>) -> Void) {
        let summary = WidgetDataBridge.read()
        let entry = NextVisitEntry(date: .now, summary: summary)
        // Re-check every 30 minutes so a visit that has since passed (or a
        // vaccination that's now overdue) doesn't sit stale on the Home
        // Screen for hours between app opens.
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 30, to: .now) ?? .now.addingTimeInterval(1800)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }
}

private extension SharedVisitSummary {
    static let placeholder = SharedVisitSummary(
        kind: .upcomingVisit, petName: "Bruno", vetName: nil, date: .now.addingTimeInterval(3600 * 20),
        subtitle: "Confirmed", vaccineName: nil, generatedAt: .now
    )
}

struct NextVisitWidgetView: View {
    let entry: NextVisitEntry

    var body: some View {
        switch entry.summary.kind {
        case .upcomingVisit:
            VStack(alignment: .leading, spacing: 4) {
                Label("Next visit", systemImage: "calendar")
                    .font(.caption).foregroundStyle(.secondary)
                Text(entry.summary.petName ?? "Your pet")
                    .font(.headline)
                if let date = entry.summary.date {
                    Text(date, style: .date) + Text(" · ") + Text(date, style: .time)
                }
                if let subtitle = entry.summary.subtitle {
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()

        case .vaccinationDue:
            VStack(alignment: .leading, spacing: 4) {
                Label("Vaccination due", systemImage: "syringe")
                    .font(.caption).foregroundStyle(.secondary)
                Text(entry.summary.vaccineName.map { "\(entry.summary.petName ?? "Your pet") · \($0)" } ?? entry.summary.petName ?? "Your pet")
                    .font(.headline)
                if let date = entry.summary.date {
                    Text(date, style: .date)
                }
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()

        case .none:
            VStack(alignment: .leading, spacing: 4) {
                Text("No upcoming visits")
                    .font(.headline)
                Text("Book a vet, elder care, or physio visit to see it here.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }
}

struct NextVisitWidget: Widget {
    let kind: String = "VetCircuitNextVisitWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NextVisitTimelineProvider()) { entry in
            NextVisitWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Next Visit")
        .description("Shows your next upcoming visit, or the next vaccination due.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

#Preview(as: .systemSmall) {
    NextVisitWidget()
} timeline: {
    NextVisitEntry(date: .now, summary: SharedVisitSummary(kind: .upcomingVisit, petName: "Bruno", vetName: nil, date: .now.addingTimeInterval(3600 * 20), subtitle: "Confirmed", vaccineName: nil, generatedAt: .now))
    NextVisitEntry(date: .now, summary: SharedVisitSummary(kind: .vaccinationDue, petName: "Milo", vetName: nil, date: .now.addingTimeInterval(3600 * 24 * 5), subtitle: nil, vaccineName: "Rabies", generatedAt: .now))
    NextVisitEntry(date: .now, summary: .empty)
}
