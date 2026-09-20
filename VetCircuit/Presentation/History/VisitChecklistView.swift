import SwiftUI

/// I7: the vet's in-visit checklist, once it becomes the customer's record.
/// Read-only end to end — filling it out is a vet-side action this app has
/// no surface for (see `VisitChecklistRepository`'s doc comment).
struct VisitChecklistView: View {
    let visitId: UUID
    @State private var items: [VisitChecklistItem] = []
    @State private var isLoading = true
    /// Nil when the load succeeded. Without this a failure was written into
    /// `items` as an empty array and rendered as "No checklist yet" — so a
    /// network problem and a visit with nothing recorded looked identical,
    /// and neither offered a way to try again.
    @State private var errorMessage: String?

    private let getVisitChecklistUseCase = DependencyContainer.shared.getVisitChecklistUseCase()

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if let errorMessage {
                EmptyStateView(
                    systemImage: "wifi.exclamationmark", title: "Couldn't load the checklist",
                    message: errorMessage, actionTitle: "Try again"
                ) { Task { await load() } }
            } else if items.isEmpty {
                EmptyStateView(systemImage: "checklist", title: "No checklist yet",
                                message: "Your vet's visit checklist will appear here once the visit is complete.")
            } else {
                List(items) { item in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(item.isCompleted ? Theme.success : .secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.label).font(.brandBody)
                            if let note = item.note, !note.isEmpty {
                                Text(note).font(.brandCaption).foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                // Without this the last checklist item comes to rest under
                // the floating tab bar. Every other pushed list in the app
                // applies one of the two floating-chrome modifiers; this one
                // was missed.
                .floatingTabBarInset()
            }
        }
        // The aurora is the app's ground everywhere else; a List that keeps
        // its own opaque system background would read as a different app.
        .scrollContentBackground(.hidden)
        .auroraScreenBackground()
        .navigationTitle("Visit checklist")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            items = try await getVisitChecklistUseCase.execute(visitId: visitId)
        } catch {
            errorMessage = UserFacingError.message(for: error)
        }
    }
}

#Preview {
    NavigationStack { VisitChecklistView(visitId: UUID()) }
}
