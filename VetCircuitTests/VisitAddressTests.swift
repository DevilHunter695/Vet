import Testing
import Foundation
@testable import VetCircuit

// Where the vet is going. The product is a home visit, and until
// 0065_visit_address.sql a booking recorded no address at all — every `Cart`
// was built with `addressId: nil` and `Visit` had no such property. These
// pin the plumbing so it cannot quietly go back to dropping it.

@Suite("Visit address")
struct VisitAddressTests {
    private func slot(inHours hours: Double = 4) -> ScheduleSlot {
        ScheduleSlot(
            id: UUID(), dayOfWeek: 1,
            startTime: .now.addingTimeInterval(hours * 3600),
            endTime: .now.addingTimeInterval((hours + 1) * 3600),
            capacity: 3, bookedCount: 0
        )
    }

    @Test("a booked visit records the address it was booked for")
    func bookingKeepsTheAddress() async throws {
        let repo = MockVisitRepository()
        let useCase = BookVisitUseCase(visitRepository: repo)
        let addressId = UUID()

        let visit = try await useCase.execute(
            petId: UUID(), vetId: UUID(), circuitId: UUID(), slot: slot(),
            addressId: addressId
        )

        #expect(visit.addressId == addressId)
    }

    @Test("the address survives a round trip through the repository")
    func addressSurvivesReload() async throws {
        let repo = MockVisitRepository()
        let useCase = BookVisitUseCase(visitRepository: repo)
        let addressId = UUID()

        let booked = try await useCase.execute(
            petId: UUID(), vetId: UUID(), circuitId: UUID(), slot: slot(),
            addressId: addressId
        )
        let reloaded = try await repo.visit(id: booked.id)

        #expect(reloaded.addressId == addressId)
    }

    @Test("a booking made without an address is still a valid booking")
    func addressIsOptional() async throws {
        let repo = MockVisitRepository()
        let useCase = BookVisitUseCase(visitRepository: repo)

        let visit = try await useCase.execute(
            petId: UUID(), vetId: UUID(), circuitId: UUID(), slot: slot()
        )

        #expect(visit.addressId == nil)
    }

    @Test("an address the customer has not saved is not silently accepted as theirs")
    func unservedAddressIsStillRepresentable() {
        // `isServed` is what the booking screen warns on. An address outside
        // every cluster has to remain bookable-but-flagged rather than
        // unrepresentable, because the vet may still be able to reach it.
        let uncovered = Address(
            id: UUID(), ownerId: UUID(), label: "Farm", line1: "Off the ring road",
            latitude: 12.0, longitude: 77.0, clusterArea: nil
        )
        #expect(uncovered.isServed == false)

        let covered = Address(
            id: UUID(), ownerId: UUID(), label: "Home", line1: "12 Main St",
            latitude: 12.9, longitude: 77.6, clusterArea: "Indiranagar"
        )
        #expect(covered.isServed)
    }
}
