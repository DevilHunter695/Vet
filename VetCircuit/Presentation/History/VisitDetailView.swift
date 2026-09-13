import SwiftUI
import UIKit

struct VisitDetailView: View {
    let visit: Visit
    @State private var showingReview = false
    @State private var showingReschedule = false
    @State private var activeCallSession: CallSession?
    @State private var callErrorMessage: String?
    @State private var visitOTP: VisitOTP?
    @State private var showingReportProblem = false

    private let startCallUseCase = DependencyContainer.shared.startCallUseCase()
    private let visitOTPRepository = DependencyContainer.shared.visitOTPRepository

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

                if visit.status == .arrived, let visitOTP {
                    Card {
                        VStack(spacing: 8) {
                            Label("Read this code to your vet", systemImage: "lock.shield")
                                .font(.brandHeadline).foregroundStyle(Theme.primary)
                            Text(visitOTP.code)
                                .font(.system(size: 40, weight: .bold, design: .rounded))
                                .kerning(8)
                            Text("This confirms the visit actually started — a quick anti-fraud check.")
                                .font(.brandCaption).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .appearAnimation()
                }

                if visit.status == .requested || visit.status == .confirmed {
                    Button {
                        Haptics.tap()
                        showingReschedule = true
                    } label: {
                        ActionRow(title: "Reschedule this visit", systemImage: "calendar.badge.clock", tint: Theme.primary)
                    }
                    .buttonStyle(PressableStyle())
                    .appearAnimation(delay: 0.03)
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
                            do {
                                let session = try await startCallUseCase.execute(visitId: visit.id)
                                activeCallSession = session
                                if let dialURL = URL(string: "tel://\(session.proxyNumber.filter { $0.isNumber || $0 == "+" })") {
                                    await UIApplication.shared.open(dialURL)
                                }
                            } catch {
                                callErrorMessage = error.localizedDescription
                            }
                        }
                    } label: {
                        // J4: masked calling — the customer dials a shared
                        // proxy number, never the vet's real phone number.
                        ActionRow(title: "Call your vet", systemImage: "phone.fill", tint: Theme.accent)
                    }
                    .buttonStyle(PressableStyle())
                    .appearAnimation(delay: 0.15)
                }

                if let activeCallSession {
                    Label("Connecting you on \(activeCallSession.proxyNumber) — your real number stays private.", systemImage: "lock.shield")
                        .font(.brandCaption)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }

                if let callErrorMessage {
                    ErrorBanner(message: callErrorMessage)
                }

                if visit.status == .completed {
                    PrimaryButton(title: "Rate this visit") { showingReview = true }
                        .appearAnimation(delay: 0.1)

                    // K8 (P0): a dispute is just a support ticket carrying
                    // this visit's id — same queue, same audit trail.
                    Button {
                        Haptics.tap()
                        showingReportProblem = true
                    } label: {
                        ActionRow(title: "Report a problem with this visit", systemImage: "exclamationmark.bubble.fill", tint: Theme.danger)
                    }
                    .buttonStyle(PressableStyle())
                    .appearAnimation(delay: 0.12)
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
        .sheet(isPresented: $showingReschedule) {
            RescheduleVisitView(visit: visit)
        }
        .sheet(isPresented: $showingReportProblem) {
            ContactSupportView(visitId: visit.id, subjectPlaceholder: "Problem with visit on \(visit.scheduledAt.formatted(date: .abbreviated, time: .omitted))")
        }
        .task {
            guard visit.status == .arrived else { return }
            visitOTP = try? await visitOTPRepository.generateOTP(visitId: visit.id)
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
