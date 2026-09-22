import SwiftUI

@Observable
@MainActor
final class RescheduleVisitViewModel {
    let visit: Visit
    var availableSlots: [ScheduleSlot] = []
    var selectedSlot: ScheduleSlot?
    var isLoading = false
    var isSaving = false
    var errorMessage: String?
    var rescheduled = false

    private let circuitRepository = DependencyContainer.shared.circuitRepository
    private let rescheduleVisitUseCase = DependencyContainer.shared.rescheduleVisitUseCase()

    init(visit: Visit) { self.visit = visit }

    func loadSlots() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let circuit = try await circuitRepository.circuit(id: visit.circuitId)
            availableSlots = circuit.schedule.filter { $0.isBookable() }
        } catch {
            errorMessage = UserFacingError.message(for: error)
        }
    }

    func confirm() async {
        guard let selectedSlot else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            _ = try await rescheduleVisitUseCase.execute(visitId: visit.id, currentScheduledAt: visit.scheduledAt, newSlot: selectedSlot)
            Haptics.success()
            rescheduled = true
        } catch {
            Haptics.error()
            errorMessage = UserFacingError.message(for: error)
        }
    }
}

/// F3: reschedule with the same policy window as cancellation (plan §F3) —
/// the visit keeps its identity (history, chat thread) rather than being
/// cancelled and rebooked from scratch.
struct RescheduleVisitView: View {
    @State private var viewModel: RescheduleVisitViewModel
    @Environment(\.dismiss) private var dismiss

    init(visit: Visit) { _viewModel = State(initialValue: RescheduleVisitViewModel(visit: visit)) }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading {
                    ProgressView()
                } else if viewModel.availableSlots.isEmpty {
                    EmptyStateView(systemImage: "calendar.badge.exclamationmark", title: "No other slots available",
                                   message: "This circuit has no other open slots right now.")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Pick a new time").font(.brandHeadline)
                            ForEach(viewModel.availableSlots) { slot in
                                Button {
                                    Haptics.selection()
                                    withAnimation(Theme.springQuick) { viewModel.selectedSlot = slot }
                                } label: {
                                    HStack {
                                        Text(slot.startTime.formatted(date: .abbreviated, time: .shortened)).font(.brandBody)
                                        Spacer()
                                    }
                                    .padding()
                                    .background(.background, in: RoundedRectangle(cornerRadius: Spacing.corner, style: .continuous))
                                }
                                .buttonStyle(PressableStyle())
                                .selectable(isSelected: viewModel.selectedSlot?.id == slot.id)
                            }

                            if let errorMessage = viewModel.errorMessage {
                                ErrorBanner(message: errorMessage)
                            }

                            PrimaryButton(title: "Confirm new time", isLoading: viewModel.isSaving) {
                                Task { await viewModel.confirm() }
                            }
                            .disabled(viewModel.selectedSlot == nil)
                        }
                        .padding()
                    }
                }
            }
            .auroraScreenBackground()
        .floatingTabBarInset()
            .navigationTitle("Reschedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task { await viewModel.loadSlots() }
            .onChange(of: viewModel.rescheduled) { _, rescheduled in if rescheduled { dismiss() } }
        }
    }
}

#Preview {
    RescheduleVisitView(visit: MockData.visits.first ?? Visit(
        id: UUID(), userId: UUID(), petId: UUID(), vetId: UUID(), circuitId: MockData.circuits[0].id,
        status: .confirmed, scheduledAt: .now.addingTimeInterval(86_400), completedAt: nil, notes: nil, paymentId: nil
    ))
}
