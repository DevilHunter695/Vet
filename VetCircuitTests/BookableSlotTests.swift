import Testing
import Foundation
@testable import VetCircuit

// What the booking screen is allowed to offer.
//
// `isAvailable` is capacity only. Using it to decide what to show a customer
// is how the slot picker came to list times that had already passed:
// `BookVisitUseCase` rejects those, correctly, but only at the Confirm tap —
// after a pet, an address and a payment method have been chosen. The first
// anyone learned of it was a validation error on the last step of the flow.

@Suite("Bookable slots")
struct BookableSlotTests {
    private func slot(startingIn interval: TimeInterval, capacity: Int = 5, booked: Int = 0) -> ScheduleSlot {
        ScheduleSlot(
            id: UUID(), dayOfWeek: 1,
            startTime: .now.addingTimeInterval(interval),
            endTime: .now.addingTimeInterval(interval + 3_600),
            capacity: capacity, bookedCount: booked
        )
    }

    @Test("a slot that has already started is not bookable, however much capacity it has")
    func pastSlotIsNotBookable() {
        let past = slot(startingIn: -3_600)
        #expect(past.isAvailable, "precondition: it still has capacity")
        #expect(past.isBookable() == false)
    }

    @Test("a slot starting exactly now is not bookable")
    func slotStartingNowIsNotBookable() {
        // This is the case the mock data actually produced, and it is the
        // one a naive `>= now` check would get wrong: by the time anybody
        // taps it, it has started.
        let now = Date()
        let starting = ScheduleSlot(
            id: UUID(), dayOfWeek: 1, startTime: now, endTime: now.addingTimeInterval(3_600),
            capacity: 5, bookedCount: 0
        )
        #expect(starting.isBookable(asOf: now) == false)
    }

    @Test("a full slot in the future is not bookable")
    func fullSlotIsNotBookable() {
        let full = slot(startingIn: 86_400, capacity: 5, booked: 5)
        #expect(full.isBookable() == false)
    }

    @Test("a future slot with capacity is bookable")
    func futureSlotWithCapacityIsBookable() {
        #expect(slot(startingIn: 86_400, capacity: 5, booked: 2).isBookable())
    }

    @Test("every slot the mock circuits offer is actually bookable")
    func mockCircuitsOfferOnlyBookableSlots() {
        // The end-to-end booking UI test taps the first slot it finds. If the
        // fixtures can produce an unbookable one, that test fails for a
        // reason that has nothing to do with the code under test — which is
        // exactly what happened.
        for circuit in MockData.circuits {
            for slot in circuit.schedule where slot.isAvailable {
                #expect(
                    slot.startTime > .now,
                    "circuit \(circuit.clusterArea) offers an available slot in the past"
                )
            }
        }
    }

    @Test("BookVisitUseCase agrees with isBookable about the past")
    func useCaseRejectsWhatIsBookableRejects() async {
        let repo = MockVisitRepository()
        let useCase = BookVisitUseCase(visitRepository: repo)
        let past = slot(startingIn: -3_600)

        await #expect(throws: DomainError.self) {
            _ = try await useCase.execute(
                petId: UUID(), vetId: UUID(), circuitId: UUID(), slot: past
            )
        }
    }
}
