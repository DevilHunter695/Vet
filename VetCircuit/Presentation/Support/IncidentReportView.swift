import SwiftUI

/// L5: safety-specific reporting, separate from `ContactSupportView`'s
/// billing/service-dispute flow — see the doc comment on `IncidentReport`.
@Observable
@MainActor
final class IncidentReportViewModel {
    var type: IncidentReport.IncidentType = .safetyConcern
    var description: String = ""
    var isSubmitting = false
    var errorMessage: String?
    var didSubmit = false

    let visitId: UUID
    private let useCase = DependencyContainer.shared.fileIncidentReportUseCase()

    init(visitId: UUID) { self.visitId = visitId }

    func submit(reporterId: UUID, reporterRole: IncidentReport.ReporterRole) async {
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            _ = try await useCase.execute(visitId: visitId, reporterId: reporterId, reporterRole: reporterRole,
                                           type: type, description: description)
            Haptics.success()
            didSubmit = true
        } catch {
            Haptics.error()
            errorMessage = error.localizedDescription
        }
    }
}

struct IncidentReportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionStore.self) private var session
    @State private var viewModel: IncidentReportViewModel

    init(visitId: UUID) { _viewModel = State(initialValue: IncidentReportViewModel(visitId: visitId)) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("This goes to our safety team, not the general support queue.", systemImage: "shield.lefthalf.filled")
                        .font(.brandCaption)
                        .foregroundStyle(.secondary)
                }
                Section("What happened") {
                    Picker("Type", selection: $viewModel.type) {
                        ForEach(IncidentReport.IncidentType.allCases.filter { $0 != .sos }, id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                }
                Section("Details") {
                    TextField("Describe what happened", text: $viewModel.description, axis: .vertical)
                        .lineLimit(5...10)
                }
                if let errorMessage = viewModel.errorMessage {
                    ErrorBanner(message: errorMessage)
                }
            }
            .navigationTitle("Report an incident")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                PrimaryButton(title: "Submit report", isLoading: viewModel.isSubmitting) {
                    Task { if let user = session.currentUser { await viewModel.submit(reporterId: user.id, reporterRole: .customer) } }
                }
                .padding()
                .background(.regularMaterial)
                .disabled(viewModel.didSubmit)
            }
            .onChange(of: viewModel.didSubmit) { _, submitted in
                guard submitted else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { dismiss() }
            }
        }
    }
}

#Preview {
    IncidentReportView(visitId: UUID()).environment(SessionStore())
}
