import Testing
import Foundation
@testable import VetCircuit

// D4: package redemption tracking — the pure policy in isolation, plus an
// end-to-end pass through the real BuyPackageUseCase -> BookVisitUseCase
// pipeline this gap was about ("3 of 4 visits used" derived from actual
// bookings, not a static purchased/expanded flag).

@Suite("PackageRedemptionPolicy")
struct PackageRedemptionPolicyTests {
    private func makeRedemption(total: Int, used: Int) -> PackageRedemption {
        PackageRedemption(id: UUID(), userId: UUID(), packageId: UUID(), packageItemId: UUID(),
                           serviceId: UUID(), totalCount: total, usedCount: used)
    }

    @Test("a redemption with slots left can be redeemed")
    func canRedeemWithSlotsLeft() {
        let redemption = makeRedemption(total: 4, used: 2)
        #expect(PackageRedemptionPolicy.canRedeem(redemption))
    }

    @Test("a fully-used redemption cannot be redeemed")
    func cannotRedeemExhausted() {
        let redemption = makeRedemption(total: 4, used: 4)
        #expect(!PackageRedemptionPolicy.canRedeem(redemption))
    }

    @Test("redeeming increments usedCount by exactly one")
    func redeemIncrementsUsedCount() throws {
        let redemption = makeRedemption(total: 4, used: 1)
        let updated = try PackageRedemptionPolicy.redeem(redemption)
        #expect(updated.usedCount == 2)
        #expect(updated.remainingCount == 2)
    }

    @Test("redeeming an exhausted entitlement throws rather than over-redeeming")
    func redeemExhaustedThrows() {
        let redemption = makeRedemption(total: 4, used: 4)
        #expect(throws: DomainError.self) {
            _ = try PackageRedemptionPolicy.redeem(redemption)
        }
    }

    @Test("progress label reads '<used> of <total> used'")
    func progressLabel() {
        let redemption = makeRedemption(total: 4, used: 3)
        #expect(PackageRedemptionPolicy.progressLabel(redemption) == "3 of 4 used")
    }
}

@Suite("BuyPackageUseCase + BookVisitUseCase redemption pipeline")
struct PackageRedemptionPipelineTests {
    @Test("buying a package creates one redemption per package item, matching its quantity")
    func buyingCreatesRedemptions() async throws {
        let packageRepository = MockPackageRepository()
        let catalogRepository = MockCatalogRepository()
        let cartRepository = MockCartRepository()
        let useCase = BuyPackageUseCase(packageRepository: packageRepository, catalogRepository: catalogRepository, cartRepository: cartRepository)
        let package = try #require(MockData.packages.first)
        let userId = MockData.user.id
        let petId = try #require(MockData.user.pets.first?.id)

        let cart = try await useCase.execute(packageId: package.id, petIds: [petId], userId: userId)

        let redemptions = try await packageRepository.redemptions(userId: userId)
        #expect(redemptions.count == package.items.count)
        for item in package.items {
            let redemption = try #require(redemptions.first { $0.packageItemId == item.id })
            #expect(redemption.totalCount == item.quantity)
            #expect(redemption.usedCount == 0)
        }
        // Every expanded cart line for a given package item carries that
        // item's redemption id, so a later booking knows what to redeem.
        for item in cart.items {
            #expect(item.packageRedemptionId != nil)
        }
    }

