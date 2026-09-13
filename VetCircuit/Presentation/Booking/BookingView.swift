import SwiftUI
import UIKit

@Observable
@MainActor
final class BookingViewModel {
    let circuit: Circuit
    var pets: [Pet] = []
    var selectedPet: Pet?
    var selectedSlot: ScheduleSlot?
    var isLoading = false
    var errorMessage: String?
    var bookedVisit: Visit?

    private let bookVisitUseCase = DependencyContainer.shared.bookVisitUseCase()
    private let managePetsUseCase = DependencyContainer.shared.managePetsUseCase()

    init(circuit: Circuit) { self.circuit = circuit }

    func loadPets(ownerId: UUID) async {
        do {
            pets = try await managePetsUseCase.list(ownerId: ownerId)
            selectedPet = pets.first
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// One primary action per screen: confirm the booking once pet + slot are chosen.
    func confirmBooking() async {
        guard let pet = selectedPet, let slot = selectedSlot else {
            errorMessage = "Choose a pet and a time slot to continue."
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            bookedVisit = try await bookVisitUseCase.execute(
                petId: pet.id, vetId: circuit.vetId, circuitId: circuit.id, slot: slot
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct BookingView: View {
    @Environment(SessionStore.self) private var session
    @State private var viewModel: BookingViewModel

    init(circuit: Circuit) {
        _viewModel = State(initialValue: BookingViewModel(circuit: circuit))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(viewModel.circuit.vet?.name ?? "Veterinarian").font(.title3.bold())
                        Text(viewModel.circuit.clusterArea).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Which pet?").font(.headline)
                    if viewModel.pets.isEmpty {
                        Text("Add a pet in your profile first.").foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(viewModel.pets.enumerated()), id: \.element.id) { index, pet in
                            SelectableRow(title: "\(pet.name) · \(pet.species.rawValue.capitalized)",
                                          isSelected: viewModel.selectedPet?.id == pet.id) {
                                viewModel.selectedPet = pet
                            }
                            .appearAnimation(delay: Theme.staggerDelay(index))
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Pick a time slot").font(.headline)
                    ForEach(Array(viewModel.circuit.schedule.filter(\.isAvailable).enumerated()), id: \.element.id) { index, slot in
                        SelectableRow(
                            title: slot.startTime.formatted(date: .abbreviated, time: .shortened),
                            subtitle: "\(slot.remainingCapacity) spot\(slot.remainingCapacity == 1 ? "" : "s") left",
                            isSelected: viewModel.selectedSlot?.id == slot.id
                        ) {
                            viewModel.selectedSlot = slot
                        }
                        .appearAnimation(delay: Theme.staggerDelay(index))
                    }
                }

                if let errorMessage = viewModel.errorMessage {
                    ErrorBanner(message: errorMessage)
                }

                PrimaryButton(title: "Confirm booking", isLoading: viewModel.isLoading) {
                    Task { await viewModel.confirmBooking() }
                }
            }
            .padding()
        }
        .navigationTitle("Book visit")
        .navigationBarTitleDisplayMode(.inline)
        .task { if let user = session.currentUser { await viewModel.loadPets(ownerId: user.id) } }
        .navigationDestination(item: $viewModel.bookedVisit) { visit in
            BookingConfirmedView(visit: visit)
        }
    }
}

private struct SelectableRow: View {
    let title: String
    var subtitle: String? = nil
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.selection()
            withAnimation(Theme.springQuick) { action() }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.brandBody)
                    if let subtitle {
                        Text(subtitle).font(.brandCaption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.primary)
                    .opacity(isSelected ? 1 : 0)
                    .scaleEffect(isSelected ? 1 : 0.5)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isSelected ? AnyShapeStyle(Theme.accentSoft) : AnyShapeStyle(Color(.secondarySystemBackground)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(isSelected ? Theme.primary.opacity(0.4) : .clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(PressableStyle())
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

struct BookingConfirmedView: View {
    let visit: Visit
    @State private var checkmarkScale: CGFloat = 0.4
    @State private var ringOpacity: Double = 0

    var body: some View {
        ZStack {
            ConfettiView()

            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .stroke(Color.green.opacity(0.25), lineWidth: 8)
                        .frame(width: 96, height: 96)
                        .scaleEffect(ringOpacity == 0 ? 0.6 : 1.3)
                        .opacity(1 - ringOpacity)

                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 68))
                        .foregroundStyle(.green)
                        .scaleEffect(checkmarkScale)
                }
                .onAppear {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.55)) { checkmarkScale = 1 }
                    withAnimation(.easeOut(duration: 0.9).delay(0.1)) { ringOpacity = 1 }
                }

                Text("Booking requested!").font(.brandTitle).brandDisplayText()
                Text("We'll notify you once the vet confirms your slot.")
                    .font(.brandBody)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                StatusBadge(status: visit.status)
            }
            .padding()
            .appearAnimation()
        }
        .navigationBarBackButtonHidden()
    }
}

#Preview {
    NavigationStack {
        BookingView(circuit: MockData.circuits[0]).environment(SessionStore())
    }
}
