import SwiftUI

struct VisitDetailView: View {
    let visit: Visit
    @State private var showingReview = false
    @State private var callURL: URL?
    @State private var callErrorMessage: String?

    private let startCallUseCase = DependencyContainer.shared.startCallUseCase()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Visit status").font(.brandHeadline)
                            Spacer()
                            StatusBadge(status: visit.status)
                        }
                        Text(visit.scheduledAt.formatted(date: .long, time: .shortened))
                            .font(.brandBody)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .appearAnimation()

                if visit.status == .enRoute {
                    NavigationLink {
                        LiveTrackingView(visitId: visit.id)
                    } label: {
                        ActionRow(title: "Track your vet live", systemImage: "location.fill", tint: Theme.inProgress)
                    }
                    .buttonStyle(PressableStyle())
                    .appearAnimation(delay: 0.05)
                }

                if let notes = visit.notes, !notes.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Vet notes", systemImage: "note.text")
                                .font(.brandHeadline)
                                .foregroundStyle(Theme.primary)
                            Text(notes).font(.brandBody)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .appearAnimation(delay: 0.08)
                }

                NavigationLink {
                    ChatView(visitId: visit.id)
                } label: {
                    ActionRow(title: "Message your vet", systemImage: "message.fill", tint: Theme.primary)
                }
                .buttonStyle(PressableStyle())
                .appearAnimation(delay: 0.1)

                if visit.status == .requested || visit.status == .confirmed {
                    Button {
                        Task {
                            do { callURL = try await startCallUseCase.execute(visitId: visit.id) }
                            catch { callErrorMessage = error.localizedDescription }
                        }
                    } label: {
                        ActionRow(title: "Quick call with vet", systemImage: "video.fill", tint: Theme.accent)
                    }
                    .buttonStyle(PressableStyle())
                    .appearAnimation(delay: 0.15)
                }

                if let callErrorMessage {
                    ErrorBanner(message: callErrorMessage)
                }

                if visit.status == .completed {
                    PrimaryButton(title: "Rate this visit") { showingReview = true }
                        .appearAnimation(delay: 0.1)
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Visit details")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingReview) {
            ReviewView(visitId: visit.id)
        }
        .sheet(item: $callURL) { url in
            CheckoutWebView(url: url)
        }
    }
}

private struct ActionRow: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(tint.opacity(0.15))
                Image(systemName: systemImage).foregroundStyle(tint)
            }
            .frame(width: 36, height: 36)

            Text(title).font(.brandHeadline).foregroundStyle(.primary)
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: Theme.cardShadow, radius: 8, y: 3)
    }
}

#Preview {
    NavigationStack { VisitDetailView(visit: MockData.visits.first ?? Visit(
        id: UUID(), userId: UUID(), petId: UUID(), vetId: UUID(), circuitId: UUID(),
        status: .completed, scheduledAt: .now, completedAt: .now, notes: "Bruno is healthy. Next vaccination due in 3 months.", paymentId: nil
    )) }
}