    @Test("booking a visit against a package redemption advances its usedCount")
    func bookingAdvancesUsedCount() async throws {
        let packageRepository = MockPackageRepository()
        let visitRepository = MockVisitRepository(packageRepository: packageRepository)
        let bookVisitUseCase = BookVisitUseCase(visitRepository: visitRepository)

        let redemption = try await packageRepository.createRedemption(
            userId: MockData.user.id, packageId: UUID(), packageItemId: UUID(), serviceId: UUID(), totalCount: 4
        )
        let slot = ScheduleSlot(id: UUID(), dayOfWeek: 2, startTime: .now.addingTimeInterval(3600),
                                 endTime: .now.addingTimeInterval(7200), capacity: 3, bookedCount: 0)

        let visit = try await bookVisitUseCase.execute(
            petId: UUID(), vetId: UUID(), circuitId: UUID(), slot: slot,
            packageRedemptionId: redemption.id
        )

        #expect(visit.packageRedemptionId == redemption.id)
        let updated = try await packageRepository.redemption(id: redemption.id)
        #expect(updated.usedCount == 1)
        #expect(PackageRedemptionPolicy.progressLabel(updated) == "1 of 4 used")
    }

    @Test("booking against an exhausted redemption fails without creating the visit")
    func bookingAgainstExhaustedRedemptionFails() async throws {
        let packageRepository = MockPackageRepository()
        let visitRepository = MockVisitRepository(packageRepository: packageRepository)
        let bookVisitUseCase = BookVisitUseCase(visitRepository: visitRepository)

        let redemption = try await packageRepository.createRedemption(
            userId: MockData.user.id, packageId: UUID(), packageItemId: UUID(), serviceId: UUID(), totalCount: 1
        )
        let firstSlot = ScheduleSlot(id: UUID(), dayOfWeek: 2, startTime: .now.addingTimeInterval(3600),
                                      endTime: .now.addingTimeInterval(7200), capacity: 3, bookedCount: 0)
        _ = try await bookVisitUseCase.execute(
            petId: UUID(), vetId: UUID(), circuitId: UUID(), slot: firstSlot, packageRedemptionId: redemption.id
        )

        let secondSlot = ScheduleSlot(id: UUID(), dayOfWeek: 3, startTime: .now.addingTimeInterval(3600 * 24),
                                       endTime: .now.addingTimeInterval(3600 * 25), capacity: 3, bookedCount: 0)
        await #expect(throws: DomainError.self) {
            _ = try await bookVisitUseCase.execute(
                petId: UUID(), vetId: UUID(), circuitId: UUID(), slot: secondSlot, packageRedemptionId: redemption.id
            )
        }
        let updated = try await packageRepository.redemption(id: redemption.id)
        #expect(updated.usedCount == 1, "the second, rejected booking must not have advanced usedCount further")
    }

    @Test("GetMyPackageRedemptionsUseCase reflects usedCount across multiple bookings")
    func getMyPackageRedemptionsReflectsBookings() async throws {
        let packageRepository = MockPackageRepository()
        let catalogRepository = MockCatalogRepository()
        let visitRepository = MockVisitRepository(packageRepository: packageRepository)
        let bookVisitUseCase = BookVisitUseCase(visitRepository: visitRepository)
        let getMyPackageRedemptionsUseCase = GetMyPackageRedemptionsUseCase(packageRepository: packageRepository, catalogRepository: catalogRepository)

        let service = try #require(MockData.services.first)
        let redemption = try await packageRepository.createRedemption(
            userId: MockData.user.id, packageId: UUID(), packageItemId: UUID(), serviceId: service.id, totalCount: 4
        )

        for offset in 0..<3 {
            let slot = ScheduleSlot(id: UUID(), dayOfWeek: 2, startTime: .now.addingTimeInterval(Double(offset + 1) * 3600 * 24),
                                     endTime: .now.addingTimeInterval(Double(offset + 1) * 3600 * 24 + 3600), capacity: 3, bookedCount: 0)
            _ = try await bookVisitUseCase.execute(petId: UUID(), vetId: UUID(), circuitId: UUID(), slot: slot, packageRedemptionId: redemption.id)
        }

        let entitlements = try await getMyPackageRedemptionsUseCase.execute(userId: MockData.user.id)
        let entitlement = try #require(entitlements.first { $0.redemption.id == redemption.id })
        #expect(entitlement.progressLabel == "3 of 4 used")
        #expect(entitlement.serviceName == service.name)
    }
}
