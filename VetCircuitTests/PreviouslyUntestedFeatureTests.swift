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
    @Test("the mock-only repositories are the four that correctly have no Supabase conformer")
    func mockOnlyListIsCurrent() {
        // Four, and none of them is a gap: triage is a rules engine with
        // nothing to store, and the other three are device-local by design.
        #expect(DependencyContainer.mockOnlyRepositories.count == 4)
        #expect(DependencyContainer.mockOnlyRepositories.contains("TriageRepository"))
        #expect(!DependencyContainer.mockOnlyRepositories.contains("LiveTrackingRepository"))
        // Payments left the mock-only list, but only into the partial one —
        // and that distinction is the whole point, because the mock's
        // behaviour in a credentialed build is to report money taken when
        // none was.
        #expect(!DependencyContainer.mockOnlyRepositories.contains("PaymentRepository"))
        #expect(DependencyContainer.partialSupabaseRepositories.contains { $0.hasPrefix("PaymentRepository") })
        // Chat moved off this list when it got a conformer; it must not be
        // silently dropped from the record altogether, because that conformer
        // still has a named hole in it.
        #expect(!DependencyContainer.mockOnlyRepositories.contains("ChatRepository"))
        #expect(DependencyContainer.partialSupabaseRepositories.contains { $0.hasPrefix("ChatRepository") })
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

/// A10 and N5 were both marked "built, nothing tests it" because their system
/// calls — `LAContext` and `SKStoreReviewController` — cannot run in CI. That
/// was true of the calls and false of the decisions around them, which is
/// where the behaviour worth protecting actually lives.
@Suite("A10 biometric lock policy")
struct BiometricLockPolicyTests {
    @Test("with the lock off, the app opens without a prompt")
    func lockOffOpens() {
        #expect(BiometricLockPolicy.decide(isEnabled: false, isAvailable: true) == .unlock)
    }

    @Test("with the lock on and biometrics available, the customer is challenged")
    func lockOnChallenges() {
        #expect(BiometricLockPolicy.decide(isEnabled: true, isAvailable: true) == .challenge)
    }

    /// The one that matters. A device with no enrolled Face ID must not leave
    /// somebody staring at a lock nothing can open — there is no password
    /// fallback here, so failing closed would mean the app is simply gone.
    @Test("with the lock on but biometrics unavailable, it fails OPEN and explains")
    func failsOpen() {
        let decision = BiometricLockPolicy.decide(isEnabled: true, isAvailable: false)
        #expect(decision == .unlockUnavailable(note: BiometricLockPolicy.unavailableNote))
        if case .unlockUnavailable(let note) = decision {
            #expect(note.localizedCaseInsensitiveContains("Face ID"))
        }
    }

    /// Order of checks: the setting is read before availability, so somebody
    /// who never turned the lock on is never told about Face ID.
    @Test("a device with no biometrics and the lock off gets no misleading note")
    func noNoteWhenLockIsOff() {
        #expect(BiometricLockPolicy.decide(isEnabled: false, isAvailable: false) == .unlock)
    }
}

@Suite("N5 App Store review prompt policy")
struct AppStoreReviewPromptPolicyTests {
    @Test("a 5-star review on a version never prompted before asks")
    func promptsOnFiveStars() {
        #expect(AppStoreReviewPromptPolicy.shouldPrompt(rating: 5, currentVersion: "1.2", lastPromptedVersion: nil))
    }

    @Test("anything below five stars never asks")
    func neverBelowFive() {
        for rating in 1...4 {
            #expect(!AppStoreReviewPromptPolicy.shouldPrompt(rating: rating, currentVersion: "1.2", lastPromptedVersion: nil),
                    "A \(rating)-star review should never trigger an App Store prompt")
        }
    }

    /// Three 5★ visits in a month should be three thank-yous and one prompt.
    @Test("the same version never asks twice, however many 5-star reviews")
    func oncePerVersion() {
        #expect(!AppStoreReviewPromptPolicy.shouldPrompt(rating: 5, currentVersion: "1.2", lastPromptedVersion: "1.2"))
    }

    @Test("a new version may ask again")
    func newVersionMayAsk() {
        #expect(AppStoreReviewPromptPolicy.shouldPrompt(rating: 5, currentVersion: "1.3", lastPromptedVersion: "1.2"))
    }

    /// `Bundle.main` returning nothing useful must not become a prompt on
    /// every single review — an unknown version is not a new version.
    @Test("an empty version string never asks")
    func emptyVersionNeverAsks() {
        #expect(!AppStoreReviewPromptPolicy.shouldPrompt(rating: 5, currentVersion: "", lastPromptedVersion: nil))
    }
}
