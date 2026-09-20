import SwiftUI

/// M2: "Contact support" → a ticket. K8 (P0): the same form, pre-filled and
/// carrying `visitId`, is how "Report a problem with this visit" works —
/// there is no separate dispute flow, just this ticket with visit context.
@Observable
@MainActor
final class ContactSupportViewModel {
    var subject: String
    var body: String
    var isSubmitting = false
    var errorMessage: String?
    var didSubmit = false

    let visitId: UUID?
    private let contactSupportUseCase = DependencyContainer.shared.contactSupportUseCase()

    init(visitId: UUID? = nil, subject: String = "", body: String = "") {
        self.visitId = visitId
        self.subject = subject
        self.body = body
    }

    func submit(userId: UUID) async {
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            _ = try await contactSupportUseCase.execute(userId: userId, visitId: visitId, subject: subject, body: body)
            Haptics.success()
            didSubmit = true
        } catch {
            Haptics.error()
            errorMessage = UserFacingError.message(for: error)
        }
    }
}

struct ContactSupportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionStore.self) private var session
    @State private var viewModel: ContactSupportViewModel

    init(visitId: UUID? = nil, subjectPlaceholder: String = "") {
        _viewModel = State(initialValue: ContactSupportViewModel(visitId: visitId, subject: subjectPlaceholder))
    }

    var body: some View {
        NavigationStack {
            Form {
                if viewModel.visitId != nil {
                    Section {
                        Label("This ticket is attached to your visit.", systemImage: "link")
                            .font(.brandCaption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                Section("Subject") {
                    TextField("What's this about?", text: $viewModel.subject)
                }
                Section("Details") {
                    TextField("Describe what happened", text: $viewModel.body, axis: .vertical)
                        .lineLimit(5...10)
                }
                if let errorMessage = viewModel.errorMessage {
                    ErrorBanner(message: errorMessage)
                }
            }
            // The aurora is the app's ground everywhere else; a List that keeps
            // its own opaque system background would read as a different app.
            .scrollContentBackground(.hidden)
            .auroraScreenBackground()
            .navigationTitle(viewModel.visitId != nil ? "Report a problem" : "Contact support")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                PrimaryButton(title: "Submit", isLoading: viewModel.isSubmitting) {
                    Task { if let user = session.currentUser { await viewModel.submit(userId: user.id) } }
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
    ContactSupportView().environment(SessionStore())
}
