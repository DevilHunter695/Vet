import SwiftUI

/// M4: a support ticket's detail screen, including the admin-style "issue a
/// refund/credit" action. Real authorization lives server-side — the
/// issue-support-refund Edge Function checks `admins` and refuses anyone
/// else — this screen is just where that action is reached from in this
/// app's mock world (there is no separate admin app here).
@Observable
@MainActor
final class TicketDetailViewModel {
    let ticket: SupportTicket
    var auditTrail: [SupportRefundAudit] = []
    var isLoading = false
    var isSubmitting = false
    var errorMessage: String?
    var didIssue = false

    private let issueSupportRefundUseCase = DependencyContainer.shared.issueSupportRefundUseCase()

    init(ticket: SupportTicket) {
        self.ticket = ticket
    }

    func loadAuditTrail() async {
        isLoading = true
        defer { isLoading = false }
        do {
            auditTrail = try await issueSupportRefundUseCase.auditTrail(ticketId: ticket.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func issue(kind: SupportRefundAudit.Kind, amountMinorUnits: Int, reason: String, issuedByUserId: UUID) async {
        guard let visitId = ticket.visitId else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            _ = try await issueSupportRefundUseCase.execute(
                ticketId: ticket.id, visitId: visitId, issuedByUserId: issuedByUserId,
                kind: kind, amountMinorUnits: amountMinorUnits, reason: reason
            )
            Haptics.success()
            didIssue = true
            await loadAuditTrail()
        } catch {
            Haptics.error()
            errorMessage = error.localizedDescription
        }
    }
}

struct TicketDetailView: View {
    @Environment(SessionStore.self) private var session
    @State private var viewModel: TicketDetailViewModel
    @State private var showingIssueSheet = false

    init(ticket: SupportTicket) {
        _viewModel = State(initialValue: TicketDetailViewModel(ticket: ticket))
    }

    var body: some View {
        List {
            Section("Ticket") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(viewModel.ticket.subject).font(.brandHeadline)
                    Text(viewModel.ticket.body).font(.brandBody).foregroundStyle(.secondary)
                    Text(viewModel.ticket.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
            }

            if let errorMessage = viewModel.errorMessage {
                ErrorBanner(message: errorMessage)
            }

            if viewModel.ticket.visitId != nil {
                Section("Support action") {
                    Button {
                        showingIssueSheet = true
                    } label: {
                        Label("Issue refund or wallet credit", systemImage: "indianrupeesign.circle")
                    }
                }

                Section("Audit trail") {
                    if viewModel.isLoading {
                        ProgressView()
                    } else if viewModel.auditTrail.isEmpty {
                        Text("No refunds or credits issued for this ticket yet.").foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.auditTrail) { audit in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(audit.kind == .refund ? "Refund" : "Wallet credit").font(.brandBody.weight(.semibold))
                                    Spacer()
                                    Text(CurrencyFormatter.rupees(audit.amountMinorUnits)).font(.brandBody)
                                }
                                Text(audit.reason).font(.brandCaption).foregroundStyle(.secondary)
                                Text(audit.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            } else {
                Section {
                    Text("This ticket isn't tied to a visit, so no refund or credit can be issued from it.")
                        .font(.brandCaption).foregroundStyle(.secondary)
                }
            }
        }
        // The aurora is the app's ground everywhere else; a List that keeps
        // its own opaque system background would read as a different app.
        .scrollContentBackground(.hidden)
        .auroraScreenBackground()
        .navigationTitle("Ticket")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.loadAuditTrail() }
        .sheet(isPresented: $showingIssueSheet) {
            if let visitId = viewModel.ticket.visitId, let user = session.currentUser {
                IssueSupportRefundSheet(visitId: visitId) { kind, amount, reason in
                    await viewModel.issue(kind: kind, amountMinorUnits: amount, reason: reason, issuedByUserId: user.id)
                    showingIssueSheet = false
                }
            }
        }
    }
}

/// The actual money movement happens server-side in issue-support-refund;
/// this sheet only collects the inputs it needs.
private struct IssueSupportRefundSheet: View {
    let visitId: UUID
    let onSubmit: (SupportRefundAudit.Kind, Int, String) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var kind: SupportRefundAudit.Kind = .refund
    @State private var amountRupees: String = ""
    @State private var reason: String = ""
    @State private var isSubmitting = false

    private var amountMinorUnits: Int? {
        guard let rupees = Double(amountRupees), rupees > 0 else { return nil }
        return Int((rupees * 100).rounded())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Type") {
                    Picker("Type", selection: $kind) {
                        Text("Refund").tag(SupportRefundAudit.Kind.refund)
                        Text("Wallet credit").tag(SupportRefundAudit.Kind.walletCredit)
                    }
                    .pickerStyle(.segmented)
                }
                Section("Amount (₹)") {
                    TextField("0.00", text: $amountRupees)
                        .keyboardType(.decimalPad)
                }
                Section("Reason (recorded in the audit trail)") {
                    TextField("Why is this being issued?", text: $reason, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle(kind == .refund ? "Issue refund" : "Issue wallet credit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                PrimaryButton(title: "Confirm", isLoading: isSubmitting) {
                    guard let amount = amountMinorUnits, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    isSubmitting = true
                    Task {
                        await onSubmit(kind, amount, reason)
                        isSubmitting = false
                    }
                }
                .disabled(amountMinorUnits == nil || reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .padding()
                .background(.regularMaterial)
            }
        }
    }
}

#Preview {
    NavigationStack {
        TicketDetailView(ticket: SupportTicket(id: UUID(), userId: UUID(), visitId: UUID(), subject: "Vet arrived late", body: "The vet was 45 minutes late.", status: .open, createdAt: .now))
            .environment(SessionStore())
    }
}
