import Testing
import Foundation
@testable import VetCircuit

// Four features that FEATURE_STATUS.md listed as "built, nothing tests it".
//
// That status is the most dangerous one on the list — worse than a known gap,
// because the code looks finished. Every inert feature this codebase has
// shipped sat in exactly this state. These four are testable without a device
// or a backend, so there is no excuse for leaving them there. (A10 Face ID,
// C7/I4 map rendering and N5's rating prompt are genuinely platform-bound and
// stay 🟠 until someone runs them on hardware.)

@Suite("A11 blocked/deactivated account gate")
struct AccountGateTests {
    private func user(_ status: User.AccountStatus) -> User {
        User(id: UUID(), phone: "+919845012345", name: "Aanya Sharma", email: nil,
             createdAt: .now, pets: [], accountStatus: status)
    }

    @Test("an active account is let into the app")
    func activeIsAllowed() {
        #expect(user(.active).isLockedOut == false)
    }

    @Test("a blocked account is held at the gate")
    func blockedIsHeld() {
        #expect(user(.blocked).isLockedOut)
    }

    @Test("a deactivated account is held at the gate")
    func deactivatedIsHeld() {
        #expect(user(.deactivated).isLockedOut)
    }

    /// The point of `isLockedOut` being a `switch` rather than `!= .active`:
    /// if someone adds `.underReview` tomorrow, this test fails loudly rather
    /// than the new status quietly being let through.
    @Test("every status is a deliberate decision, not a default")
    func everyStatusIsDecided() {
        let lockedOut = User.AccountStatus.allCases.filter { user($0).isLockedOut }
        #expect(lockedOut.count == User.AccountStatus.allCases.count - 1,
                "A new AccountStatus was added without deciding whether it locks the user out")
    }
}

@Suite("C9 recently viewed")
struct RecentlyViewedTests {
    /// A private suite-scoped UserDefaults, so these never touch the
    /// simulator's real defaults or each other.
    @MainActor
    private func freshStore() -> RecentlyViewedStore {
        let suiteName = "vc.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return RecentlyViewedStore(defaults: defaults)
    }

    @MainActor
    @Test("a viewed circuit is remembered, most recent first")
    func recordsMostRecentFirst() {
        let store = freshStore()
        let first = UUID(), second = UUID()
        store.recordView(circuitId: first)
        store.recordView(circuitId: second)
        #expect(store.circuitIds == [second, first])
    }

    @MainActor
    @Test("viewing the same circuit again moves it to the front, it doesn't duplicate")
    func revisitingDeduplicates() {
        let store = freshStore()
        let a = UUID(), b = UUID()
        store.recordView(circuitId: a)
        store.recordView(circuitId: b)
        store.recordView(circuitId: a)
        #expect(store.circuitIds == [a, b], "A revisit duplicated the entry instead of promoting it")
    }

    @MainActor
    @Test("the history is capped, so browsing all day doesn't grow forever")
    func capsTheHistory() {
        let store = freshStore()
        for _ in 0..<25 { store.recordView(circuitId: UUID()) }
        #expect(store.circuitIds.count == 10)
    }

    /// The resolve step must drop ids whose circuit is no longer in the
    /// loaded list — a vet who left the platform must not crash the row or
    /// render as a blank card.
    @MainActor
    @Test("ids with no matching circuit are dropped, not rendered blank")
    func dropsUnresolvableIds() {
        let store = freshStore()
        let present = MockData.circuits[0]
        store.recordView(circuitId: UUID())       // gone from the platform
        store.recordView(circuitId: present.id)
        let resolved = store.recentCircuits(from: MockData.circuits)
        #expect(resolved.map(\.id) == [present.id])
    }
}

