import SwiftUI

/// I7: the vet's in-visit checklist, once it becomes the customer's record.
/// Read-only end to end — filling it out is a vet-side action this app has
/// no surface for (see `VisitChecklistRepository`'s doc comment).
struct VisitChecklistView: View {
    let visitId: UUID
    @State private var items: [VisitChecklistItem] = []
    @State private var isLoading = true

    private let getVisitChecklistUseCase = DependencyContainer.shared.getVisitChecklistUseCase()

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
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
                                Text(note).font(.brandCaption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Visit checklist")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            items = (try? await getVisitChecklistUseCase.execute(visitId: visitId)) ?? []
            isLoading = false
        }
    }
}

#Preview {
    NavigationStack { VisitChecklistView(visitId: UUID()) }
}
