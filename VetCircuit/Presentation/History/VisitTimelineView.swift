import SwiftUI

/// I2: the full timestamped status timeline — badges alone tell you where a
/// visit is *now*, this shows how it got there and when each step happened.
struct VisitTimelineView: View {
    let visitId: UUID
    @State private var events: [VisitStatusEvent] = []
    @State private var isLoading = true
    /// See `VisitChecklistView` — a swallowed failure rendered as "nothing
    /// recorded yet", which is a different and much more reassuring claim
    /// than the truth.
    @State private var errorMessage: String?

    private let visitRepository = DependencyContainer.shared.visitRepository

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if let errorMessage {
                EmptyStateView(
                    systemImage: "wifi.exclamationmark", title: "Couldn't load the timeline",
                    message: errorMessage, actionTitle: "Try again"
                ) { Task { await load() } }
            } else if events.isEmpty {
                EmptyStateView(systemImage: "list.bullet.clipboard", title: "No timeline yet",
                                message: "This visit's status history will appear here once it starts moving.")
            } else {
                List {
                    ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                        TimelineRow(event: event, isLast: index == events.count - 1)
                    }
                }
                .listStyle(.plain)
                // Pushed from VisitDetailView, which sits under the floating
                // tab bar — without this the last timeline row rests behind it.
                .floatingTabBarInset()
            }
        }
        // The aurora is the app's ground everywhere else; a List that keeps
        // its own opaque system background would read as a different app.
        .scrollContentBackground(.hidden)
        .auroraScreenBackground()
        .navigationTitle("Status timeline")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }
}

private extension VisitTimelineView {
    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            events = try await visitRepository.statusHistory(visitId: visitId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct TimelineRow: View {
    let event: VisitStatusEvent
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Circle().fill(isLast ? Theme.primary : Theme.neutral).frame(width: 10, height: 10)
                if !isLast {
                    Rectangle().fill(Theme.neutral.opacity(0.4)).frame(width: 2).frame(maxHeight: .infinity)
                }
            }
            .frame(width: 10)

            VStack(alignment: .leading, spacing: 4) {
                Text(event.status.displayText).font(.brandHeadline)
                Text(event.occurredAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.brandCaption).foregroundStyle(Theme.textSecondary)
            }
            .padding(.bottom, 12)
        }
        .listRowSeparator(.hidden)
    }
}

#Preview {
    NavigationStack { VisitTimelineView(visitId: UUID()) }
}