@Suite("G4 refunds")
struct RefundIssuanceTests {
    @Test("issuing a refund records it against the visit")
    func issuingRecordsIt() async throws {
        let repo = MockRefundRepository()
        let visitId = UUID(), paymentId = UUID()

        let refund = try await repo.issueRefund(
            visitId: visitId, paymentId: paymentId, amountMinorUnits: 59_900,
            reason: "Cancelled outside the free window", initiatedByOpsUserId: nil
        )

        #expect(refund.amountMinorUnits == 59_900)
        #expect(refund.visitId == visitId)
        let recorded = try await repo.refunds(visitId: visitId)
        #expect(recorded.map(\.id) == [refund.id])
    }

    /// The distinction the protocol exists to carry: an ops-initiated refund
    /// is attributable to a person, a policy-driven one is not. Losing that
    /// makes a support refund indistinguishable from an automatic one.
    @Test("an ops-initiated refund keeps the initiator; an automatic one has none")
    func attributionIsPreserved() async throws {
        let repo = MockRefundRepository()
        let visitId = UUID()
        let opsUserId = UUID()

        _ = try await repo.issueRefund(visitId: visitId, paymentId: UUID(), amountMinorUnits: 10_000,
                                       reason: "Goodwill", initiatedByOpsUserId: opsUserId)
        _ = try await repo.issueRefund(visitId: visitId, paymentId: UUID(), amountMinorUnits: 20_000,
                                       reason: "Cancellation policy", initiatedByOpsUserId: nil)

        let refunds = try await repo.refunds(visitId: visitId)
        #expect(refunds.count == 2)
        #expect(refunds.contains { $0.initiatedByOpsUserId == opsUserId })
        #expect(refunds.contains { $0.initiatedByOpsUserId == nil })
    }

    @Test("refunds for one visit never leak into another's")
    func refundsAreScopedToTheirVisit() async throws {
        let repo = MockRefundRepository()
        let mine = UUID(), theirs = UUID()
        _ = try await repo.issueRefund(visitId: mine, paymentId: UUID(), amountMinorUnits: 1_000,
                                       reason: "x", initiatedByOpsUserId: nil)
        let other = try await repo.refunds(visitId: theirs)
        #expect(other.isEmpty)
    }
}

@Suite("O8 maintenance mode")
struct MaintenanceModeTests {
    private func gate(config: RemoteAppConfig, currentVersion: String = "1.0") async -> CheckAppConfigUseCase.Gate {
        let repo = MockAppConfigRepository()
        await repo.setConfig(config)
        return await CheckAppConfigUseCase(repository: repo).execute(currentVersion: currentVersion)
    }

    @Test("maintenance mode closes the app and carries its message")
    func maintenanceClosesTheApp() async {
        let result = await gate(config: RemoteAppConfig(
            minSupportedVersion: "1.0", isMaintenanceMode: true,
            maintenanceMessage: "We're upgrading the booking system — back by 6pm IST."
        ))
        guard case .maintenance(let message) = result else {
            Issue.record("Maintenance mode did not close the app: \(result)")
            return
        }
        #expect(message == "We're upgrading the booking system — back by 6pm IST.")
    }

    /// Maintenance must win over a force-upgrade: telling someone to go to the
    /// App Store during an outage sends them to update an app that still
    /// won't work.
    @Test("maintenance takes precedence over a force-upgrade")
    func maintenanceBeatsForceUpgrade() async {
        let result = await gate(
            config: RemoteAppConfig(minSupportedVersion: "9.9", isMaintenanceMode: true, maintenanceMessage: nil),
            currentVersion: "1.0"
        )
        guard case .maintenance = result else {
            Issue.record("A force-upgrade was shown during an outage: \(result)")
            return
        }
    }

    @Test("with maintenance off and a supported version, the app opens normally")
    func normallyTheAppOpens() async {
        let result = await gate(config: RemoteAppConfig(
            minSupportedVersion: "1.0", isMaintenanceMode: false, maintenanceMessage: nil
        ))
        guard case .ok = result else {
            Issue.record("The app was gated when it should have opened: \(result)")
            return
        }
    }
}

