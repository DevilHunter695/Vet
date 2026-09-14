import SwiftUI
import UIKit

@Observable
@MainActor
final class PrivacyConsentViewModel {
    var pendingDeletion: DeletionRequest?
    var consents: [ConsentRecord] = []
    var isLoading = false
    var isExporting = false
    var errorMessage: String?
    var exportedFileURL: URL?
    var exportedPDF: PDFShareURL?
    var deletionRequested = false

    private let manageAccountDeletionUseCase = DependencyContainer.shared.manageAccountDeletionUseCase()
    private let exportDataUseCase = DependencyContainer.shared.exportDataUseCase()
    private let consentRepository = DependencyContainer.shared.consentRepository

    func load(userId: UUID) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            async let pending = manageAccountDeletionUseCase.pendingDeletion(userId: userId)
            async let activeConsents = consentRepository.activeConsents(userId: userId)
            pendingDeletion = try await pending
            consents = try await activeConsents
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// O5: "what you collect, why, withdraw consent" — a DPDP data-principal
    /// right, not just a delete-account afterthought.
    func withdraw(_ consent: ConsentRecord, userId: UUID) async {
        do {
            try await consentRepository.withdraw(userId: userId, purpose: consent.purpose)
            consents.removeAll { $0.id == consent.id }
            Haptics.tap()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func requestDeletion(userId: UUID) async {
        do {
            pendingDeletion = try await manageAccountDeletionUseCase.requestDeletion(userId: userId)
            Haptics.warning()
            deletionRequested = true
        } catch {
            Haptics.error()
            errorMessage = error.localizedDescription
        }
    }

    func cancelDeletion(userId: UUID) async {
        do {
            try await manageAccountDeletionUseCase.cancelPendingDeletion(userId: userId)
            pendingDeletion = nil
            Haptics.success()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// A7: exports the customer's data to a JSON file they can share/save.
    func exportData(userId: UUID) async {
        isExporting = true
        errorMessage = nil
        defer { isExporting = false }
        do {
            let export = try await exportDataUseCase.execute(userId: userId)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(export)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("vetcircuit-my-data.json")
            try data.write(to: url)
            exportedFileURL = url
            Haptics.success()
        } catch {
            Haptics.error()
            errorMessage = error.localizedDescription
        }
    }

    /// A7: the same export as a shareable, human-readable PDF — reuses
    /// `PDFDocumentBuilder` (the pattern already used for K2/K4).
    func exportDataAsPDF(userId: UUID) async {
        isExporting = true
        errorMessage = nil
        defer { isExporting = false }
        do {
            let export = try await exportDataUseCase.execute(userId: userId)
            let data = export.summaryPDF()
            exportedPDF = PDFShareURL.write(data, suggestedName: "vetcircuit-my-data")
            Haptics.success()
        } catch {
            Haptics.error()
            errorMessage = error.localizedDescription
        }
    }
}

/// O5 (consent dashboard) + A6 (delete account) + A7 (export data) — the
/// three DPDP/App-Store-mandated account screens the plan calls "the most
/// common avoidable rejection" (A6) and a date-bound legal obligation (O5).
struct PrivacyConsentView: View {
    @Environment(SessionStore.self) private var session
    @State private var viewModel = PrivacyConsentViewModel()
    @State private var showingDeleteConfirmation = false
    @State private var showingShareSheet = false

    var body: some View {
        List {
            Section("What you've agreed to") {
                if viewModel.consents.isEmpty {
                    Text("No active consents yet — these appear once you accept the liability waiver or grant location tracking.")
                        .font(.brandCaption).foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.consents) { consent in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(consentDisplayName(consent.purpose)).font(.brandHeadline)
                            Text("Granted \(consent.grantedAt.formatted(date: .abbreviated, time: .omitted)) · version \(consent.version)")
                                .font(.brandCaption).foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            Button("Withdraw", role: .destructive) {
                                if let user = session.currentUser { Task { await viewModel.withdraw(consent, userId: user.id) } }
                            }
                        }
                    }
                }
            }

            Section("Your data") {
                Button {
                    Haptics.tap()
                    if let user = session.currentUser { Task { await viewModel.exportData(userId: user.id) } }
                } label: {
                    HStack {
                        Label("Export as JSON", systemImage: "square.and.arrow.up")
                        Spacer()
                        if viewModel.isExporting { ProgressView() }
                    }
                }
                .disabled(viewModel.isExporting)

                Button {
                    Haptics.tap()
                    if let user = session.currentUser { Task { await viewModel.exportDataAsPDF(userId: user.id) } }
                } label: {
                    Label("Export as PDF", systemImage: "doc.richtext")
                }
                .disabled(viewModel.isExporting)

                Text("Downloads everything VetCircuit holds about you — profile, addresses, visit history, and consent records — as JSON (machine-readable) or PDF (readable summary).")
                    .font(.brandCaption).foregroundStyle(.secondary)
            }

            Section("Danger zone") {
                if let pending = viewModel.pendingDeletion {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Deletion scheduled", systemImage: "clock.badge.exclamationmark")
                            .font(.brandHeadline).foregroundStyle(Theme.danger)
                        Text("Your account will be permanently deleted on \(pending.scheduledPurgeAt.formatted(date: .long, time: .omitted)). You can still cancel this.")
                            .font(.brandCaption).foregroundStyle(.secondary)
                        Button("Cancel deletion") {
                            Haptics.tap()
                            if let user = session.currentUser { Task { await viewModel.cancelDeletion(userId: user.id) } }
                        }
                        .foregroundStyle(Theme.primary)
                    }
                } else {
                    Button(role: .destructive) {
                        Haptics.tap()
                        showingDeleteConfirmation = true
                    } label: {
                        Label("Delete my account", systemImage: "trash")
                    }
                    .tint(Theme.danger)
                }

                if let errorMessage = viewModel.errorMessage {
                    ErrorBanner(message: errorMessage)
                }
            }
        }
        .navigationTitle("Privacy & consent")
        .task { if let user = session.currentUser { await viewModel.load(userId: user.id) } }
        .confirmationDialog(
            "Delete your account?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete account", role: .destructive) {
                if let user = session.currentUser { Task { await viewModel.requestDeletion(userId: user.id) } }
            }
            Button("Keep account", role: .cancel) {}
        } message: {
            Text("Your account and data will be permanently deleted in \(DeletionRequest.softWindowDays) days. You can cancel any time before then. Financial records are retained as required by law.")
        }
        .sheet(item: $viewModel.exportedFileURL) { url in
            ShareSheet(activityItems: [url])
        }
        .sheet(item: $viewModel.exportedPDF) { pdf in
            ShareSheet(activityItems: [pdf.url])
        }
    }

    private func consentDisplayName(_ purpose: String) -> String {
        switch purpose {
        case ManageConsentUseCase.liabilityWaiverPurpose: return "Liability waiver"
        case "location_tracking": return "Location tracking"
        default: return purpose.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

#Preview {
    NavigationStack { PrivacyConsentView().environment(SessionStore()) }
}
