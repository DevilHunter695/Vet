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
    /// K5: the same circuit (hence the same vet) as this visit, resolved
    /// once "Book free follow-up" is tapped — enforced by construction
    /// rather than left to the customer to re-pick, closing the prior
    /// "same vet/circuit isn't yet enforced end-to-end" gap.
    @State private var followUpBooking: FollowUpBooking?
    /// K5: the follow-up CTA used to fail silently — four guards, two of them
    /// `try?`, all falling through to a bare `return`. Now the failure is
    /// visible and the button reports that it is working.
    @State private var followUpErrorMessage: String?
    @State private var isPreparingFollowUp = false
    /// Load failures on the detail fetches, surfaced instead of discarded.
    @State private var otpErrorMessage: String?
    @State private var detailLoadErrorMessage: String?
    /// The address this visit was booked for. Resolved here rather than
    /// carried on `Visit`, which holds only the id — and shown at all so
    /// somebody can check, before the vet sets off, that the booking is
    /// pointed at the right door.
    @State private var visitAddress: Address?
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
    // J3: unread-message badge on the "Message your vet" row.
    @State private var unreadChatCount = 0
    @Environment(SessionStore.self) private var session
    // G3: payment retry on failure.
    @State private var paymentStatus: Payment.Status?
    @State private var retryAttempts = 0
    @State private var isRetryingPayment = false
    @State private var retryErrorMessage: String?

    /// Cancelling from here used to be impossible — the only cancel affordance
    /// in the app lived on the Visits list. `effectiveStatus` lets this screen
    /// reflect the cancellation immediately without needing the parent list to
    /// reload first.
    @State private var cancelledStatus: Visit.VisitStatus?
    @State private var pendingCancellation: CancellationPolicy.Outcome?
    @State private var isCancelling = false
    @State private var cancelErrorMessage: String?

    private let cancelVisitUseCase = DependencyContainer.shared.cancelVisitUseCase()
    private let startCallUseCase = DependencyContainer.shared.startCallUseCase()
    private let chatRepository = DependencyContainer.shared.chatRepository
    private let paymentRepository = DependencyContainer.shared.paymentRepository
    private let retryPaymentUseCase = DependencyContainer.shared.retryPaymentUseCase()
    private let paymentDisputeRepository = DependencyContainer.shared.paymentDisputeRepository
    private let visitOTPRepository = DependencyContainer.shared.visitOTPRepository
    private let getCatalogUseCase = DependencyContainer.shared.getCatalogUseCase()
    private let managePetsUseCase = DependencyContainer.shared.managePetsUseCase()
    private let manageAddressesUseCase = DependencyContainer.shared.manageAddressesUseCase()
    private let circuitRepository = DependencyContainer.shared.circuitRepository
    private let rescheduleProposalRepository = DependencyContainer.shared.rescheduleProposalRepository
    private let respondToRescheduleProposalUseCase = DependencyContainer.shared.respondToRescheduleProposalUseCase()
    private let reportVetNoShowUseCase = DependencyContainer.shared.reportVetNoShowUseCase()

    /// F7: a visit stuck en route to being serviced, past its scheduled time
    /// by the grace window, is eligible for the customer to report a no-show.
    private var canReportVetNoShow: Bool {
        (visit.status == .assigned || visit.status == .enRoute)
            && Date().timeIntervalSince(visit.scheduledAt) / 60 >= NoShowPolicy.vetGraceWindowMinutes
    }

    private var effectiveStatus: Visit.VisitStatus { cancelledStatus ?? visit.status }

    private var canCancelVisit: Bool {
        Visit.canTransition(from: effectiveStatus, to: .cancelledByUser)
    }

    /// The same window `RescheduleVisitUseCase` enforces. Gating the row on
    /// status alone offered "Reschedule this visit" on a visit two hours
    /// away, let the customer pick a new slot, and only then refused it —
    /// the failure arriving at the last tap, exactly like the slot picker
    /// offering times that had already passed.
    private var isWithinRescheduleWindow: Bool {
        visit.scheduledAt.timeIntervalSinceNow / 3600 >= CancellationPolicy.freeWindowHours
    }

    private var isReschedulableStatus: Bool {
        visit.status == .requested || visit.status == .confirmed
    }

    private func previewCancellation() async {
        do {
            pendingCancellation = try await cancelVisitUseCase.preview(visitId: visit.id, scheduledAt: visit.scheduledAt)
        } catch {
            cancelErrorMessage = UserFacingError.message(for: error)
        }
    }

    /// Takes the outcome the dialog is presenting rather than re-reading
    /// `pendingCancellation`: SwiftUI clears the presentation binding before
    /// it runs the button's action, so state read back here is already nil.
    private func confirmCancellation(_ outcome: CancellationPolicy.Outcome) async {
        isCancelling = true
        defer { isCancelling = false }
        do {
            try await cancelVisitUseCase.execute(
                visitId: visit.id, currentStatus: effectiveStatus,
                scheduledAt: visit.scheduledAt, paymentId: visit.paymentId
            )
            Haptics.success()
            withAnimation(Theme.springSoft) { cancelledStatus = .cancelledByUser }
        } catch {
            Haptics.error()
            cancelErrorMessage = UserFacingError.message(for: error)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                NavigationLink {
                    VisitTimelineView(visitId: visit.id)
                } label: {
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Visit status").font(.brandHeadline)
                                Spacer()
                                StatusBadge(status: visit.status)
                            }
                            Text(visit.scheduledAt.formatted(date: .long, time: .shortened))
                                .font(.brandBody)
                                .foregroundStyle(Theme.textSecondary)
                            if let visitAddress {
                                Label(
                                    "\(visitAddress.label) · \(visitAddress.line1)",
                                    systemImage: "house.fill"
                                )
                                .font(.brandCaption)
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(2)

                                // The access notes travel with the visit, so
                                // show them here too: this is the screen
                                // somebody opens while the vet is on the way,
                                // and "is the gate code still right?" is a
                                // question they can only answer if they can
                                // see it.
                                if let notes = visitAddress.accessNotes, !notes.isEmpty {
                                    Label(notes, systemImage: "key.fill")
                                        .font(.brandCaption)
                                        .foregroundStyle(Theme.textTertiary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            // I2: entry point to the full timestamped timeline.
                            Label("View full timeline", systemImage: "list.bullet.clipboard")
                                .font(.brandCaption)
                                .foregroundStyle(Theme.primary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .buttonStyle(PressableStyle())
                .accessibilityElement(children: .combine)
                .appearAnimation()

                if canCancelVisit {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Plans changed?")
                            .font(.brandHeadline)
                        Text("Cancelling more than \(Int(CancellationPolicy.freeWindowHours))h before the slot is free. We'll show you exactly what comes back before anything is confirmed.")
                            .font(.brandCaption)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        SecondaryButton(title: "Cancel this visit", systemImage: "xmark.circle", role: .destructive) {
                            Haptics.warning()
                            Task { await previewCancellation() }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .glassCard()
                } else if cancelledStatus == .cancelledByUser {
                    CalloutNote(text: "This visit is cancelled. Any refund due goes back to your original payment method, usually within 5–7 business days.", systemImage: "checkmark.circle.fill")
                }

                if let cancelErrorMessage {
                    ErrorBanner(message: cancelErrorMessage)
                }

                // G9: a gateway dispute (chargeback) was opened against this
                // visit's payment — surfaced so the customer isn't left
                // confused about a hold on their money. Read-only: the
                // customer can't act on it here, only see that it's happening.
                if let activeDispute {
                    PaymentDisputeStatusView(dispute: activeDispute)
                        .appearAnimation(delay: 0.01)
                }

                // G3: payment retry on failure — a clear failure state with a
                // bounded number of retries instead of a dead checkout link.
                if paymentStatus == .failed {
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Payment failed", systemImage: "exclamationmark.circle.fill")
                                .font(.brandHeadline).foregroundStyle(Theme.danger)
                            Text("Your payment for this visit didn't go through.")
                                .font(.brandCaption).foregroundStyle(Theme.textSecondary)
                            if let retryErrorMessage {
                                Text(retryErrorMessage).font(.brandCaption).foregroundStyle(Theme.danger)
                            }
                            PrimaryButton(title: "Retry payment", isLoading: isRetryingPayment) {
                                Task { await retryPayment() }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .appearAnimation(delay: 0.015)
                }

                // F6: vet-initiated reschedule accept/decline banner.
                if let pendingProposal {
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Your vet proposed a new time", systemImage: "calendar.badge.exclamationmark")
                                .font(.brandHeadline).foregroundStyle(Theme.warning)
                            Text("Accepting moves this visit to the new slot right away. Declining keeps your original time and adds a goodwill credit to your account.")
                                .font(.brandCaption).foregroundStyle(Theme.textSecondary)
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
                            Text(noShowMessage).font(.brandCaption).foregroundStyle(Theme.textSecondary)
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

                // Load failures that used to be discarded by `try?`, kept in
                // one Group so the surrounding VStack gains a single child.
                Group {
                    if let detailLoadErrorMessage {
                        ErrorBanner(message: detailLoadErrorMessage)
                    }
                    if visit.status == .arrived, visitOTP == nil, let otpErrorMessage {
                        CalloutNote(
                            text: otpErrorMessage,
                            systemImage: "lock.trianglebadge.exclamationmark",
                            tint: Theme.warning
                        )
                    }
                }
                .appearAnimation()

                if visit.status == .arrived, let visitOTP {
                    Card {
                        VStack(spacing: 8) {
                            Label("Read this code to your vet", systemImage: "lock.shield")
                                .font(.brandHeadline).foregroundStyle(Theme.primary)
                            Text(visitOTP.code)
                                // A text style, not a fixed 40pt. This code
                                // is read aloud to the vet at the door, so
                                // it is the single string on this screen
                                // somebody most needs to be able to enlarge
                                // - and pinned at 40pt it was the one thing
                                // Dynamic Type could not touch.
                                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                                .kerning(8)
                                .minimumScaleFactor(0.6)
                            Text("This confirms the visit actually started — a quick anti-fraud check.")
                                .font(.brandCaption).foregroundStyle(Theme.textSecondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .appearAnimation()
                }

                if isReschedulableStatus && isWithinRescheduleWindow {
                    Button {
                        Haptics.tap()
                        showingReschedule = true
                    } label: {
                        ActionRow(title: "Reschedule this visit", systemImage: "calendar.badge.clock", tint: Theme.primary)
                    }
                    .buttonStyle(PressableStyle())
                    .appearAnimation(delay: 0.03)
                } else if isReschedulableStatus {
                    // Said, rather than silently hidden. A row that vanishes
                    // with no explanation reads as the app losing a feature;
                    // this says which rule applied and what the alternative
                    // is, at the point somebody is looking for it.
                    CalloutNote(
                        text: "This visit is within \(Int(CancellationPolicy.freeWindowHours))h, so it can't be moved any more. You can still cancel — we'll show you exactly what comes back first.",
                        systemImage: "calendar.badge.exclamationmark", tint: Theme.warning
                    )
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
                                    Text("Diagnosis").font(.brandCaption).foregroundStyle(Theme.textSecondary)
                                    Text(diagnosis).font(.brandBody)
                                }
                            }
                            if !visit.proceduresPerformed.isEmpty {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Procedures performed").font(.brandCaption).foregroundStyle(Theme.textSecondary)
                                    ForEach(visit.proceduresPerformed, id: \.self) { Text("• \($0)").font(.brandBody) }
                                }
                            }
                            if !visit.medicationsGiven.isEmpty {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Medications given").font(.brandCaption).foregroundStyle(Theme.textSecondary)
                                    ForEach(visit.medicationsGiven, id: \.self) { Text("• \($0)").font(.brandBody) }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .appearAnimation(delay: 0.08)
                }

                // The customer's own words at booking time, kept distinct
                // from "Vet notes" below — one is the complaint, the other is
                // the clinical record, and collapsing them would misattribute
                // both.
                if let reason = visit.reason, !reason.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("What you told us", systemImage: "text.bubble")
                                .font(.brandHeadline)
                                .foregroundStyle(Theme.textSecondary)
                            Text(reason).font(.brandBody)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .appearAnimation(delay: 0.08)
                }

                // Only when there is no structured record: the two say the
                // same thing, and the structured one says it better.
                if !visit.hasStructuredRecord, let notes = visit.notes, !notes.isEmpty {
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
                    ActionRow(title: "Message your vet", systemImage: "message.fill", tint: Theme.primary, badgeCount: unreadChatCount)
                }
                .task {
                    guard let userId = session.currentUser?.id else { return }
                    let messages = (try? await chatRepository.history(visitId: visit.id)) ?? []
                    unreadChatCount = ChatUnreadPolicy.unreadCount(messages: messages, viewerId: userId)
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
                                callErrorMessage = UserFacingError.message(for: error)
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
                        .foregroundStyle(Theme.textSecondary)
                        .transition(.opacity)
                }

                if let callErrorMessage {
                    ErrorBanner(message: callErrorMessage)
                }

                if visit.status == .completed {
                    // I7: the vet's in-visit checklist, now the customer's record.
                    NavigationLink {
                        VisitChecklistView(visitId: visit.id)
                    } label: {
                        ActionRow(title: "Visit checklist", systemImage: "checklist", tint: Theme.success)
                    }
                    .buttonStyle(PressableStyle())
                    .appearAnimation(delay: 0.085)

                    // G5: GST-compliant invoice, rendered on-device from the
                    // server-issued Invoice row.
                    NavigationLink {
                        InvoiceView(visit: visit)
                    } label: {
                        ActionRow(title: "View invoice", systemImage: "doc.text.fill", tint: Theme.primary)
                    }
                    .buttonStyle(PressableStyle())
                    .appearAnimation(delay: 0.09)

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
                    Group {
                        if let followUpErrorMessage {
                            ErrorBanner(message: followUpErrorMessage)
                        }
                        Button {
                            guard !isPreparingFollowUp else { return }
                            Haptics.tap()
                            Task { await prepareFollowUp() }
                        } label: {
                            ActionRow(
                                title: isPreparingFollowUp ? "Finding your vet…" : "Book free follow-up",
                                systemImage: "arrow.uturn.forward.circle.fill",
                                tint: Theme.accent,
                                isLoading: isPreparingFollowUp
                            )
                        }
                        .buttonStyle(PressableStyle())
                        .disabled(isPreparingFollowUp)
                    }
                    .appearAnimation(delay: 0.12)
                }
            }
            .padding()
        }
        .auroraScreenBackground()
        .floatingTabBarInset()
        .confirmationDialog(
            "Cancel this visit?",
            isPresented: Binding(get: { pendingCancellation != nil }, set: { if !$0 { pendingCancellation = nil } }),
            // Without this the dialog shows only the refund line and a red
            // button - the question it is asking is invisible, so the first
            // thing you read is a number and the second is "Cancel visit".
            titleVisibility: .visible,
            presenting: pendingCancellation
        ) { outcome in
            Button("Cancel visit", role: .destructive) {
                Task { await confirmCancellation(outcome) }
            }
            Button("Keep visit", role: .cancel) {}
        } message: { outcome in
            if outcome.isPastVisitTime {
                Text("This visit's time has passed — no refund applies.")
            } else if outcome.refundPercent == 100 {
                Text("Cancelling now refunds \(CurrencyFormatter.rupees(outcome.refundMinorUnits)) in full.")
            } else {
                Text("Cancelling now refunds \(CurrencyFormatter.rupees(outcome.refundMinorUnits)) of \(CurrencyFormatter.rupees(outcome.paidMinorUnits)).")
            }
        }
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
        .sheet(item: $followUpBooking) { booking in
            NavigationStack {
                // K5: booking directly against the original visit's own
                // `circuit` (not the catalog's add-to-cart flow) is what
                // actually guarantees the same vet services the follow-up.
                BookingView(circuit: booking.circuit, serviceCategory: booking.service.category,
                            serviceId: booking.service.id, variantId: booking.variantId, preselectedPetId: visit.petId)
            }
        }
        .task {
            // Best-effort and deliberately silent on failure: the address is
            // context on a screen that has plenty, and a header that fails to
            // load one line should not put an error banner over a visit
            // somebody opened to cancel or track.
            if let addressId = visit.addressId, let ownerId = session.currentUser?.id {
                let saved = (try? await manageAddressesUseCase.list(ownerId: ownerId)) ?? []
                visitAddress = saved.first { $0.id == addressId }
            }
            // These four fetches were all `try?`. A missing OTP or an
            // unresolved payment status then looked identical to "there
            // isn't one", which is exactly the wrong thing to tell someone
            // standing at the door with a vet.
            if visit.status == .arrived {
                do {
                    visitOTP = try await visitOTPRepository.generateOTP(visitId: visit.id)
                } catch {
                    otpErrorMessage = "We couldn't generate your door code. Ask your vet to confirm the visit manually — \(UserFacingError.message(for: error))"
                }
            }
            var failures: [String] = []
            do {
                pendingProposal = try await rescheduleProposalRepository.pendingProposal(visitId: visit.id)
            } catch {
                failures.append("reschedule requests")
            }
            do {
                activeDispute = try await paymentDisputeRepository.disputes(visitId: visit.id).first { $0.isActive }
            } catch {
                failures.append("dispute status")
            }
            if let paymentId = visit.paymentId {
                do {
                    paymentStatus = try await paymentRepository.paymentStatus(paymentId: paymentId)
                } catch {
                    failures.append("payment status")
                }
            }
            detailLoadErrorMessage = failures.isEmpty
                ? nil
                : "Couldn't load \(ListFormatter.localizedString(byJoining: failures)). Pull to refresh or try again shortly."
        }
    }

    /// G3: re-launches hosted checkout for this visit's payment, bounded by
    /// `PaymentRetryPolicy`'s attempt cap.
    private func retryPayment() async {
        guard let paymentId = visit.paymentId else { return }
        isRetryingPayment = true
        retryErrorMessage = nil
        defer { isRetryingPayment = false }
        do {
            let paidMinorUnits = try await DependencyContainer.shared.visitRepository.paidAmountMinorUnits(visitId: visit.id)
            let url = try await retryPaymentUseCase.execute(
                visitId: visit.id, paymentId: paymentId, amountMinorUnits: paidMinorUnits, priorAttempts: retryAttempts
            )
            retryAttempts += 1
            await UIApplication.shared.open(url)
        } catch {
            retryErrorMessage = UserFacingError.message(for: error)
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
            proposalActionMessage = UserFacingError.message(for: error)
        }
    }

    /// F7: reports the vet as a no-show once the grace window has passed —
    /// transitions the visit to `noShowVet` and triggers the full refund + credit.
    private func reportVetNoShow() async {
        isReportingNoShow = true
        defer { isReportingNoShow = false }
        do {
            let outcome = try await reportVetNoShowUseCase.execute(visit: visit)
            // Through the shared formatter: integer-dividing minor units by
            // 100 silently drops the paise on any non-round refund.
            noShowMessage = "Reported. Your \(CurrencyFormatter.rupees(outcome.refundMinorUnits)) refund and \(outcome.goodwillCreditPoints) goodwill points are on the way."
        } catch {
            noShowMessage = UserFacingError.message(for: error)
        }
    }

    /// K5: resolves the same circuit (hence the same vet) as this visit,
    /// the same pet, and the consult service's free follow-up variant
    /// before presenting booking — the customer never re-selects any of it.
    private func prepareFollowUp() async {
        isPreparingFollowUp = true
        followUpErrorMessage = nil
        defer { isPreparingFollowUp = false }
        do {
            let services = try await getCatalogUseCase.execute(vertical: .vet)
            guard let service = services.first(where: { $0.variants.contains(where: \.isFollowUp) }),
                  let variantId = service.variants.first(where: \.isFollowUp)?.id else {
                followUpErrorMessage = "Follow-up consults aren't available right now. Message your vet and we'll sort it out."
                Haptics.error()
                return
            }
            let circuit = try await circuitRepository.circuit(id: visit.circuitId)
            followUpBooking = FollowUpBooking(circuit: circuit, service: service, variantId: variantId)
        } catch {
            Haptics.error()
            followUpErrorMessage = "Couldn't set up your follow-up. \(UserFacingError.message(for: error))"
        }
    }
}

/// K5: bundles the resolved circuit/service/variant for the follow-up
/// booking sheet — `Identifiable` so it can drive `.sheet(item:)`.
private struct FollowUpBooking: Identifiable {
    let id = UUID()
    let circuit: Circuit
    let service: Service
    let variantId: UUID
}

private struct ActionRow: View {
    let title: String
    let systemImage: String
    let tint: Color
    /// J3: unread-message badge, e.g. on the "Message your vet" row.
    var badgeCount: Int = 0
    /// Swaps the trailing chevron for a spinner while the row's action is
    /// in flight, so a slow action doesn't read as a dead button.
    var isLoading: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            // A plain tinted symbol, not a symbol inside a tinted disc.
            // Four discs stacked down the screen is four more shapes than
            // the list needs; the colour alone already separates them.
            Image(systemName: systemImage)
                // scaledIcon, not a pinned 17pt - this file already has the
                // helper for exactly this and I used a literal an hour ago.
                .scaledIcon(17, weight: .semibold)
                .foregroundStyle(tint)
                .frame(width: 28, alignment: .center)

            Text(title).font(.body).foregroundStyle(.primary)
            Spacer()
            if badgeCount > 0 {
                Text("\(badgeCount)")
                    .font(.brandCaption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Theme.danger, in: Capsule())
                    .contentTransition(.numericText())
                    .accessibilityLabel("\(badgeCount) unread messages")
            }
            if isLoading {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, Spacing.gutter)
        .padding(.vertical, Spacing.row)
        // A grouped-list row, not a floating card.
        //
        // This was `.background(.background)` plus a drop shadow, which on
        // the dark ground resolves to near-black - so four sibling actions
        // read as four black slabs hovering over the gradient rather than as
        // one list of things you can do with this visit. The fill is the
        // system's grouped-row colour now, the shadow is gone, and the
        // corners are rounder.
        .background(Color(.secondarySystemGroupedBackground).opacity(0.92),
                    in: RoundedRectangle(cornerRadius: Spacing.corner, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Spacing.corner, style: .continuous))
        .accessibilityElement(children: .combine)
        .animation(Theme.springQuick, value: badgeCount)
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
                    .foregroundStyle(Theme.textSecondary)
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
