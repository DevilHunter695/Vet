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

    func load(subscriptionId: UUID) async {
        assignments = (try? await useCase.list(subscriptionId: subscriptionId)) ?? []
    }

    func assign(subscriptionId: UUID, seatCount: Int) async {
        errorMessage = nil
        do {
            let assignment = try await useCase.assign(subscriptionId: subscriptionId, phone: phoneInput, seatCount: seatCount)
            assignments.append(assignment)
            phoneInput = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func unassign(_ assignment: CorporateSeatAssignment) async {
        do {
            try await useCase.unassign(id: assignment.id)
            assignments.removeAll { $0.id == assignment.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct CorporateSeatAssignmentView: View {
    let subscription: Subscription
    @State private var viewModel = CorporateSeatAssignmentViewModel()

    var body: some View {
        List {
            Section {
                Text("\(viewModel.assignments.count) of \(subscription.seatCount) seats assigned")
                    .font(.brandCaption).foregroundStyle(.secondary)
            }

            Section("Assign a seat") {
                HStack {
                    TextField("Phone number", text: $viewModel.phoneInput)
                        .keyboardType(.phonePad)
                    Button("Assign") {
                        Haptics.tap()
                        Task { await viewModel.assign(subscriptionId: subscription.id, seatCount: subscription.seatCount) }
                    }
                    .disabled(viewModel.phoneInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage).font(.brandCaption).foregroundStyle(Theme.danger)
                }
            }

            Section("Assigned") {
                ForEach(viewModel.assignments) { assignment in
                    HStack {
                        Text(assignment.assignedPhone)
                        Spacer()
                        Button(role: .destructive) {
                            Haptics.warning()
                            Task { await viewModel.unassign(assignment) }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                    }
                }
            }
        }
        // The aurora is the app's ground everywhere else; a List that keeps
        // its own opaque system background would read as a different app.
        .scrollContentBackground(.hidden)
        .auroraScreenBackground()
        .navigationTitle("Seat assignments")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load(subscriptionId: subscription.id) }
    }
}

#Preview {
    NavigationStack {
        CorporateSeatAssignmentView(subscription: Subscription(id: UUID(), userId: UUID(), planType: .corporate, status: .active, renewalDate: .now, seatCount: 10))
    }
}
