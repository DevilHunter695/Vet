import SwiftUI

struct VisitDetailView: View {
    let visit: Visit
    @State private var showingReview = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Visit status").font(.headline)
                            Spacer()
                            StatusBadge(status: visit.status)
                        }
                        Text(visit.scheduledAt.formatted(date: .long, time: .shortened))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let notes = visit.notes, !notes.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Vet notes").font(.headline)
                        Text(notes)
                    }
                }

                NavigationLink {
                    ChatView(visitId: visit.id)
                } label: {
                    Label("Message your vet", systemImage: "message.fill")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)

                if visit.status == .completed {
                    PrimaryButton(title: "Rate this visit") { showingReview = true }
                }
            }
            .padding()
        }
        .navigationTitle("Visit details")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingReview) {
            ReviewView(visitId: visit.id)
        }
    }
}

#Preview {
    NavigationStack { VisitDetailView(visit: MockData.visits.first ?? Visit(
        id: UUID(), userId: UUID(), petId: UUID(), vetId: UUID(), circuitId: UUID(),
        status: .completed, scheduledAt: .now, completedAt: .now, notes: "Bruno is healthy. Next vaccination due in 3 months.", paymentId: nil
    )) }
}