/// The composition root's backend branch. This is the seam a deployment turns
/// on, so it is worth a test that it resolves at all and reports honestly
/// which side it landed on — a build that silently serves mock data while
/// believing it is connected is the expensive version of this going wrong.
@Suite("DependencyContainer backend selection")
struct BackendSelectionTests {
    @MainActor
    @Test("with no credentials in the bundle, the container resolves to mocks and says so")
    func resolvesToMockWithoutCredentials() {
        #expect(AppConfig.isBackendConfigured == false,
                "The test bundle should carry no Supabase credentials")
        #expect(DependencyContainer.shared.backendMode == .mock)
    }

    /// The nine are named in the container so whoever deploys knows exactly
    /// which surfaces still serve mock data in a credentialed build. If a
    /// Supabase conformer is written for one of them, this fails and the list
    /// gets corrected rather than quietly going stale.
    @MainActor
    @Test("the mock-only repositories are still the nine that have no Supabase conformer")
    func mockOnlyListIsCurrent() {
        #expect(DependencyContainer.mockOnlyRepositories.count == 9)
        #expect(DependencyContainer.mockOnlyRepositories.contains("ChatRepository"))
        #expect(DependencyContainer.mockOnlyRepositories.contains("PaymentRepository"))
    }
}

/// D6 was the last functional gap I had named and not closed: a cart line
/// could carry several pets and be *priced* for them, but the visit it booked
/// recorded exactly one. The customer paid a second-pet fee and got a booking
/// that said one pet.
@Suite("D6 multi-pet in one visit")
struct MultiPetVisitTests {
    private func futureSlot() -> ScheduleSlot {
        let start = Calendar.current.date(byAdding: .day, value: 2, to: .now) ?? .now
        return ScheduleSlot(id: UUID(), dayOfWeek: 3, startTime: start,
                            endTime: start.addingTimeInterval(3600), capacity: 5, bookedCount: 0)
    }

    @Test("a booking for three pets records all three")
    func recordsEveryPet() async throws {
        let repo = MockVisitRepository()
        let bruno = UUID(), miso = UUID(), kiwi = UUID()

        let visit = try await BookVisitUseCase(visitRepository: repo).execute(
            petId: bruno, additionalPetIds: [miso, kiwi],
            vetId: UUID(), circuitId: UUID(), slot: futureSlot()
        )

        #expect(visit.petId == bruno, "The primary pet must stay the primary pet")
        #expect(visit.additionalPetIds == [miso, kiwi])
        #expect(visit.allPetIds == [bruno, miso, kiwi])
    }

    @Test("a single-pet booking is written exactly as it always was")
    func singlePetIsUnchanged() async throws {
        let repo = MockVisitRepository()
        let visit = try await BookVisitUseCase(visitRepository: repo).execute(
            petId: UUID(), vetId: UUID(), circuitId: UUID(), slot: futureSlot()
        )
        #expect(visit.additionalPetIds.isEmpty)
        #expect(visit.allPetIds.count == 1)
    }

    /// The same pet listed twice would be charged twice by
    /// `PricingEngine.additionalPetCount` and read as a data error to anyone
    /// looking at the visit, so the use case normalises rather than trusting
    /// callers to have deduplicated their cart line.
    @Test("a pet repeated in the list is not booked or charged twice")
    func deduplicates() async throws {
        let repo = MockVisitRepository()
        let bruno = UUID(), miso = UUID()

        let visit = try await BookVisitUseCase(visitRepository: repo).execute(
            petId: bruno, additionalPetIds: [miso, bruno, miso],
            vetId: UUID(), circuitId: UUID(), slot: futureSlot()
        )

        #expect(visit.additionalPetIds == [miso])
        #expect(visit.allPetIds == [bruno, miso])
    }

    @Test("the primary pet appearing in the companion list does not duplicate it")
    func primaryIsNeverAlsoACompanion() async throws {
        let repo = MockVisitRepository()
        let bruno = UUID()
        let visit = try await BookVisitUseCase(visitRepository: repo).execute(
            petId: bruno, additionalPetIds: [bruno],
            vetId: UUID(), circuitId: UUID(), slot: futureSlot()
        )
        #expect(visit.additionalPetIds.isEmpty)
    }
}
