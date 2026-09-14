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
    @State private var showingIncidentReport = false
    @State private var followUpService: Service?
    @State private var followUpPet: Pet?
    @State private var showingTip = false
    @State private var hasTipped = false
    // F6: a pending vet-initiated reschedule proposal, if any.
    @State private var pendingProposal: RescheduleProposal?
    @State private var proposalActionMessage: String?
    @State private var isRespondingToProposal = false
    // F7: vet no-show reporting.
    @State private var noShowMessage: String?
    @State private var isReportingNoShow = false
    // G9: an active gateway dispute against this visit's payment, if any.
    @State private var activeDispute: PaymentDispute?

    private let startCallUseCase = DependencyContainer.shared.startCallUseCase()
    private let paymentDisputeRepository = DependencyContainer.shared.paymentDisputeRepository
    private let visitOTPRepository = DependencyContainer.shared.visitOTPRepository
    private let getCatalogUseCase = DependencyContainer.shared.getCatalogUseCase()
    private let managePetsUseCase = DependencyContainer.shared.managePetsUseCase()
    private let rescheduleProposalRepository = DependencyContainer.shared.rescheduleProposalRepository
    private let respondToRescheduleProposalUseCase = DependencyContainer.shared.respondToRescheduleProposalUseCase()
    private let reportVetNoShowUseCase = DependencyContainer.shared.reportVetNoShowUseCase()

    /// F7: a visit stuck en route to being serviced, past its scheduled time
    /// by the grace window, is eligible for the customer to report a no-show.
    private var canReportVetNoShow: Bool {
        (visit.status == .assigned || visit.status == .enRoute)
            && Date().timeIntervalSince(visit.scheduledAt) / 60 >= NoShowPolicy.vetGraceWindowMinutes
    }

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

                // G9: a gateway dispute (chargeback) was opened against this
                // visit's payment — surfaced so the customer isn't left
                // confused about a hold on their money. Read-only: the
                // customer can't act on it here, only see that it's happening.
                if let activeDispute {
                    PaymentDisputeStatusView(dispute: activeDispute)
                        .appearAnimation(delay: 0.01)
                }

                // F6: vet-initiated reschedule accept/decline banner.
                if let pendingProposal {
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Your vet proposed a new time", systemImage: "calendar.badge.exclamationmark")
                                .font(.brandHeadline).foregroundStyle(Theme.warning)
                            Text("Accepting moves this visit to the new slot right away. Declining keeps your original time and adds a goodwill credit to your account.")
                                .font(.brandCaption).foregroundStyle(.secondary)
                            if let proposalActionMessage {
                                Text(proposalActionMessage).font(.brandCaption).foregroundStyle(Theme.danger)
                            }
                            HStack(spacing: 12) {
                                PrimaryButton(title: "Accept", isLoading: isRespondingToProposal) {
                                    Task { await respond(to: pendingProposal, accept: true) }
                                }
                                Button("Decline", role: .destructive) {
                                    Task { await respond(to: pendingProposal, accept: false) }
                                }
                                .disabled(isRespondingToProposal)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .appearAnimation(delay: 0.02)
                }

                if canReportVetNoShow {
                    VStack(alignment: .leading, spacing: 6) {
                        Button {
                            Haptics.tap()
                            Task { await reportVetNoShow() }
                        } label: {
                            ActionRow(title: "Vet didn't show up", systemImage: "exclamationmark.triangle.fill", tint: Theme.danger)
                        }
                        .buttonStyle(PressableStyle())
                        .disabled(isReportingNoShow)
                        if let noShowMessage {
                            Text(noShowMessage).font(.brandCaption).foregroundStyle(.secondary)
                        }
                    }
                    .appearAnimation(delay: 0.04)
                }

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

                // K1: structured visit record — diagnosis, procedures, meds —
                // falls back to the legacy free-text `notes` blob for visits
                // recorded before these columns existed.
                if visit.hasStructuredRecord {
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Visit record", systemImage: "note.text")
                                .font(.brandHeadline)
                                .foregroundStyle(Theme.primary)
                            if let diagnosis = visit.diagnosisNotes, !diagnosis.isEmpty {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Diagnosis").font(.brandCaption).foregroundStyle(.secondary)
                                    Text(diagnosis).font(.brandBody)
                                }
                            }
                            if !visit.proceduresPerformed.isEmpty {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Procedures performed").font(.brandCaption).foregroundStyle(.secondary)
                                    ForEach(visit.proceduresPerformed, id: \.self) { Text("• \($0)").font(.brandBody) }
                                }
                            }
                            if !visit.medicationsGiven.isEmpty {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Medications given").font(.brandCaption).foregroundStyle(.secondary)
                                    ForEach(visit.medicationsGiven, id: \.self) { Text("• \($0)").font(.brandBody) }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .appearAnimation(delay: 0.08)
                } else if let notes = visit.notes, !notes.isEmpty {
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

                // K6: always reachable from a visit's detail page — the view
                // itself renders an empty state when this pet has no lab
                // test reports (most visits won't).
                NavigationLink {
                    LabTestReportsView(petId: visit.petId, visitId: visit.id)
                } label: {
                    ActionRow(title: "Lab test reports", systemImage: "cross.vial.fill", tint: Theme.accent)
                }
                .buttonStyle(PressableStyle())
                .appearAnimation(delay: 0.1)

                // L5: safety-specific, separate from "Report a problem with
                // this visit" below (a billing/service dispute) — see the
                // doc comment on IncidentReport. Available at any visit
                // status, not just completed, since a safety concern can
                // arise at any point in the visit's lifecycle.
                Button {
                    Haptics.tap()
                    showingIncidentReport = true
                } label: {
                    ActionRow(title: "Report an incident", systemImage: "shield.lefthalf.filled", tint: Theme.danger)
                }
                .buttonStyle(PressableStyle())
                .appearAnimation(delay: 0.11)

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

                    // E11: shown once per completed visit — 100% to the vet.
                    if !hasTipped {
                        Button {
                            Haptics.tap()
                            showingTip = true
                        } label: {
                            ActionRow(title: "Add a tip for your vet", systemImage: "heart.fill", tint: Theme.accent)
                        }
                        .buttonStyle(PressableStyle())
                        .appearAnimation(delay: 0.11)
                    }

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

                // K5: 1-tap follow-up — same pet, same vet/circuit, the free
                // "within 14 days" variant preselected, no re-picking anything.
                if FollowUpBookingPolicy.isEligible(visit: visit) {
                    Button {
                        Task { await prepareFollowUp() }
                    } label: {
                        ActionRow(title: "Book free follow-up", systemImage: "arrow.uturn.forward.circle.fill", tint: Theme.accent)
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
        .sheet(isPresented: $showingTip) {
            TipVetView(visitId: visit.id) { hasTipped = true }
        }
        .sheet(isPresented: $showingReschedule) {
            RescheduleVisitView(visit: visit)
        }
        .sheet(isPresented: $showingReportProblem) {
            ContactSupportView(visitId: visit.id, subjectPlaceholder: "Problem with visit on \(visit.scheduledAt.formatted(date: .abbreviated, time: .omitted))")
        }
        .sheet(isPresented: $showingIncidentReport) {
            IncidentReportView(visitId: visit.id)
        }
        .sheet(item: $followUpService) { service in
            NavigationStack {
                ServiceDetailView(service: service, pet: followUpPet, preselectedVariantId: service.variants.first(where: \.isFollowUp)?.id)
            }
        }
        .task {
            if visit.status == .arrived {
                visitOTP = try? await visitOTPRepository.generateOTP(visitId: visit.id)
            }
            pendingProposal = try? await rescheduleProposalRepository.pendingProposal(visitId: visit.id)
            activeDispute = try? await paymentDisputeRepository.disputes(visitId: visit.id).first { $0.isActive }
        }
    }

    /// F6: accept reschedules the visit immediately (bypassing the
    /// customer-side 4h policy window, since the vet moved the slot);
    /// decline awards the goodwill credit. Either way the banner clears.
    private func respond(to proposal: RescheduleProposal, accept: Bool) async {
        isRespondingToProposal = true
        proposalActionMessage = nil
        defer { isRespondingToProposal = false }
        do {
            _ = try await respondToRescheduleProposalUseCase.execute(proposal: proposal, visit: visit, accept: accept)
            pendingProposal = nil
        } catch {
            proposalActionMessage = error.localizedDescription
        }
    }

    /// F7: reports the vet as a no-show once the grace window has passed —
    /// transitions the visit to `noShowVet` and triggers the full refund + credit.
    private func reportVetNoShow() async {
        isReportingNoShow = true
        defer { isReportingNoShow = false }
        do {
            let outcome = try await reportVetNoShowUseCase.execute(visit: visit)
            noShowMessage = "Reported. Your ₹\(outcome.refundMinorUnits / 100) refund and \(outcome.goodwillCreditPoints) goodwill points are on the way."
        } catch {
            noShowMessage = error.localizedDescription
        }
    }

    /// K5: resolves the same pet and the consult service's free follow-up
    /// variant before presenting booking — the customer never re-selects
    /// either.
    private func prepareFollowUp() async {
        guard let services = try? await getCatalogUseCase.execute(vertical: .vet),
              let service = services.first(where: { $0.variants.contains(where: \.isFollowUp) }) else { return }
        followUpPet = try? await managePetsUseCase.list(ownerId: visit.userId).first { $0.id == visit.petId }
        followUpService = service
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

/// G9: a small banner explaining a gateway dispute (chargeback) is under
/// review for this visit's payment — the customer-facing half of dispute
/// handling. There is nothing to act on here (evidence, response, etc. are
/// ops/gateway concerns), only enough context that a hold doesn't look like
/// a silent problem.
struct PaymentDisputeStatusView: View {
    let dispute: PaymentDispute

    private var message: String {
        switch dispute.status {
        case .open, .needsResponse:
            return "A payment dispute is under review for this visit. We're looking into it — no action is needed from you right now."
        case .won:
            return "The payment dispute on this visit has been resolved in your favor."
        case .lost:
            return "The payment dispute on this visit has been resolved."
        }
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("Payment under review", systemImage: "exclamationmark.shield.fill")
                    .font(.brandHeadline)
                    .foregroundStyle(dispute.isActive ? Theme.warning : .secondary)
                Text(message)
                    .font(.brandCaption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#Preview {
    NavigationStack { VisitDetailView(visit: MockData.visits.first ?? Visit(
        id: UUID(), userId: UUID(), petId: UUID(), vetId: UUID(), circuitId: UUID(),
        status: .completed, scheduledAt: .now, completedAt: .now, notes: "Bruno is healthy. Next vaccination due in 3 months.", paymentId: nil
    )) }
}
