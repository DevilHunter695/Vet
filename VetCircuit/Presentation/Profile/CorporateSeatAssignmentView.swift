import SwiftUI

/// H7: assign a corporate/RWA subscription's billed seats to specific
/// phone numbers — mirrors `HouseholdView`'s "invite by phone" shape.
@Observable
@MainActor
final class CorporateSeatAssignmentViewModel {
    var assignments: [CorporateSeatAssignment] = []
    var phoneInput = ""
    var errorMessage: String?

    private let useCase = DependencyContainer.shared.manageCorporateSeatsUseCase()

    var isLoading = false

    func load(subscriptionId: UUID) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            assignments = try await useCase.list(subscriptionId: subscriptionId)
        } catch {
            // Silently swallowing this left the screen claiming zero seats
            // were assigned when the fetch had simply failed.
            errorMessage = "Couldn't load seat assignments. \(UserFacingError.message(for: error))"
        }
    }

    func assign(subscriptionId: UUID, seatCount: Int) async {
        errorMessage = nil
        do {
            let assignment = try await useCase.assign(subscriptionId: subscriptionId, phone: phoneInput, seatCount: seatCount)
            assignments.append(assignment)
            phoneInput = ""
        } catch {
            errorMessage = UserFacingError.message(for: error)
        }
    }

    func unassign(_ assignment: CorporateSeatAssignment) async {
        do {
            try await useCase.unassign(id: assignment.id)
            assignments.removeAll { $0.id == assignment.id }
        } catch {
            errorMessage = UserFacingError.message(for: error)
        }
    }
}

struct CorporateSeatAssignmentView: View {
    let subscription: Subscription
    @State private var viewModel = CorporateSeatAssignmentViewModel()
    @State private var pendingUnassign: CorporateSeatAssignment?

    var body: some View {
        List {
            Section {
                Text("\(viewModel.assignments.count) of \(subscription.seatCount) seats assigned")
                    .font(.brandCaption).foregroundStyle(Theme.textSecondary)
            }

            Section("Assign a seat") {
                // Above the field, not below: an error under the keyboard is
                // an error nobody reads.
                if let errorMessage = viewModel.errorMessage {
                    ErrorBanner(message: errorMessage)
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                        .listRowBackground(Color.clear)
                }
                HStack {
                    TextField("Phone number", text: $viewModel.phoneInput)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                    Button("Assign") {
                        Haptics.tap()
                        Task { await viewModel.assign(subscriptionId: subscription.id, seatCount: subscription.seatCount) }
                    }
                    .disabled(viewModel.phoneInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Section("Assigned") {
                if viewModel.isLoading && viewModel.assignments.isEmpty {
                    ForEach(0..<3, id: \.self) { _ in
                        ShimmerView(cornerRadius: 10).frame(height: 28)
                    }
                } else {
                    ForEach(viewModel.assignments) { assignment in
                        HStack {
                            Text(assignment.assignedPhone)
                            Spacer()
                            // A List row with exactly one Button and no
                            // buttonStyle makes the *whole row* fire it — so
                            // tapping the phone number used to revoke a seat.
                            Button(role: .destructive) {
                                Haptics.warning()
                                pendingUnassign = assignment
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .frame(minWidth: 44, minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        // The aurora is the app's ground everywhere else; a List that keeps
        // its own opaque system background would read as a different app.
        .scrollContentBackground(.hidden)
        .auroraScreenBackground()
        .floatingTabBarInset()
        .navigationTitle("Seat assignments")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load(subscriptionId: subscription.id) }
        .confirmationDialog(
            "Remove this seat?",
            isPresented: Binding(get: { pendingUnassign != nil }, set: { if !$0 { pendingUnassign = nil } }),
            titleVisibility: .visible
        ) {
            if let pendingUnassign {
                Button("Remove \(pendingUnassign.assignedPhone)", role: .destructive) {
                    let assignment = pendingUnassign
                    self.pendingUnassign = nil
                    Task { await viewModel.unassign(assignment) }
                }
            }
            Button("Keep seat", role: .cancel) { pendingUnassign = nil }
        } message: {
            Text("They'll immediately lose access to the corporate plan's benefits.")
        }
    }
}

#Preview {
    NavigationStack {
        CorporateSeatAssignmentView(subscription: Subscription(id: UUID(), userId: UUID(), planType: .corporate, status: .active, renewalDate: .now, seatCount: 10))
    }
}
