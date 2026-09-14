import Testing
import Foundation
@testable import VetCircuit

// Domain-layer tests: pure Swift business logic, no UI or network spun up.

@Suite("BookVisitUseCase")
struct BookVisitUseCaseTests {
    @Test("rejects a slot that is not available")
    func rejectsUnavailableSlot() async {
        let repo = MockVisitRepository()
        let useCase = BookVisitUseCase(visitRepository: repo)
        let slot = ScheduleSlot(id: UUID(), dayOfWeek: 2, startTime: .now.addingTimeInterval(3600),
                                 endTime: .now.addingTimeInterval(7200), capacity: 1, bookedCount: 1)

        await #expect(throws: DomainError.slotUnavailable) {
            _ = try await useCase.execute(petId: UUID(), vetId: UUID(), circuitId: UUID(), slot: slot)
        }
    }

    @Test("rejects a slot in the past")
    func rejectsPastSlot() async {
        let repo = MockVisitRepository()
        let useCase = BookVisitUseCase(visitRepository: repo)
        let slot = ScheduleSlot(id: UUID(), dayOfWeek: 2, startTime: .now.addingTimeInterval(-3600),
                                 endTime: .now, capacity: 3, bookedCount: 0)

        await #expect(throws: DomainError.self) {
            _ = try await useCase.execute(petId: UUID(), vetId: UUID(), circuitId: UUID(), slot: slot)
        }
    }

    @Test("rejects a slot that is at full capacity even if not explicitly marked unavailable")
    func rejectsFullCapacitySlot() async {
        let repo = MockVisitRepository()
        let useCase = BookVisitUseCase(visitRepository: repo)
        let slot = ScheduleSlot(id: UUID(), dayOfWeek: 2, startTime: .now.addingTimeInterval(3600),
                                 endTime: .now.addingTimeInterval(7200), capacity: 5, bookedCount: 5)

        await #expect(throws: DomainError.slotUnavailable) {
            _ = try await useCase.execute(petId: UUID(), vetId: UUID(), circuitId: UUID(), slot: slot)
        }
    }

    @Test("books a valid, future, available slot")
    func booksValidSlot() async throws {
        let repo = MockVisitRepository()
        let useCase = BookVisitUseCase(visitRepository: repo)
        let slot = ScheduleSlot(id: UUID(), dayOfWeek: 2, startTime: .now.addingTimeInterval(3600),
                                 endTime: .now.addingTimeInterval(7200), capacity: 3, bookedCount: 0)

        let visit = try await useCase.execute(petId: UUID(), vetId: UUID(), circuitId: UUID(), slot: slot)
        #expect(visit.status == .requested)
    }

    @Test("retrying with the same idempotency key returns the original visit, not a duplicate")
    func idempotentRetryReturnsOriginal() async throws {
        let repo = MockVisitRepository()
        let useCase = BookVisitUseCase(visitRepository: repo)
        let slot = ScheduleSlot(id: UUID(), dayOfWeek: 2, startTime: .now.addingTimeInterval(3600),
                                 endTime: .now.addingTimeInterval(7200), capacity: 3, bookedCount: 0)
        let key = UUID().uuidString
        let petId = UUID(), vetId = UUID(), circuitId = UUID()

        let first = try await useCase.execute(petId: petId, vetId: vetId, circuitId: circuitId, slot: slot, idempotencyKey: key)
        let retry = try await useCase.execute(petId: petId, vetId: vetId, circuitId: circuitId, slot: slot, idempotencyKey: key)

        #expect(first.id == retry.id)
        let allVisits = try await repo.listVisits(userId: first.userId)
        #expect(allVisits.filter { $0.id == first.id }.count == 1)
    }

    @Test("concurrent bookings on a slot never exceed its capacity")
    func neverOversellsCapacity() async throws {
        let repo = MockVisitRepository()
        let useCase = BookVisitUseCase(visitRepository: repo)
        let slot = ScheduleSlot(id: UUID(), dayOfWeek: 2, startTime: .now.addingTimeInterval(3600),
                                 endTime: .now.addingTimeInterval(7200), capacity: 3, bookedCount: 0)

        let results = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    (try? await useCase.execute(petId: UUID(), vetId: UUID(), circuitId: UUID(), slot: slot)) != nil
                }
            }
            var successes = 0
            for await success in group where success { successes += 1 }
            return successes
        }

        #expect(results == 3)
    }
}

@Suite("ManageAccountDeletionUseCase")
struct ManageAccountDeletionUseCaseTests {
    @Test("no pending deletion before one is requested")
    func noPendingInitially() async throws {
        let useCase = ManageAccountDeletionUseCase(accountRepository: MockAccountRepository(), authRepository: MockAuthRepository())
        let pending = try await useCase.pendingDeletion(userId: UUID())
        #expect(pending == nil)
    }

    @Test("requesting deletion schedules a purge 30 days out")
    func requestSchedulesPurge() async throws {
        let useCase = ManageAccountDeletionUseCase(accountRepository: MockAccountRepository(), authRepository: MockAuthRepository())
        let userId = UUID()
        let request = try await useCase.requestDeletion(userId: userId)
        #expect(request.status == .pending)
        let daysUntilPurge = Calendar.current.dateComponents([.day], from: .now, to: request.scheduledPurgeAt).day ?? 0
        #expect(daysUntilPurge >= DeletionRequest.softWindowDays - 1)

        let pending = try await useCase.pendingDeletion(userId: userId)
        #expect(pending?.id == request.id)
    }

    @Test("cancelling a pending deletion clears it")
    func cancellingClearsPending() async throws {
        let useCase = ManageAccountDeletionUseCase(accountRepository: MockAccountRepository(), authRepository: MockAuthRepository())
        let userId = UUID()
        _ = try await useCase.requestDeletion(userId: userId)
        try await useCase.cancelPendingDeletion(userId: userId)
        let pending = try await useCase.pendingDeletion(userId: userId)
        #expect(pending == nil)
    }
}

@Suite("ExportDataUseCase")
struct ExportDataUseCaseTests {
    @Test("produces an export with the requesting user's data")
    func producesExport() async throws {
        let useCase = ExportDataUseCase(accountRepository: MockAccountRepository())
        let export = try await useCase.execute(userId: MockData.user.id)
        #expect(export.user.id == MockData.user.id)
    }
}

@Suite("Visit.legalTransitions")
struct VisitTransitionTests {
    @Test("the full happy path is legal, state by state")
    func happyPathIsLegal() {
        let path: [Visit.VisitStatus] = [.requested, .confirmed, .assigned, .enRoute, .arrived, .inProgress, .completed]
        for (from, to) in zip(path, path.dropFirst()) {
            #expect(Visit.canTransition(from: from, to: to), "\(from) -> \(to) should be legal")
        }
    }

    @Test("skipping states is illegal")
    func skippingStatesIsIllegal() {
        #expect(!Visit.canTransition(from: .requested, to: .arrived))
        #expect(!Visit.canTransition(from: .confirmed, to: .inProgress))
        #expect(!Visit.canTransition(from: .completed, to: .requested))
    }

    @Test("a completed visit can only move to disputed, never backwards")
    func completedOnlyMovesToDisputed() {
        #expect(Visit.canTransition(from: .completed, to: .disputed))
        #expect(!Visit.canTransition(from: .completed, to: .completed))
        #expect(!Visit.canTransition(from: .completed, to: .confirmed))
    }
}

@Suite("StartVisitUseCase")
struct StartVisitUseCaseTests {
    @Test("rejects a code that isn't 4 digits")
    func rejectsMalformedCode() async {
        let useCase = StartVisitUseCase(visitOTPRepository: MockVisitOTPRepository(), visitRepository: MockVisitRepository())
        await #expect(throws: DomainError.self) {
            _ = try await useCase.verify(visitId: UUID(), code: "12a4")
        }
        await #expect(throws: DomainError.self) {
            _ = try await useCase.verify(visitId: UUID(), code: "123")
        }
    }

    @Test("rejects a code that doesn't match")
    func rejectsWrongCode() async throws {
        let otpRepo = MockVisitOTPRepository()
        let visitRepo = MockVisitRepository()
        let useCase = StartVisitUseCase(visitOTPRepository: otpRepo, visitRepository: visitRepo)
        let visitId = UUID()
        _ = try await otpRepo.generateOTP(visitId: visitId)

        await #expect(throws: DomainError.self) {
            _ = try await useCase.verify(visitId: visitId, code: "0000")
        }
    }

    @Test("verifying the correct code moves the visit to in_progress")
    func correctCodeStartsVisit() async throws {
        let otpRepo = MockVisitOTPRepository()
        let visitRepo = MockVisitRepository()
        let useCase = StartVisitUseCase(visitOTPRepository: otpRepo, visitRepository: visitRepo)
        let visit = try await visitRepo.createVisit(
            petId: UUID(), vetId: UUID(), circuitId: UUID(),
            slot: ScheduleSlot(id: UUID(), dayOfWeek: 1, startTime: .now.addingTimeInterval(3600), endTime: .now.addingTimeInterval(7200), capacity: 3, bookedCount: 0),
            idempotencyKey: UUID().uuidString
        )
        let otp = try await otpRepo.generateOTP(visitId: visit.id)

        let updated = try await useCase.verify(visitId: visit.id, code: otp.code)
        #expect(updated.status == .inProgress)
    }
}

@Suite("ManageConsentUseCase")
struct ManageConsentUseCaseTests {
    @Test("has not accepted the waiver before granting it")
    func notAcceptedInitially() async throws {
        let useCase = ManageConsentUseCase(consentRepository: MockConsentRepository())
        let hasAccepted = try await useCase.hasAcceptedLiabilityWaiver(userId: UUID())
        #expect(!hasAccepted)
    }

    @Test("accepting the waiver is reflected immediately")
    func acceptingIsReflected() async throws {
        let useCase = ManageConsentUseCase(consentRepository: MockConsentRepository())
        let userId = UUID()
        _ = try await useCase.acceptLiabilityWaiver(userId: userId)
        let hasAccepted = try await useCase.hasAcceptedLiabilityWaiver(userId: userId)
        #expect(hasAccepted)
    }
}

@Suite("CancellationPolicy")
struct CancellationPolicyTests {
    @Test("free full refund more than 4 hours before the visit")
    func freeBeforeWindow() {
        let scheduledAt = Date().addingTimeInterval(5 * 3600)
        let outcome = CancellationPolicy.evaluate(scheduledAt: scheduledAt, paidMinorUnits: 60_000)
        #expect(outcome.refundPercent == 100)
        #expect(outcome.refundMinorUnits == 60_000)
        #expect(!outcome.isPastVisitTime)
    }

    @Test("50% refund inside the 4-hour window")
    func halfRefundInsideWindow() {
        let scheduledAt = Date().addingTimeInterval(2 * 3600)
        let outcome = CancellationPolicy.evaluate(scheduledAt: scheduledAt, paidMinorUnits: 60_000)
        #expect(outcome.refundPercent == 50)
        #expect(outcome.refundMinorUnits == 30_000)
    }

    @Test("no refund once the visit's scheduled time has passed")
    func noRefundAfterVisitTime() {
        let scheduledAt = Date().addingTimeInterval(-3600)
        let outcome = CancellationPolicy.evaluate(scheduledAt: scheduledAt, paidMinorUnits: 60_000)
        #expect(outcome.refundPercent == 0)
        #expect(outcome.isPastVisitTime)
    }
}

@Suite("CancelVisitUseCase")
struct CancelVisitUseCaseTests {
    @Test("allows cancelling a requested visit and issues the policy-computed refund")
    func cancelsRequestedAndRefunds() async throws {
        let visitRepo = MockVisitRepository()
        let refundRepo = MockRefundRepository()
        let visit = try await visitRepo.createVisit(
            petId: UUID(), vetId: UUID(), circuitId: UUID(),
            slot: ScheduleSlot(id: UUID(), dayOfWeek: 1, startTime: .now.addingTimeInterval(3600 * 6), endTime: .now.addingTimeInterval(7200), capacity: 3, bookedCount: 0),
            idempotencyKey: UUID().uuidString
        )
        let useCase = CancelVisitUseCase(visitRepository: visitRepo, refundRepository: refundRepo)
        let outcome = try await useCase.execute(visitId: visit.id, currentStatus: .requested, scheduledAt: visit.scheduledAt, paymentId: UUID())

        let updated = try await visitRepo.visit(id: visit.id)
        #expect(updated.status == .cancelledByUser)
        #expect(outcome.refundPercent == 100)
        let refunds = try await refundRepo.refunds(visitId: visit.id)
        #expect(refunds.count == 1)
    }

    @Test("refuses to cancel a completed visit")
    func refusesCompletedCancel() async {
        let useCase = CancelVisitUseCase(visitRepository: MockVisitRepository(), refundRepository: MockRefundRepository())
        await #expect(throws: DomainError.self) {
            _ = try await useCase.execute(visitId: UUID(), currentStatus: .completed, scheduledAt: .now, paymentId: nil)
        }
    }

    @Test("issues no refund when there's no associated payment, even with a full-refund outcome")
    func noRefundWithoutPayment() async throws {
        let visitRepo = MockVisitRepository()
        let refundRepo = MockRefundRepository()
        let visit = try await visitRepo.createVisit(
            petId: UUID(), vetId: UUID(), circuitId: UUID(),
            slot: ScheduleSlot(id: UUID(), dayOfWeek: 1, startTime: .now.addingTimeInterval(3600 * 6), endTime: .now.addingTimeInterval(7200), capacity: 3, bookedCount: 0),
            idempotencyKey: UUID().uuidString
        )
        let useCase = CancelVisitUseCase(visitRepository: visitRepo, refundRepository: refundRepo)
        _ = try await useCase.execute(visitId: visit.id, currentStatus: .requested, scheduledAt: visit.scheduledAt, paymentId: nil)
        let refunds = try await refundRepo.refunds(visitId: visit.id)
        #expect(refunds.isEmpty)
    }
}

@Suite("RescheduleVisitUseCase")
struct RescheduleVisitUseCaseTests {
    @Test("rejects rescheduling inside the 4-hour policy window")
    func rejectsInsideWindow() async {
        let repo = MockVisitRepository()
        let useCase = RescheduleVisitUseCase(visitRepository: repo)
        let newSlot = ScheduleSlot(id: UUID(), dayOfWeek: 2, startTime: .now.addingTimeInterval(86_400), endTime: .now.addingTimeInterval(90_000), capacity: 3, bookedCount: 0)

        await #expect(throws: DomainError.self) {
            _ = try await useCase.execute(visitId: UUID(), currentScheduledAt: .now.addingTimeInterval(3600), newSlot: newSlot)
        }
    }

    @Test("rejects rescheduling onto a full slot")
    func rejectsFullNewSlot() async {
        let repo = MockVisitRepository()
        let useCase = RescheduleVisitUseCase(visitRepository: repo)
        let fullSlot = ScheduleSlot(id: UUID(), dayOfWeek: 2, startTime: .now.addingTimeInterval(86_400), endTime: .now.addingTimeInterval(90_000), capacity: 1, bookedCount: 1)

        await #expect(throws: DomainError.slotUnavailable) {
            _ = try await useCase.execute(visitId: UUID(), currentScheduledAt: .now.addingTimeInterval(3600 * 10), newSlot: fullSlot)
        }
    }

    @Test("reschedules to a valid future slot outside the policy window")
    func reschedulesValidSlot() async throws {
        let repo = MockVisitRepository()
        let visit = try await repo.createVisit(
            petId: UUID(), vetId: UUID(), circuitId: UUID(),
            slot: ScheduleSlot(id: UUID(), dayOfWeek: 1, startTime: .now.addingTimeInterval(86_400), endTime: .now.addingTimeInterval(90_000), capacity: 3, bookedCount: 0),
            idempotencyKey: UUID().uuidString
        )
        let useCase = RescheduleVisitUseCase(visitRepository: repo)
        let newSlot = ScheduleSlot(id: UUID(), dayOfWeek: 2, startTime: .now.addingTimeInterval(172_800), endTime: .now.addingTimeInterval(176_400), capacity: 3, bookedCount: 0)

        let rescheduled = try await useCase.execute(visitId: visit.id, currentScheduledAt: visit.scheduledAt, newSlot: newSlot)
        #expect(rescheduled.scheduledAt == newSlot.startTime)
    }
}

@Suite("SendChatMessageUseCase")
struct SendChatMessageUseCaseTests {
    @Test("rejects empty messages")
    func rejectsEmpty() async {
        let useCase = SendChatMessageUseCase(chatRepository: MockChatRepository())
        await #expect(throws: DomainError.self) {
            _ = try await useCase.execute(visitId: UUID(), body: "   ")
        }
    }

    @Test("sends a valid message")
    func sendsValid() async throws {
        let useCase = SendChatMessageUseCase(chatRepository: MockChatRepository())
        let message = try await useCase.execute(visitId: UUID(), body: "Hello!")
        #expect(message.body == "Hello!")
    }
}

@Suite("SendChatMessageUseCase photo attachments")
struct SendChatPhotoTests {
    @Test("rejects an empty photo payload")
    func rejectsEmptyData() async {
        let useCase = SendChatMessageUseCase(chatRepository: MockChatRepository())
        await #expect(throws: DomainError.self) {
            _ = try await useCase.sendPhoto(visitId: UUID(), imageData: Data())
        }
    }

    @Test("rejects a photo over the 10MB limit")
    func rejectsOversizedPhoto() async {
        let useCase = SendChatMessageUseCase(chatRepository: MockChatRepository())
        let oversized = Data(repeating: 0, count: 11 * 1024 * 1024)
        await #expect(throws: DomainError.self) {
            _ = try await useCase.sendPhoto(visitId: UUID(), imageData: oversized)
        }
    }

    @Test("sends a valid photo and gets back a message with an attachment URL")
    func sendsValidPhoto() async throws {
        let useCase = SendChatMessageUseCase(chatRepository: MockChatRepository())
        let message = try await useCase.sendPhoto(visitId: UUID(), imageData: Data([0xFF, 0xD8, 0xFF]))
        #expect(message.attachmentURL != nil)
    }
}

@Suite("SubmitReviewUseCase")
struct SubmitReviewUseCaseTests {
    @Test("rejects out-of-range ratings")
    func rejectsInvalidRating() async {
        let useCase = SubmitReviewUseCase(reviewRepository: MockReviewRepository())
        await #expect(throws: DomainError.self) {
            _ = try await useCase.execute(visitId: UUID(), rating: 6, comment: nil)
        }
    }

    @Test("accepts a valid rating")
    func acceptsValidRating() async throws {
        let useCase = SubmitReviewUseCase(reviewRepository: MockReviewRepository())
        let review = try await useCase.execute(visitId: UUID(), rating: 4, comment: "Great visit")
        #expect(review.rating == 4)
    }
}

@Suite("GetCircuitsUseCase")
struct GetCircuitsUseCaseTests {
    @Test("filters circuits by vertical")
    func filtersByVertical() async throws {
        let useCase = GetCircuitsUseCase(repository: MockCircuitRepository())
        let vetCircuits = try await useCase.execute(area: nil, vertical: .vet)
        let elderCareCircuits = try await useCase.execute(area: nil, vertical: .elderCare)
        #expect(!vetCircuits.isEmpty)
        #expect(elderCareCircuits.isEmpty)
    }
}

@Suite("SlotBufferPolicy")
struct SlotBufferPolicyTests {
    @Test("rejects a candidate with zero gap after a booked slot")
    func rejectsZeroGap() {
        let booked = Date(timeIntervalSince1970: 0)
        // Candidate starts exactly when the booked 30-min visit ends — no travel time at all.
        let candidate = booked.addingTimeInterval(30 * 60)
        let offerable = SlotBufferPolicy.isOfferable(
            candidateStart: candidate, visitDurationMinutes: 30, bookedStarts: [booked], bufferMinutes: 15
        )
        #expect(!offerable)
    }

    @Test("accepts a candidate that leaves the full buffer")
    func acceptsFullBuffer() {
        let booked = Date(timeIntervalSince1970: 0)
        let candidate = booked.addingTimeInterval((30 + 15) * 60)
        let offerable = SlotBufferPolicy.isOfferable(
            candidateStart: candidate, visitDurationMinutes: 30, bookedStarts: [booked], bufferMinutes: 15
        )
        #expect(offerable)
    }

    @Test("accepts when there are no booked slots at all")
    func acceptsWithNoBookings() {
        let offerable = SlotBufferPolicy.isOfferable(
            candidateStart: .now, visitDurationMinutes: 30, bookedStarts: [], bufferMinutes: 15
        )
        #expect(offerable)
    }

    @Test("filterOfferableSlots keeps booked slots and drops too-close empty ones")
    func filterOfferableSlotsDropsTooClose() {
        let base = Date(timeIntervalSince1970: 0)
        let booked = ScheduleSlot(id: UUID(), dayOfWeek: 2, startTime: base, endTime: base.addingTimeInterval(1800), capacity: 1, bookedCount: 1)
        let tooClose = ScheduleSlot(id: UUID(), dayOfWeek: 2, startTime: base.addingTimeInterval(1800), endTime: base.addingTimeInterval(3600), capacity: 1, bookedCount: 0)
        let farEnough = ScheduleSlot(id: UUID(), dayOfWeek: 2, startTime: base.addingTimeInterval(2700), endTime: base.addingTimeInterval(4500), capacity: 1, bookedCount: 0)
        let filtered = SlotBufferPolicy.filterOfferableSlots([booked, tooClose, farEnough], visitDurationMinutes: 30, bufferMinutes: 15)
        #expect(filtered.contains { $0.id == booked.id })
        #expect(!filtered.contains { $0.id == tooClose.id })
        #expect(filtered.contains { $0.id == farEnough.id })
    }
}

@Suite("VetBlackout")
struct VetBlackoutTests {
    @Test("isActive is true within the date range, inclusive")
    func activeWithinRange() {
        let now = Date.now
        let blackout = VetBlackout(id: UUID(), vetId: UUID(), startDate: now.addingTimeInterval(-86400), endDate: now.addingTimeInterval(86400), reason: "Leave")
        #expect(blackout.isActive(on: now))
    }

    @Test("isActive is false outside the date range")
    func inactiveOutsideRange() {
        let now = Date.now
        let blackout = VetBlackout(id: UUID(), vetId: UUID(), startDate: now.addingTimeInterval(86400), endDate: now.addingTimeInterval(2 * 86400), reason: nil)
        #expect(!blackout.isActive(on: now))
    }

    @Test("isVetBlackedOut only matches the given vet")
    func matchesOnlyGivenVet() {
        let now = Date.now
        let vetA = UUID(); let vetB = UUID()
        let blackout = VetBlackout(id: UUID(), vetId: vetA, startDate: now.addingTimeInterval(-3600), endDate: now.addingTimeInterval(3600), reason: nil)
        #expect(VetBlackout.isVetBlackedOut(vetId: vetA, blackouts: [blackout], on: now))
        #expect(!VetBlackout.isVetBlackedOut(vetId: vetB, blackouts: [blackout], on: now))
    }
}

@Suite("ManageVetBlackoutsUseCase")
struct ManageVetBlackoutsUseCaseTests {
    @Test("rejects an end date before the start date")
    func rejectsInvertedRange() async {
        let useCase = ManageVetBlackoutsUseCase(repository: MockVetBlackoutRepository())
        let vetId = UUID()
        await #expect(throws: DomainError.self) {
            _ = try await useCase.add(vetId: vetId, startDate: .now, endDate: .now.addingTimeInterval(-3600), reason: nil)
        }
    }

    @Test("add then list returns the created blackout")
    func addThenList() async throws {
        let useCase = ManageVetBlackoutsUseCase(repository: MockVetBlackoutRepository())
        let vetId = UUID()
        _ = try await useCase.add(vetId: vetId, startDate: .now, endDate: .now.addingTimeInterval(86400), reason: "Diwali")
        let list = try await useCase.list(vetId: vetId)
        #expect(list.count == 1)
        #expect(list.first?.reason == "Diwali")
    }
}

@Suite("GetCircuitsUseCase blackout filtering")
struct GetCircuitsUseCaseBlackoutTests {
    @Test("excludes a circuit whose vet is currently blacked out")
    func excludesBlackedOutVet() async throws {
        let circuitRepository = MockCircuitRepository()
        let allCircuits = try await circuitRepository.listCircuits(area: nil)
        guard let targetCircuit = allCircuits.first(where: { $0.vertical == .vet }) else {
            Issue.record("Fixture has no vet-vertical circuit to test against")
            return
        }
        let blackoutRepository = MockVetBlackoutRepository()
        _ = try await blackoutRepository.create(
            VetBlackout(id: UUID(), vetId: targetCircuit.vetId, startDate: .now.addingTimeInterval(-3600), endDate: .now.addingTimeInterval(3600), reason: "Leave")
        )

        let useCase = GetCircuitsUseCase(repository: circuitRepository, vetBlackoutRepository: blackoutRepository)
        let result = try await useCase.execute(area: nil, vertical: .vet)
        #expect(!result.contains { $0.id == targetCircuit.id })
    }

    @Test("without a blackout repository, nothing is filtered")
    func noFilteringWithoutRepository() async throws {
        let useCase = GetCircuitsUseCase(repository: MockCircuitRepository())
        let result = try await useCase.execute(area: nil, vertical: .vet)
        #expect(!result.isEmpty)
    }
}

@Suite("MedicationReminder")
struct MedicationReminderTests {
    @Test("isInRange is false before the start date")
    func falseBeforeStart() {
        let reminder = MedicationReminder(id: UUID(), petId: UUID(), medicationName: "Amoxicillin", dosage: "1 tablet",
                                           times: [TimeOfDay(hour: 8, minute: 0)], startDate: .now.addingTimeInterval(86400), endDate: nil)
        #expect(!reminder.isInRange(on: .now))
    }

    @Test("isInRange is true with no end date, once started")
    func trueOngoing() {
        let reminder = MedicationReminder(id: UUID(), petId: UUID(), medicationName: "Fish oil", dosage: "1 capsule",
                                           times: [TimeOfDay(hour: 8, minute: 0)], startDate: .now.addingTimeInterval(-86400), endDate: nil)
        #expect(reminder.isInRange(on: .now))
    }

    @Test("isInRange is false after the end date")
    func falseAfterEnd() {
        let reminder = MedicationReminder(id: UUID(), petId: UUID(), medicationName: "Antibiotic", dosage: "1 tablet",
                                           times: [TimeOfDay(hour: 8, minute: 0)],
                                           startDate: .now.addingTimeInterval(-10 * 86400), endDate: .now.addingTimeInterval(-2 * 86400))
        #expect(!reminder.isInRange(on: .now))
    }
}

@Suite("ManageMedicationRemindersUseCase")
struct ManageMedicationRemindersUseCaseTests {
    @Test("rejects an empty medication name")
    func rejectsEmptyName() async {
        let useCase = ManageMedicationRemindersUseCase(repository: MockMedicationReminderRepository())
        await #expect(throws: DomainError.self) {
            _ = try await useCase.add(petId: UUID(), medicationName: "  ", dosage: "1 tablet", times: [TimeOfDay(hour: 8, minute: 0)], startDate: .now, endDate: nil)
        }
    }

    @Test("rejects no times of day")
    func rejectsNoTimes() async {
        let useCase = ManageMedicationRemindersUseCase(repository: MockMedicationReminderRepository())
        await #expect(throws: DomainError.self) {
            _ = try await useCase.add(petId: UUID(), medicationName: "Fish oil", dosage: "1 capsule", times: [], startDate: .now, endDate: nil)
        }
    }

    @Test("add then list, then setActive toggles the flag")
    func addListSetActive() async throws {
        let useCase = ManageMedicationRemindersUseCase(repository: MockMedicationReminderRepository())
        let petId = UUID()
        let created = try await useCase.add(petId: petId, medicationName: "Fish oil", dosage: "1 capsule",
                                             times: [TimeOfDay(hour: 8, minute: 0)], startDate: .now, endDate: nil)
        var list = try await useCase.list(petId: petId)
        #expect(list.count == 1)

        let deactivated = try await useCase.setActive(created, isActive: false)
        #expect(!deactivated.isActive)
        list = try await useCase.list(petId: petId)
        #expect(list.first?.isActive == false)
    }

    @Test("remove deletes the reminder")
    func removeDeletes() async throws {
        let useCase = ManageMedicationRemindersUseCase(repository: MockMedicationReminderRepository())
        let petId = UUID()
        let created = try await useCase.add(petId: petId, medicationName: "Fish oil", dosage: "1 capsule",
                                             times: [TimeOfDay(hour: 8, minute: 0)], startDate: .now, endDate: nil)
        try await useCase.remove(id: created.id)
        let list = try await useCase.list(petId: petId)
        #expect(list.isEmpty)
    }
}

@Suite("GetLoyaltyAccountUseCase")
struct GetLoyaltyAccountUseCaseTests {
    @Test("starts at zero points and bronze tier")
    func startsAtBronze() async throws {
        let useCase = GetLoyaltyAccountUseCase(loyaltyRepository: MockLoyaltyRepository())
        let account = try await useCase.execute(userId: UUID())
        #expect(account.points == 0)
        #expect(account.tier == .bronze)
    }

    @Test("awarding points can move the tier to silver")
    func awardingMovesTier() async throws {
        let repo = MockLoyaltyRepository()
        let account = try await repo.awardPoints(userId: UUID(), points: 250)
        #expect(account.tier == .silver)
    }
}

// E5: loyalty point redemption at checkout.

@Suite("LoyaltyRedemptionPolicy")
struct LoyaltyRedemptionPolicyTests {
    @Test("converts points to minor units at the fixed rate")
    func convertsPoints() {
        #expect(LoyaltyRedemptionPolicy.minorUnits(forPoints: 100) == 5_000)
    }

    @Test("rejects redeeming below the minimum")
    func rejectsBelowMinimum() {
        #expect(LoyaltyRedemptionPolicy.validate(points: 50, availablePoints: 500) != nil)
    }

    @Test("rejects redeeming more than available")
    func rejectsOverAvailable() {
        #expect(LoyaltyRedemptionPolicy.validate(points: 500, availablePoints: 100) != nil)
    }

    @Test("allows a valid redemption")
    func allowsValidRedemption() {
        #expect(LoyaltyRedemptionPolicy.validate(points: 200, availablePoints: 500) == nil)
    }
}

@Suite("RedeemLoyaltyPointsUseCase")
struct RedeemLoyaltyPointsUseCaseTests {
    @Test("redeems points and moves them into wallet credit")
    func redeemsAndCreditsWallet() async throws {
        let walletRepo = MockWalletRepository()
        let loyaltyRepo = MockLoyaltyRepository(walletRepository: walletRepo)
        let userId = UUID()
        _ = try await loyaltyRepo.awardPoints(userId: userId, points: 500)
        let balanceBefore = try await walletRepo.balanceMinorUnits(userId: userId)

        let useCase = RedeemLoyaltyPointsUseCase(loyaltyRepository: loyaltyRepo)
        let account = try await useCase.execute(userId: userId, points: 200)

        #expect(account.points == 300)
        let balanceAfter = try await walletRepo.balanceMinorUnits(userId: userId)
        #expect(balanceAfter == balanceBefore + LoyaltyRedemptionPolicy.minorUnits(forPoints: 200))
    }

    @Test("rejects redeeming more points than the account has")
    func rejectsOverdraw() async throws {
        let loyaltyRepo = MockLoyaltyRepository()
        let userId = UUID()
        _ = try await loyaltyRepo.awardPoints(userId: userId, points: 100)

        let useCase = RedeemLoyaltyPointsUseCase(loyaltyRepository: loyaltyRepo)
        await #expect(throws: DomainError.self) {
            _ = try await useCase.execute(userId: userId, points: 500)
        }
    }
}

@Suite("RunTriageUseCase")
struct RunTriageUseCaseTests {
    @Test("rejects empty symptom description")
    func rejectsEmpty() async {
        let useCase = RunTriageUseCase(triageRepository: MockTriageRepository())
        await #expect(throws: DomainError.self) {
            _ = try await useCase.execute(species: .dog, symptoms: "  ")
        }
    }

    @Test("flags urgent symptoms")
    func flagsUrgent() async throws {
        let useCase = RunTriageUseCase(triageRepository: MockTriageRepository())
        let result = try await useCase.execute(species: .dog, symptoms: "He is bleeding heavily from a cut")
        #expect(result.recommendation == .bookVisitUrgently)
    }

    @Test("routes mild symptoms to self-care")
    func routesMildToSelfCare() async throws {
        let useCase = RunTriageUseCase(triageRepository: MockTriageRepository())
        let result = try await useCase.execute(species: .cat, symptoms: "Seems a little sleepy today")
        #expect(result.recommendation == .selfCare)
    }
}

@Suite("SendReferralUseCase")
struct SendReferralUseCaseTests {
    @Test("rejects an invalid phone number")
    func rejectsInvalidPhone() async {
        let useCase = SendReferralUseCase(referralRepository: MockReferralRepository())
        await #expect(throws: DomainError.self) {
            _ = try await useCase.execute(userId: UUID(), phone: "123")
        }
    }

    @Test("sends a valid invite")
    func sendsValidInvite() async throws {
        let useCase = SendReferralUseCase(referralRepository: MockReferralRepository())
        let referral = try await useCase.execute(userId: UUID(), phone: "9876543210")
        #expect(referral.status == .pending)
    }
}

@Suite("StartCallUseCase")
struct StartCallUseCaseTests {
    @Test("returns a masked proxy number, never a raw one")
    func returnsMaskedProxyNumber() async throws {
        let useCase = StartCallUseCase(callRepository: MockCallRepository())
        let session = try await useCase.execute(visitId: UUID())
        #expect(!session.proxyNumber.isEmpty)
        #expect(!session.isExpired)
    }
}

@Suite("TrackVetUseCase")
struct TrackVetUseCaseTests {
    @Test("returns the vet's current location")
    func returnsLocation() async throws {
        let useCase = TrackVetUseCase(liveTrackingRepository: MockLiveTrackingRepository())
        let location = try await useCase.execute(visitId: UUID())
        #expect(location != nil)
    }
}

@Suite("ManagePetsUseCase")
struct ManagePetsUseCaseTests {
    @Test("rejects a pet with an empty name")
    func rejectsEmptyName() async {
        let useCase = ManagePetsUseCase(petRepository: MockPetRepository())
        let pet = Pet(id: UUID(), ownerId: UUID(), name: "  ", species: .dog, breed: nil, dateOfBirth: nil)
        await #expect(throws: DomainError.self) {
            _ = try await useCase.add(pet)
        }
    }
}

@Suite("PricingEngine")
struct PricingEngineTests {
    private let variant = ServiceVariant(id: UUID(), serviceId: UUID(), name: "Standard 20 min", durationMinutes: 20, priceMinorUnits: 59_900, additionalPetPriceMinorUnits: 29_900)

    @Test("base variant price plus GST, no extras")
    func basePriceWithGST() {
        let breakdown = PricingEngine.quote(.init(variant: variant, addons: [], additionalPetCount: 0, travelFeeMinorUnits: 0))
        let expectedGST = Int((Double(59_900) * 0.18).rounded())
        #expect(breakdown.totalMinorUnits == 59_900 + expectedGST)
    }

    @Test("multi-pet, add-ons, and travel fee all itemize and sum correctly")
    func multiPetAddonsAndTravel() {
        let addon = Addon(id: UUID(), name: "Nail trim", priceMinorUnits: 14_900)
        let breakdown = PricingEngine.quote(.init(variant: variant, addons: [addon], additionalPetCount: 1, travelFeeMinorUnits: 4_500))
        let subtotal = 59_900 + 29_900 + 14_900 + 4_500
        let gst = Int((Double(subtotal) * 0.18).rounded())
        #expect(breakdown.totalMinorUnits == subtotal + gst)
        #expect(breakdown.lineItems.contains { $0.label.contains("Additional pet") })
        #expect(breakdown.lineItems.contains { $0.label == "Travel fee" })
    }

    @Test("a coupon discount never pushes the taxable amount negative")
    func discountNeverGoesNegative() {
        let breakdown = PricingEngine.quote(.init(variant: variant, addons: [], additionalPetCount: 0, travelFeeMinorUnits: 0, couponDiscountMinorUnits: 999_999))
        #expect(breakdown.totalMinorUnits >= 0)
    }

    @Test("wallet credit is capped at the pre-wallet total, never overdraws")
    func walletCappedAtTotal() {
        let breakdown = PricingEngine.quote(.init(variant: variant, addons: [], additionalPetCount: 0, travelFeeMinorUnits: 0, walletBalanceMinorUnits: 999_999))
        #expect(breakdown.totalMinorUnits == 0)
    }

    // E1: change quantity — multiplies base/multi-pet/add-ons, not travel fee.
    @Test("quantity multiplies the base price and add-ons, not the travel fee")
    func quantityMultipliesBaseAndAddons() {
        let addon = Addon(id: UUID(), name: "Nail trim", priceMinorUnits: 10_000)
        let breakdown = PricingEngine.quote(.init(
            variant: variant, addons: [addon], additionalPetCount: 0, travelFeeMinorUnits: 4_500, gstRate: 0, quantity: 2
        ))
        #expect(breakdown.totalMinorUnits == 59_900 * 2 + 10_000 * 2 + 4_500)
    }

    @Test("an entitlement credit is never multiplied by quantity")
    func entitlementCreditIgnoresQuantity() {
        let breakdown = PricingEngine.quote(.init(
            variant: variant, addons: [], additionalPetCount: 0, travelFeeMinorUnits: 0, gstRate: 0,
            entitlementCreditApplied: true, quantity: 3
        ))
        #expect(breakdown.totalMinorUnits == 0)
    }
}

@Suite("ManageCartUseCase + GetQuoteUseCase")
struct CartAndQuoteUseCaseTests {
    @Test("rejects adding an item with no pets selected")
    func rejectsNoPets() async throws {
        let repo = MockCartRepository()
        let useCase = ManageCartUseCase(cartRepository: repo)
        let cart = try await useCase.current(userId: UUID())
        let item = CartItem(id: UUID(), serviceId: UUID(), variantId: UUID(), petIds: [])

        await #expect(throws: DomainError.self) {
            _ = try await useCase.addItem(item, to: cart)
        }
    }

    // E1: change quantity / clear cart.
    @Test("setQuantity rejects out-of-range values and updates a valid one")
    func setQuantityValidatesRange() async throws {
        let repo = MockCartRepository()
        let useCase = ManageCartUseCase(cartRepository: repo)
        var cart = try await useCase.current(userId: UUID())
        let item = CartItem(id: UUID(), serviceId: UUID(), variantId: UUID(), petIds: [UUID()])
        cart = try await useCase.addItem(item, to: cart)

        await #expect(throws: DomainError.self) {
            _ = try await useCase.setQuantity(0, forItemId: item.id, in: cart)
        }
        await #expect(throws: DomainError.self) {
            _ = try await useCase.setQuantity(21, forItemId: item.id, in: cart)
        }

        let updated = try await useCase.setQuantity(3, forItemId: item.id, in: cart)
        #expect(updated.items.first?.quantity == 3)
    }

    @Test("clear empties the cart")
    func clearEmptiesCart() async throws {
        let repo = MockCartRepository()
        let useCase = ManageCartUseCase(cartRepository: repo)
        let userId = UUID()
        var cart = try await useCase.current(userId: userId)
        cart = try await useCase.addItem(CartItem(id: UUID(), serviceId: UUID(), variantId: UUID(), petIds: [UUID()]), to: cart)
        #expect(!cart.items.isEmpty)

        try await useCase.clear(userId: userId)
        let cleared = try await useCase.current(userId: userId)
        #expect(cleared.items.isEmpty)
    }

    @Test("rejects a quote for an empty cart")
    func rejectsEmptyCartQuote() async {
        let quoteUseCase = GetQuoteUseCase(
            quoteRepository: MockQuoteRepository(couponRepository: MockCouponRepository(), walletRepository: MockWalletRepository()),
            catalogRepository: MockCatalogRepository(), circuitRepository: MockCircuitRepository(),
            vetServiceOverrideRepository: MockVetServiceOverrideRepository())
        let emptyCart = Cart(id: UUID(), userId: UUID())

        await #expect(throws: DomainError.self) {
            _ = try await quoteUseCase.execute(cart: emptyCart)
        }
    }

    @Test("a real cart produces a signed, itemized, unexpired quote")
    func producesRealQuote() async throws {
        let cartRepo = MockCartRepository()
        let cartUseCase = ManageCartUseCase(cartRepository: cartRepo)
        let quoteUseCase = GetQuoteUseCase(
            quoteRepository: MockQuoteRepository(couponRepository: MockCouponRepository(), walletRepository: MockWalletRepository()),
            catalogRepository: MockCatalogRepository(), circuitRepository: MockCircuitRepository(),
            vetServiceOverrideRepository: MockVetServiceOverrideRepository())

        let service = MockData.services[0]
        let userId = UUID()
        var cart = try await cartUseCase.current(userId: userId)
        let item = CartItem(id: UUID(), serviceId: service.id, variantId: service.variants[0].id, petIds: [UUID()])
        cart = try await cartUseCase.addItem(item, to: cart)

        let quote = try await quoteUseCase.execute(cart: cart)
        #expect(!quote.signature.isEmpty)
        #expect(!quote.isExpired)
        #expect(quote.breakdown.totalMinorUnits > 0)
    }

    @Test("an active subscriber with a credit gets the base price zeroed")
    func appliesEntitlementCreditWhenAvailable() async throws {
        let cartRepo = MockCartRepository()
        let cartUseCase = ManageCartUseCase(cartRepository: cartRepo)
        let subscriptionRepo = MockSubscriptionRepository()
        let entitlementRepo = MockSubscriptionEntitlementRepository()
        let quoteUseCase = GetQuoteUseCase(
            quoteRepository: MockQuoteRepository(couponRepository: MockCouponRepository(), walletRepository: MockWalletRepository()),
            catalogRepository: MockCatalogRepository(), circuitRepository: MockCircuitRepository(),
            vetServiceOverrideRepository: MockVetServiceOverrideRepository(),
            subscriptionRepository: subscriptionRepo, entitlementRepository: entitlementRepo)

        let service = MockData.services[0]
        let userId = UUID()
        let subscription = try await subscriptionRepo.subscribe(userId: userId, plan: .monthly)
        var cart = try await cartUseCase.current(userId: userId)
        let item = CartItem(id: UUID(), serviceId: service.id, variantId: service.variants[0].id, petIds: [UUID()])
        cart = try await cartUseCase.addItem(item, to: cart)

        // A fresh subscription's entitlement is lazily seeded with 1 credit
        // (mirrors a signup edge function granting one server-side) — the
        // quote flow should find and apply it without the caller ever
        // touching consumeCredit directly.
        let creditedQuote = try await quoteUseCase.execute(cart: cart)
        #expect(creditedQuote.breakdown.lineItems.contains { $0.amountMinorUnits == 0 && $0.label.contains(service.variants[0].name) })

        // Once the credit is actually spent, the next quote is priced normally.
        _ = try await entitlementRepo.consumeCredit(subscriptionId: subscription.id)
        let noCreditQuote = try await quoteUseCase.execute(cart: cart)
        #expect(noCreditQuote.breakdown.lineItems.first?.label == service.variants[0].name)

        // Without a subscription/entitlement wired at all, no credit applies either.
        let plainQuoteUseCase = GetQuoteUseCase(
            quoteRepository: MockQuoteRepository(couponRepository: MockCouponRepository(), walletRepository: MockWalletRepository()),
            catalogRepository: MockCatalogRepository(), circuitRepository: MockCircuitRepository(),
            vetServiceOverrideRepository: MockVetServiceOverrideRepository())
        let plainQuote = try await plainQuoteUseCase.execute(cart: cart)
        #expect(plainQuote.breakdown.lineItems.first?.label == service.variants[0].name)
    }
}

@Suite("EntitlementPolicy")
struct EntitlementPolicyTests {
    @Test("monthly/quarterly/annual each grant one credit per month")
    func individualPlansGrantOneCreditPerMonth() {
        #expect(EntitlementPolicy.creditsGrantedPerPeriod(plan: .monthly, seatCount: 1) == 1)
        #expect(EntitlementPolicy.creditsGrantedPerPeriod(plan: .quarterly, seatCount: 1) == 1)
        #expect(EntitlementPolicy.creditsGrantedPerPeriod(plan: .annual, seatCount: 1) == 1)
    }

    @Test("corporate grants one credit per seat")
    func corporateGrantsOneCreditPerSeat() {
        #expect(EntitlementPolicy.creditsGrantedPerPeriod(plan: .corporate, seatCount: 12) == 12)
    }

    @Test("a paused/cancelled subscription never gets a credit applied")
    func inactiveSubscriptionNeverGetsCredit() {
        var subscription = Subscription(id: UUID(), userId: UUID(), planType: .monthly, status: .paused, renewalDate: .now)
        let entitlement = SubscriptionEntitlement(id: UUID(), subscriptionId: subscription.id, creditsRemaining: 5, resetAt: .now.addingTimeInterval(86_400))
        #expect(EntitlementPolicy.canApplyCredit(subscription: subscription, entitlement: entitlement, now: .now) == false)

        subscription.status = .active
        #expect(EntitlementPolicy.canApplyCredit(subscription: subscription, entitlement: entitlement, now: .now) == true)
    }

    @Test("zero credits remaining and no reset due means no credit applies")
    func zeroCreditsNoResetDueMeansNoCredit() {
        let subscription = Subscription(id: UUID(), userId: UUID(), planType: .monthly, status: .active, renewalDate: .now)
        let entitlement = SubscriptionEntitlement(id: UUID(), subscriptionId: subscription.id, creditsRemaining: 0, resetAt: .now.addingTimeInterval(86_400))
        #expect(EntitlementPolicy.canApplyCredit(subscription: subscription, entitlement: entitlement, now: .now) == false)
    }

    @Test("a due reset rolls credits forward before the eligibility check")
    func dueResetRollsForwardBeforeCheck() {
        let subscription = Subscription(id: UUID(), userId: UUID(), planType: .monthly, status: .active, renewalDate: .now)
        let pastDue = SubscriptionEntitlement(id: UUID(), subscriptionId: subscription.id, creditsRemaining: 0, resetAt: .now.addingTimeInterval(-3600))
        #expect(EntitlementPolicy.canApplyCredit(subscription: subscription, entitlement: pastDue, now: .now) == true)

        let rolled = EntitlementPolicy.rolledForward(entitlement: pastDue, plan: subscription.planType, seatCount: subscription.seatCount, now: .now)
        #expect(rolled.creditsRemaining == 1)
        #expect(rolled.resetAt > .now)
    }
}

@Suite("PricingEngine entitlement credit")
struct PricingEngineEntitlementTests {
    @Test("an applied credit zeroes the base price but not add-ons")
    func creditZeroesBaseOnly() {
        let variant = MockData.services[0].variants[0]
        let addon = MockData.services[0].addons.first
        let input = PricingEngine.Input(variant: variant, addons: addon.map { [$0] } ?? [], additionalPetCount: 0,
                                        travelFeeMinorUnits: 0, entitlementCreditApplied: true)
        let breakdown = PricingEngine.quote(input)
        #expect(breakdown.lineItems.contains { $0.amountMinorUnits == 0 && $0.label.contains(variant.name) })
        if let addon {
            #expect(breakdown.lineItems.contains { $0.label == addon.name && $0.amountMinorUnits == addon.priceMinorUnits })
        }
    }
}

@Suite("HoldSlotUseCase")
struct HoldSlotUseCaseTests {
    @Test("places a hold on a slot with remaining capacity")
    func placesHold() async throws {
        let circuitRepo = MockCircuitRepository()
        let holdRepo = MockSlotHoldRepository()
        let useCase = HoldSlotUseCase(circuitRepository: circuitRepo, slotHoldRepository: holdRepo)
        let circuit = MockData.circuits[0]
        let slot = circuit.schedule.first { $0.isAvailable }!

        let hold = try await useCase.execute(circuitId: circuit.id, slotId: slot.id, userId: UUID())
        #expect(hold.slotId == slot.id)
        #expect(!hold.isExpired)
    }

    @Test("rejects a hold once concurrent holds exhaust remaining capacity")
    func rejectsWhenHoldsExhaustCapacity() async throws {
        let circuitRepo = MockCircuitRepository()
        let holdRepo = MockSlotHoldRepository()
        let useCase = HoldSlotUseCase(circuitRepository: circuitRepo, slotHoldRepository: holdRepo)
        let circuit = MockData.circuits[0]
        let slot = circuit.schedule.first { $0.isAvailable }!

        for _ in 0..<slot.remainingCapacity {
            _ = try await useCase.execute(circuitId: circuit.id, slotId: slot.id, userId: UUID())
        }

        await #expect(throws: DomainError.slotUnavailable) {
            _ = try await useCase.execute(circuitId: circuit.id, slotId: slot.id, userId: UUID())
        }
    }
}

@Suite("ManageAddressesUseCase")
struct ManageAddressesUseCaseTests {
    @Test("rejects an address with an empty line1")
    func rejectsEmptyLine1() async {
        let repo = MockAddressRepository()
        let useCase = ManageAddressesUseCase(addressRepository: repo)
        let address = Address(id: UUID(), ownerId: UUID(), label: "Home", line1: "  ",
                               line2: nil, landmark: nil, accessNotes: nil, latitude: 0, longitude: 0, clusterArea: nil)

        await #expect(throws: DomainError.self) {
            _ = try await useCase.add(address)
        }
    }

    @Test("matches a served cluster on add, and reports uncovered outside one")
    func matchesClusterOnAdd() async throws {
        let repo = MockAddressRepository()
        let useCase = ManageAddressesUseCase(addressRepository: repo)

        let served = Address(id: UUID(), ownerId: UUID(), label: "Home", line1: "14, 5th Cross",
                              line2: nil, landmark: nil, accessNotes: nil, latitude: 12.9352, longitude: 77.6146, clusterArea: nil)
        let saved = try await useCase.add(served)
        #expect(saved.isServed)
        #expect(saved.clusterArea == "Koramangala 5th Block")

        let uncovered = Address(id: UUID(), ownerId: UUID(), label: "Farmhouse", line1: "Middle of nowhere",
                                 line2: nil, landmark: nil, accessNotes: nil, latitude: 30.0, longitude: 70.0, clusterArea: nil)
        let savedUncovered = try await useCase.add(uncovered)
        #expect(!savedUncovered.isServed)
    }

    @Test("the first address added for an owner becomes their default")
    func firstAddressBecomesDefault() async throws {
        let repo = MockAddressRepository()
        let useCase = ManageAddressesUseCase(addressRepository: repo)
        let ownerId = UUID()
        let address = Address(id: UUID(), ownerId: ownerId, label: "Home", line1: "Line 1",
                               line2: nil, landmark: nil, accessNotes: nil, latitude: 12.9352, longitude: 77.6146, clusterArea: nil)
        let saved = try await useCase.add(address)
        #expect(saved.isDefault)
    }
}

@Suite("GetCatalogUseCase")
struct GetCatalogUseCaseTests {
    @Test("filters services to the requested vertical")
    func filtersByVertical() async throws {
        let repo = MockCatalogRepository()
        let useCase = GetCatalogUseCase(catalogRepository: repo)

        let vetServices = try await useCase.execute(vertical: .vet)
        #expect(!vetServices.isEmpty)
        #expect(vetServices.allSatisfy { $0.category.vertical == .vet })

        let physioServices = try await useCase.execute(vertical: .physio)
        #expect(physioServices.allSatisfy { $0.category.vertical == .physio })
    }

    @Test("excludes services a pet's species is ineligible for")
    func filtersBySpeciesEligibility() async throws {
        let repo = MockCatalogRepository()
        let useCase = GetCatalogUseCase(catalogRepository: repo)
        let dogOnly = Service(
            id: UUID(), category: .dental, name: "Dog dental",
            summary: "", variants: [ServiceVariant(id: UUID(), serviceId: UUID(), name: "Standard", durationMinutes: 20, priceMinorUnits: 100)],
            eligibility: ServiceEligibility(species: [.dog])
        )
        await repo.seed([dogOnly])

        let forCats = try await useCase.execute(vertical: .vet, forSpecies: .cat)
        #expect(forCats.isEmpty)

        let forDogs = try await useCase.execute(vertical: .vet, forSpecies: .dog)
        #expect(forDogs.contains { $0.id == dogOnly.id })
    }

    @Test("a service with no species restriction is eligible for every species")
    func unrestrictedServiceIsUniversallyEligible() {
        let eligibility = ServiceEligibility()
        for species in Pet.Species.allCases {
            #expect(eligibility.allows(species: species))
        }
    }
}

@Suite("ManageCartUseCase — D3/D6 add-ons and multi-pet lines")
struct ManageCartUseCaseAddonsAndMultiPetTests {
    @Test("addItem rejects a cart line with no pets")
    func rejectsEmptyPetSelection() async {
        let repo = MockCartRepository()
        let useCase = ManageCartUseCase(cartRepository: repo)
        let userId = UUID()
        let cart = try! await repo.currentCart(userId: userId)
        let item = CartItem(id: UUID(), serviceId: UUID(), variantId: UUID(), petIds: [])

        await #expect(throws: DomainError.validation("Choose at least one pet.")) {
            _ = try await useCase.addItem(item, to: cart)
        }
    }

    @Test("a cart line carries the selected add-ons and every selected pet")
    func addItemPersistsAddonsAndPets() async throws {
        let repo = MockCartRepository()
        let useCase = ManageCartUseCase(cartRepository: repo)
        let userId = UUID()
        let cart = try await repo.currentCart(userId: userId)
        let petIds = [UUID(), UUID()]
        let addonIds = [UUID()]
        let item = CartItem(id: UUID(), serviceId: UUID(), variantId: UUID(), petIds: petIds, addonIds: addonIds)

        let saved = try await useCase.addItem(item, to: cart)
        #expect(saved.items.first?.petIds.count == 2)
        #expect(saved.items.first?.addonIds == addonIds)
    }

    @Test("PricingEngine charges the reduced multi-pet rate, not the full base price, for the 2nd pet")
    func multiPetLinePricesTheSecondPetAtTheReducedRate() {
        let variant = ServiceVariant(id: UUID(), serviceId: UUID(), name: "Standard 20 min",
                                      durationMinutes: 20, priceMinorUnits: 59_900, additionalPetPriceMinorUnits: 29_900)
        let input = PricingEngine.Input(variant: variant, addons: [], additionalPetCount: 1, travelFeeMinorUnits: 0)
        let breakdown = PricingEngine.quote(input)

        #expect(breakdown.lineItems.contains { $0.label.hasPrefix("Additional pet") && $0.amountMinorUnits == 29_900 })
        #expect(breakdown.totalMinorUnits < (59_900 + 59_900) * 118 / 100) // cheaper than two full-price bookings, even after GST
    }
}

@Suite("Package — D4 packages/bundles")
struct PackageTests {
    private func makeCatalog() -> [Service] {
        [
            Service(id: UUID(), category: .consult, name: "Home consultation", summary: "",
                    variants: [ServiceVariant(id: UUID(), serviceId: UUID(), name: "Standard", durationMinutes: 20, priceMinorUnits: 59_900)]),
            Service(id: UUID(), category: .vaccination, name: "Vaccination", summary: "",
                    variants: [ServiceVariant(id: UUID(), serviceId: UUID(), name: "Single vaccine", durationMinutes: 15, priceMinorUnits: 49_900)]),
        ]
    }

    @Test("a package's discount is the saving vs. buying every included service separately")
    func discountReflectsSeparatePricing() {
        let catalog = makeCatalog()
        let package = Package(
            id: UUID(), name: "Puppy first-year", packageDescription: "",
            items: [
                PackageItem(id: UUID(), serviceId: catalog[0].id, quantity: 4),
                PackageItem(id: UUID(), serviceId: catalog[1].id, quantity: 3),
            ],
            priceMinorUnits: 349_900
        )
        // 4×599 + 3×499 = 2396 + 1497 = 3893 rupees separately, vs 3499 bundled.
        #expect(package.discountMinorUnits(catalog: catalog) == 389_300 - 349_900)
    }

    @Test("a package referencing an unknown service contributes nothing to the discount, never crashes")
    func discountIgnoresUnknownServices() {
        let package = Package(
            id: UUID(), name: "Mystery bundle", packageDescription: "",
            items: [PackageItem(id: UUID(), serviceId: UUID(), quantity: 2)],
            priceMinorUnits: 10_000
        )
        #expect(package.discountMinorUnits(catalog: []) == 0)
    }
}

@Suite("BuyPackageUseCase — D4 checkout stub")
struct BuyPackageUseCaseTests {
    @Test("buying a package adds one cart line per included service occurrence, for every selected pet")
    func expandsPackageIntoCartLines() async throws {
        let catalogRepo = MockCatalogRepository()
        let cartRepo = MockCartRepository()
        let userId = UUID()
        let consult = try await catalogRepo.listServices(vertical: .vet).first { $0.category == .consult }!
        let vaccination = try await catalogRepo.listServices(vertical: .vet).first { $0.category == .vaccination }!
        let packageRepo = MockPackageRepository()
        let package = try await packageRepo.listPackages(vertical: .vet).first { $0.name == "Puppy first-year" } ??
            Package(id: UUID(), name: "Test bundle", packageDescription: "",
                    items: [PackageItem(id: UUID(), serviceId: consult.id, quantity: 2),
                            PackageItem(id: UUID(), serviceId: vaccination.id, quantity: 1)],
                    priceMinorUnits: 100_000)

        let useCase = BuyPackageUseCase(packageRepository: packageRepo, catalogRepository: catalogRepo, cartRepository: cartRepo)
        let petIds = [UUID(), UUID()]
        let cart = try await useCase.execute(packageId: package.id, petIds: petIds, userId: userId)

        let expectedLineCount = package.items.reduce(0) { $0 + $1.quantity }
        #expect(cart.items.count == expectedLineCount)
        #expect(cart.items.allSatisfy { $0.petIds == petIds })
    }

    @Test("buying a package with no pets selected is rejected before touching the cart")
    func rejectsEmptyPetSelection() async {
        let packageRepo = MockPackageRepository()
        let catalogRepo = MockCatalogRepository()
        let cartRepo = MockCartRepository()
        let useCase = BuyPackageUseCase(packageRepository: packageRepo, catalogRepository: catalogRepo, cartRepository: cartRepo)
        let anyPackage = try! await packageRepo.listPackages(vertical: nil).first!

        await #expect(throws: DomainError.validation("Choose at least one pet.")) {
            _ = try await useCase.execute(packageId: anyPackage.id, petIds: [], userId: UUID())
        }
    }
}
// MARK: - H3: subscription management

@Suite("SubscriptionManagementPolicy")
struct SubscriptionManagementPolicyTests {
    private func subscription(plan: Subscription.PlanType, status: Subscription.Status, seatCount: Int = 1) -> Subscription {
        Subscription(id: UUID(), userId: UUID(), planType: plan, status: status, renewalDate: .now.addingTimeInterval(86400 * 20), seatCount: seatCount)
    }

    @Test("upgrading to a higher tier is allowed")
    func upgradeAllowed() {
        let sub = subscription(plan: .monthly, status: .active)
        #expect(SubscriptionManagementPolicy.validate(.upgrade, subscription: sub, targetPlan: .annual) == nil)
    }

    @Test("upgrading to a lower or equal tier is rejected")
    func upgradeToLowerRejected() {
        let sub = subscription(plan: .annual, status: .active)
        #expect(SubscriptionManagementPolicy.validate(.upgrade, subscription: sub, targetPlan: .monthly) != nil)
        #expect(SubscriptionManagementPolicy.validate(.upgrade, subscription: sub, targetPlan: .annual) != nil)
    }

    @Test("downgrading to a higher or equal tier is rejected")
    func downgradeToHigherRejected() {
        let sub = subscription(plan: .monthly, status: .active)
        #expect(SubscriptionManagementPolicy.validate(.downgrade, subscription: sub, targetPlan: .annual) != nil)
    }

    @Test("downgrading to a lower tier is allowed")
    func downgradeAllowed() {
        let sub = subscription(plan: .annual, status: .active)
        #expect(SubscriptionManagementPolicy.validate(.downgrade, subscription: sub, targetPlan: .monthly) == nil)
    }

    @Test("cannot change plan on a cancelled subscription")
    func cannotChangeCancelled() {
        let sub = subscription(plan: .monthly, status: .cancelled)
        #expect(SubscriptionManagementPolicy.validate(.upgrade, subscription: sub, targetPlan: .annual) != nil)
    }

    @Test("cannot upgrade/downgrade a corporate plan through the individual ladder")
    func corporateExcludedFromLadder() {
        let sub = subscription(plan: .corporate, status: .active, seatCount: 10)
        #expect(SubscriptionManagementPolicy.validate(.upgrade, subscription: sub, targetPlan: .annual) != nil)
        let individual = subscription(plan: .monthly, status: .active)
        #expect(SubscriptionManagementPolicy.validate(.upgrade, subscription: individual, targetPlan: .corporate) != nil)
    }

    @Test("pausing an active individual plan is allowed")
    func pauseAllowed() {
        let sub = subscription(plan: .monthly, status: .active)
        #expect(SubscriptionManagementPolicy.validate(.pause, subscription: sub) == nil)
    }

    @Test("pausing an already-paused or cancelled subscription is rejected")
    func pauseRejectedWhenNotActive() {
        #expect(SubscriptionManagementPolicy.validate(.pause, subscription: subscription(plan: .monthly, status: .paused)) != nil)
        #expect(SubscriptionManagementPolicy.validate(.pause, subscription: subscription(plan: .monthly, status: .cancelled)) != nil)
    }

    @Test("pausing a corporate plan with fewer than 5 seats is rejected — cancel instead")
    func pauseRejectedBelowCorporateSeatFloor() {
        let sub = subscription(plan: .corporate, status: .active, seatCount: 3)
        #expect(SubscriptionManagementPolicy.validate(.pause, subscription: sub) != nil)
    }

    @Test("pausing a corporate plan at or above 5 seats is allowed")
    func pauseAllowedAtCorporateSeatFloor() {
        let sub = subscription(plan: .corporate, status: .active, seatCount: 5)
        #expect(SubscriptionManagementPolicy.validate(.pause, subscription: sub) == nil)
    }

    @Test("resuming a paused subscription is allowed; resuming a non-paused one is rejected")
    func resumeRequiresPaused() {
        #expect(SubscriptionManagementPolicy.validate(.resume, subscription: subscription(plan: .monthly, status: .paused)) == nil)
        #expect(SubscriptionManagementPolicy.validate(.resume, subscription: subscription(plan: .monthly, status: .active)) != nil)
    }

    @Test("cancelling an already-cancelled subscription is rejected")
    func cancelIdempotencyGuard() {
        #expect(SubscriptionManagementPolicy.validate(.cancel, subscription: subscription(plan: .monthly, status: .cancelled)) != nil)
        #expect(SubscriptionManagementPolicy.validate(.cancel, subscription: subscription(plan: .monthly, status: .active)) == nil)
    }
}

@Suite("ManageSubscriptionUseCase")
struct ManageSubscriptionUseCaseTests {
    @Test("upgrade persists the new plan through the repository")
    func upgradePersists() async throws {
        let repo = MockSubscriptionRepository()
        let userId = UUID()
        _ = try await repo.subscribe(userId: userId, plan: .monthly)
        let useCase = ManageSubscriptionUseCase(subscriptionRepository: repo)
        let current = try await repo.currentSubscription(userId: userId)!
        let updated = try await useCase.upgrade(subscriptionId: current.id, userId: userId, to: .annual)
        #expect(updated.planType == .annual)
    }

    @Test("invalid downgrade throws and never touches the repository")
    func invalidDowngradeThrows() async throws {
        let repo = MockSubscriptionRepository()
        let userId = UUID()
        _ = try await repo.subscribe(userId: userId, plan: .monthly)
        let useCase = ManageSubscriptionUseCase(subscriptionRepository: repo)
        let current = try await repo.currentSubscription(userId: userId)!
        await #expect(throws: DomainError.self) {
            _ = try await useCase.downgrade(subscriptionId: current.id, userId: userId, to: .annual)
        }
        let unchanged = try await repo.currentSubscription(userId: userId)
        #expect(unchanged?.planType == .monthly)
    }

    @Test("pause then resume round-trips status")
    func pauseThenResume() async throws {
        let repo = MockSubscriptionRepository()
        let userId = UUID()
        _ = try await repo.subscribe(userId: userId, plan: .monthly)
        let useCase = ManageSubscriptionUseCase(subscriptionRepository: repo)
        let current = try await repo.currentSubscription(userId: userId)!
        let paused = try await useCase.pause(subscriptionId: current.id, userId: userId)
        #expect(paused.status == .paused)
        let resumed = try await useCase.resume(subscriptionId: current.id, userId: userId)
        #expect(resumed.status == .active)
    }

    @Test("cancel marks the subscription cancelled")
    func cancelMarksCancelled() async throws {
        let repo = MockSubscriptionRepository()
        let userId = UUID()
        _ = try await repo.subscribe(userId: userId, plan: .monthly)
        let useCase = ManageSubscriptionUseCase(subscriptionRepository: repo)
        let current = try await repo.currentSubscription(userId: userId)!
        try await useCase.cancel(subscriptionId: current.id, userId: userId)
        let after = try await repo.currentSubscription(userId: userId)
        #expect(after?.status == .cancelled)
    }

    @Test("acting on a subscription id that isn't the caller's throws notFound")
    func mismatchedSubscriptionIdThrows() async throws {
        let repo = MockSubscriptionRepository()
        let userId = UUID()
        _ = try await repo.subscribe(userId: userId, plan: .monthly)
        let useCase = ManageSubscriptionUseCase(subscriptionRepository: repo)
        await #expect(throws: DomainError.self) {
            _ = try await useCase.upgrade(subscriptionId: UUID(), userId: userId, to: .annual)
        }
    }
}

// MARK: - H5: dunning

@Suite("DunningPolicy")
struct DunningPolicyTests {
    @Test("first failed charge schedules a retry 1 day out")
    func firstFailureSchedulesRetryAt1Day() {
        let now = Date()
        let outcome = DunningPolicy.onChargeFailed(state: nil, subscriptionId: UUID(), now: now)
        guard case .retryScheduled(let state) = outcome else {
            Issue.record("expected retryScheduled")
            return
        }
        #expect(state.failedAttempts == 1)
        let expected = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        #expect(abs(state.nextRetryAt!.timeIntervalSince(expected)) < 1)
    }

    @Test("second and third failures follow the +3 and +7 day ladder")
    func subsequentFailuresFollowLadder() {
        let now = Date()
        let first = DunningState(subscriptionId: UUID(), failedAttempts: 1, nextRetryAt: now, gracePeriodEndsAt: nil)
        let secondOutcome = DunningPolicy.onChargeFailed(state: first, subscriptionId: first.subscriptionId, now: now)
        guard case .retryScheduled(let secondState) = secondOutcome else { Issue.record("expected retryScheduled"); return }
        #expect(secondState.failedAttempts == 2)
        #expect(abs(secondState.nextRetryAt!.timeIntervalSince(Calendar.current.date(byAdding: .day, value: 3, to: now)!)) < 1)

        let thirdOutcome = DunningPolicy.onChargeFailed(state: secondState, subscriptionId: first.subscriptionId, now: now)
        guard case .retryScheduled(let thirdState) = thirdOutcome else { Issue.record("expected retryScheduled"); return }
        #expect(thirdState.failedAttempts == 3)
        #expect(abs(thirdState.nextRetryAt!.timeIntervalSince(Calendar.current.date(byAdding: .day, value: 7, to: now)!)) < 1)
    }

    @Test("fourth failure exhausts the ladder and starts the grace period")
    func fourthFailureStartsGrace() {
        let now = Date()
        let third = DunningState(subscriptionId: UUID(), failedAttempts: 3, nextRetryAt: now, gracePeriodEndsAt: nil)
        let outcome = DunningPolicy.onChargeFailed(state: third, subscriptionId: third.subscriptionId, now: now)
        guard case .graceStarted(let state) = outcome else {
            Issue.record("expected graceStarted")
            return
        }
        #expect(state.failedAttempts == 4)
        #expect(state.nextRetryAt == nil)
        #expect(abs(state.gracePeriodEndsAt!.timeIntervalSince(Calendar.current.date(byAdding: .day, value: 7, to: now)!)) < 1)
    }

    @Test("auto-downgrade fires once grace has elapsed, not before")
    func autoDowngradeTiming() {
        let now = Date()
        let state = DunningState(subscriptionId: UUID(), failedAttempts: 4, nextRetryAt: nil, gracePeriodEndsAt: now.addingTimeInterval(3600))
        #expect(!DunningPolicy.shouldAutoDowngrade(state: state, now: now))
        #expect(DunningPolicy.shouldAutoDowngrade(state: state, now: now.addingTimeInterval(3601)))
    }

    @Test("a state with no grace period never auto-downgrades")
    func noGraceMeansNoDowngrade() {
        let state = DunningState(subscriptionId: UUID(), failedAttempts: 1, nextRetryAt: .now, gracePeriodEndsAt: nil)
        #expect(!DunningPolicy.shouldAutoDowngrade(state: state, now: .now.addingTimeInterval(86400 * 30)))
    }
}

@Suite("ChatPolicy")
struct ChatPolicyTests {
    private func makeVisit(status: Visit.VisitStatus, completedAt: Date?) -> Visit {
        Visit(id: UUID(), userId: UUID(), petId: UUID(), vetId: UUID(), circuitId: UUID(),
              status: status, scheduledAt: .now, completedAt: completedAt, notes: nil, paymentId: nil)
    }

    @Test("chat stays open for a non-completed visit regardless of time")
    func openWhileNotCompleted() {
        let visit = makeVisit(status: .enRoute, completedAt: nil)
        #expect(ChatPolicy.isOpen(visit: visit, now: .now.addingTimeInterval(86400 * 365)))
    }

    @Test("chat is open just under 48h after completion")
    func openJustUnder48h() {
        let completedAt = Date()
        let visit = makeVisit(status: .completed, completedAt: completedAt)
        let now = completedAt.addingTimeInterval(48 * 3600 - 1)
        #expect(ChatPolicy.isOpen(visit: visit, now: now))
    }

    @Test("chat is closed exactly at the 48h boundary")
    func closedAtBoundary() {
        let completedAt = Date()
        let visit = makeVisit(status: .completed, completedAt: completedAt)
        let now = completedAt.addingTimeInterval(48 * 3600)
        #expect(!ChatPolicy.isOpen(visit: visit, now: now))
    }

    @Test("chat is closed well after the 48h window")
    func closedLongAfter() {
        let completedAt = Date().addingTimeInterval(-86400 * 10)
        let visit = makeVisit(status: .completed, completedAt: completedAt)
        #expect(!ChatPolicy.isOpen(visit: visit, now: .now))
    }

    @Test("a completed visit with no completedAt timestamp defaults to open")
    func completedWithoutTimestampStaysOpen() {
        // Defensive default: missing data should never silently lock a
        // customer out of a chat they're entitled to.
        let visit = makeVisit(status: .completed, completedAt: nil)
        #expect(ChatPolicy.isOpen(visit: visit, now: .now))
    }
}

@Suite("ContactSupportUseCase")
struct ContactSupportUseCaseTests {
    @Test("rejects an empty subject")
    func rejectsEmptySubject() async {
        let useCase = ContactSupportUseCase(repository: MockSupportRepository())
        await #expect(throws: DomainError.self) {
            _ = try await useCase.execute(userId: UUID(), visitId: nil, subject: "   ", body: "It broke")
        }
    }

    @Test("rejects an empty body")
    func rejectsEmptyBody() async {
        let useCase = ContactSupportUseCase(repository: MockSupportRepository())
        await #expect(throws: DomainError.self) {
            _ = try await useCase.execute(userId: UUID(), visitId: nil, subject: "Refund", body: "")
        }
    }

    @Test("creates a ticket with trimmed subject/body and open status")
    func createsTicket() async throws {
        let useCase = ContactSupportUseCase(repository: MockSupportRepository())
        let userId = UUID()
        let ticket = try await useCase.execute(userId: userId, visitId: nil, subject: "  Refund  ", body: "  Payment charged twice  ")
        #expect(ticket.subject == "Refund")
        #expect(ticket.body == "Payment charged twice")
        #expect(ticket.status == .open)
        #expect(ticket.userId == userId)
    }

    @Test("a ticket opened from a visit carries that visit's id — this is how disputes are filed")
    func ticketCarriesVisitContext() async throws {
        let useCase = ContactSupportUseCase(repository: MockSupportRepository())
        let visitId = UUID()
        let ticket = try await useCase.execute(userId: UUID(), visitId: visitId, subject: "Vet arrived late", body: "40 minutes late, no notice")
        #expect(ticket.visitId == visitId)
    }

    @Test("myTickets only returns the calling user's tickets")
    func myTicketsScopedToUser() async throws {
        let repo = MockSupportRepository()
        let useCase = ContactSupportUseCase(repository: repo)
        let userA = UUID(), userB = UUID()
        _ = try await useCase.execute(userId: userA, visitId: nil, subject: "A", body: "A's issue")
        _ = try await useCase.execute(userId: userB, visitId: nil, subject: "B", body: "B's issue")

        let ticketsForA = try await useCase.myTickets(userId: userA)
        #expect(ticketsForA.count == 1)
        #expect(ticketsForA.first?.userId == userA)
    }
}

// MARK: - Pet health records (plan §3 B, §3 K)

@Suite("VaccinationPolicy & Vaccination due status")
struct VaccinationPolicyTests {
    @Test("suggests a next due date 12 months out by default")
    func annualBoosterDefault() {
        let given = Date(timeIntervalSince1970: 0)
        let nextDue = VaccinationPolicy.suggestedNextDueDate(givenAt: given)
        let expected = Calendar.current.date(byAdding: .month, value: 12, to: given)!
        #expect(nextDue == expected)
    }

    @Test("a vaccination well in the future is up to date")
    func upToDate() {
        let vaccination = Vaccination(id: UUID(), petId: UUID(), vaccineName: "Rabies",
                                       givenAt: .now, nextDueAt: .now.addingTimeInterval(86400 * 200))
        #expect(vaccination.dueStatus() == .upToDate)
    }

    @Test("a vaccination due within 30 days is flagged due-soon, not overdue")
    func dueSoon() {
        let vaccination = Vaccination(id: UUID(), petId: UUID(), vaccineName: "Rabies",
                                       givenAt: .now, nextDueAt: .now.addingTimeInterval(86400 * 10))
        #expect(vaccination.dueStatus() == .dueSoon)
    }

    @Test("a vaccination past its due date is overdue")
    func overdue() {
        let vaccination = Vaccination(id: UUID(), petId: UUID(), vaccineName: "Rabies",
                                       givenAt: .now.addingTimeInterval(-86400 * 400), nextDueAt: .now.addingTimeInterval(-86400))
        #expect(vaccination.dueStatus() == .overdue)
    }
}

@Suite("ManageVaccinationsUseCase")
struct ManageVaccinationsUseCaseTests {
    @Test("recording a vaccination auto-populates a suggested next-due date (K4)")
    func recordGivenAutoSchedulesNextDue() async throws {
        let repo = MockVaccinationRepository()
        let useCase = ManageVaccinationsUseCase(repository: repo)
        let petId = UUID()
        let givenAt = Date(timeIntervalSince1970: 1_700_000_000)

        let vaccination = try await useCase.recordGiven(petId: petId, vaccineName: "Rabies", givenAt: givenAt, batchNumber: "B-1", visitId: nil)

        let expected = Calendar.current.date(byAdding: .month, value: 12, to: givenAt)!
        #expect(vaccination.nextDueAt == expected)
    }

    @Test("nextActionable surfaces an overdue or due-soon vaccination, not an up-to-date one")
    func nextActionableSkipsUpToDate() async throws {
        let repo = MockVaccinationRepository()
        let petId = UUID()
        _ = try await repo.record(Vaccination(id: UUID(), petId: petId, vaccineName: "DHPPi",
                                               givenAt: .now, nextDueAt: .now.addingTimeInterval(86400 * 300)))
        let dueSoonVaccination = Vaccination(id: UUID(), petId: petId, vaccineName: "Rabies",
                                              givenAt: .now, nextDueAt: .now.addingTimeInterval(86400 * 5))
        _ = try await repo.record(dueSoonVaccination)

        let useCase = ManageVaccinationsUseCase(repository: repo)
        let actionable = try await useCase.nextActionable(petId: petId)
        #expect(actionable?.vaccineName == "Rabies")
    }
}

@Suite("ManagePetsUseCase archiving (B8)")
struct ManagePetsArchiveTests {
    @Test("archiving a pet excludes it from the default (booking-facing) list")
    func archivedPetExcludedByDefault() async throws {
        let repo = MockPetRepositoryForTests()
        let ownerId = UUID()
        let pet = Pet(id: UUID(), ownerId: ownerId, name: "Milo", species: .cat)
        _ = try await repo.addPet(pet)
        let useCase = ManagePetsUseCase(petRepository: repo)

        _ = try await useCase.archive(pet, reason: .rehomed)

        let activeList = try await useCase.list(ownerId: ownerId)
        #expect(activeList.isEmpty)

        let fullList = try await useCase.list(ownerId: ownerId, includeArchived: true)
        #expect(fullList.count == 1)
        #expect(fullList.first?.archiveReason == .rehomed)
    }

    @Test("unarchiving a pet returns it to the default list")
    func unarchiveRestoresPet() async throws {
        let repo = MockPetRepositoryForTests()
        let ownerId = UUID()
        let pet = Pet(id: UUID(), ownerId: ownerId, name: "Milo", species: .cat)
        _ = try await repo.addPet(pet)
        let useCase = ManagePetsUseCase(petRepository: repo)

        let archived = try await useCase.archive(pet, reason: .deceased)
        _ = try await useCase.unarchive(archived)

        let activeList = try await useCase.list(ownerId: ownerId)
        #expect(activeList.count == 1)
        #expect(activeList.first?.isArchived == false)
    }
}

/// A tiny in-memory `PetRepository` local to this test file — the app
/// target's `MockPetRepository` seeds from `MockData.user.pets`, which isn't
/// what these tests want to assert against.
actor MockPetRepositoryForTests: PetRepository {
    private var pets: [Pet] = []

    func listPets(ownerId: UUID) async throws -> [Pet] { pets.filter { $0.ownerId == ownerId } }

    func addPet(_ pet: Pet) async throws -> Pet {
        pets.append(pet)
        return pet
    }

    func updatePet(_ pet: Pet) async throws -> Pet {
        guard let index = pets.firstIndex(where: { $0.id == pet.id }) else { throw DomainError.notFound("Pet") }
        pets[index] = pet
        return pet
    }

    func deletePet(id: UUID) async throws {
        pets.removeAll { $0.id == id }
    }
}

@Suite("FollowUpBookingPolicy (K5)")
struct FollowUpBookingPolicyTests {
    @Test("a visit completed within the window is eligible for a free follow-up")
    func eligibleWithinWindow() {
        let visit = Visit(id: UUID(), userId: UUID(), petId: UUID(), vetId: UUID(), circuitId: UUID(),
                           status: .completed, scheduledAt: .now.addingTimeInterval(-86400 * 5),
                           completedAt: .now.addingTimeInterval(-86400 * 5), notes: nil, paymentId: nil)
        #expect(FollowUpBookingPolicy.isEligible(visit: visit))
    }

    @Test("a visit completed more than 14 days ago is not eligible")
    func ineligibleOutsideWindow() {
        let visit = Visit(id: UUID(), userId: UUID(), petId: UUID(), vetId: UUID(), circuitId: UUID(),
                           status: .completed, scheduledAt: .now.addingTimeInterval(-86400 * 20),
                           completedAt: .now.addingTimeInterval(-86400 * 20), notes: nil, paymentId: nil)
        #expect(!FollowUpBookingPolicy.isEligible(visit: visit))
    }

    @Test("a visit that hasn't completed yet is never eligible")
    func ineligibleWhenNotCompleted() {
        let visit = Visit(id: UUID(), userId: UUID(), petId: UUID(), vetId: UUID(), circuitId: UUID(),
                           status: .confirmed, scheduledAt: .now.addingTimeInterval(3600), completedAt: nil, notes: nil, paymentId: nil)
        #expect(!FollowUpBookingPolicy.isEligible(visit: visit))
    }
}

// MARK: - C3/C4: discovery filters & sort

@Suite("CircuitFilter")
struct CircuitFilterTests {
    private func makeCircuit(vet: Vet, slots: [ScheduleSlot] = []) -> Circuit {
        Circuit(id: UUID(), vetId: vet.id, vet: vet, clusterArea: "Test Area",
                schedule: slots.isEmpty ? [ScheduleSlot(id: UUID(), dayOfWeek: 2, startTime: .now.addingTimeInterval(3600), endTime: .now.addingTimeInterval(7200))] : slots)
    }

    @Test("an empty filter matches everything")
    func emptyFilterMatchesAll() {
        let vet = Vet(id: UUID(), name: "Dr. Test", licenseNumber: "VCI-1", verificationStatus: .verified, rating: 4.0, reviewCount: 1, photoURL: nil)
        #expect(CircuitFilter().matches(makeCircuit(vet: vet)))
    }

    @Test("rating filter excludes a lower-rated vet")
    func ratingFilterExcludesLowerRated() {
        let vet = Vet(id: UUID(), name: "Dr. Test", licenseNumber: "VCI-1", verificationStatus: .verified, rating: 3.5, reviewCount: 1, photoURL: nil)
        let filter = CircuitFilter(minRating: 4.0)
        #expect(!filter.matches(makeCircuit(vet: vet)))
    }

    @Test("species filter only matches a vet that handles that species")
    func speciesFilterMatchesHandledSpecies() {
        let vet = Vet(id: UUID(), name: "Dr. Test", licenseNumber: "VCI-1", verificationStatus: .verified,
                      rating: 4.5, reviewCount: 1, photoURL: nil, speciesHandled: [.dog])
        #expect(CircuitFilter(species: .dog).matches(makeCircuit(vet: vet)))
        #expect(!CircuitFilter(species: .cat).matches(makeCircuit(vet: vet)))
    }

    @Test("language filter is case-insensitive")
    func languageFilterCaseInsensitive() {
        let vet = Vet(id: UUID(), name: "Dr. Test", licenseNumber: "VCI-1", verificationStatus: .verified,
                      rating: 4.5, reviewCount: 1, photoURL: nil, languages: ["Hindi"])
        #expect(CircuitFilter(language: "hindi").matches(makeCircuit(vet: vet)))
        #expect(!CircuitFilter(language: "tamil").matches(makeCircuit(vet: vet)))
    }

    @Test("gender filter matches only the requested gender")
    func genderFilterMatches() {
        let vet = Vet(id: UUID(), name: "Dr. Test", licenseNumber: "VCI-1", verificationStatus: .verified,
                      rating: 4.5, reviewCount: 1, photoURL: nil, gender: .female)
        #expect(CircuitFilter(gender: .female).matches(makeCircuit(vet: vet)))
        #expect(!CircuitFilter(gender: .male).matches(makeCircuit(vet: vet)))
    }

    @Test("time-of-day filter requires at least one matching slot")
    func timeOfDayFilterRequiresMatchingSlot() {
        let vet = Vet(id: UUID(), name: "Dr. Test", licenseNumber: "VCI-1", verificationStatus: .verified, rating: 4.5, reviewCount: 1, photoURL: nil)
        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let morningSlot = ScheduleSlot(id: UUID(), dayOfWeek: 2,
                                        startTime: calendar.date(bySettingHour: 8, minute: 0, second: 0, of: .now)!,
                                        endTime: calendar.date(bySettingHour: 9, minute: 0, second: 0, of: .now)!)
        let circuit = makeCircuit(vet: vet, slots: [morningSlot])
        var filter = CircuitFilter()
        filter.timeOfDay = .morning
        #expect(filter.matches(circuit))
        filter.timeOfDay = .evening
        #expect(!filter.matches(circuit))
    }

    @Test("a circuit with no vet attached fails any vet-level filter rather than passing blindly")
    func noVetFailsVetLevelFilter() {
        let circuit = Circuit(id: UUID(), vetId: UUID(), vet: nil, clusterArea: "Test Area", schedule: [])
        #expect(!CircuitFilter(minRating: 4.0).matches(circuit))
    }

    @Test("apply filters a list down to only the matches")
    func applyFiltersList() {
        let verifiedGoodVet = Vet(id: UUID(), name: "A", licenseNumber: "VCI-1", verificationStatus: .verified, rating: 4.9, reviewCount: 1, photoURL: nil)
        let lowRatedVet = Vet(id: UUID(), name: "B", licenseNumber: "VCI-2", verificationStatus: .verified, rating: 3.0, reviewCount: 1, photoURL: nil)
        let circuits = [makeCircuit(vet: verifiedGoodVet), makeCircuit(vet: lowRatedVet)]
        let result = CircuitFilter.apply(CircuitFilter(minRating: 4.0), to: circuits)
        #expect(result.count == 1)
        #expect(result.first?.vetId == verifiedGoodVet.id)
    }
}

@Suite("CircuitSortOption")
struct CircuitSortOptionTests {
    @Test("topRated sorts by vet rating descending")
    func topRatedSortsDescending() {
        let lowVet = Vet(id: UUID(), name: "Low", licenseNumber: "VCI-1", verificationStatus: .verified, rating: 3.5, reviewCount: 1, photoURL: nil)
        let highVet = Vet(id: UUID(), name: "High", licenseNumber: "VCI-2", verificationStatus: .verified, rating: 4.9, reviewCount: 1, photoURL: nil)
        let circuits = [
            Circuit(id: UUID(), vetId: lowVet.id, vet: lowVet, clusterArea: "A", schedule: []),
            Circuit(id: UUID(), vetId: highVet.id, vet: highVet, clusterArea: "B", schedule: []),
        ]
        let sorted = CircuitSortOption.sort(circuits, by: .topRated)
        #expect(sorted.first?.vetId == highVet.id)
    }

    @Test("soonest sorts by earliest upcoming slot")
    func soonestSortsByEarliestSlot() {
        let vet = Vet(id: UUID(), name: "Test", licenseNumber: "VCI-1", verificationStatus: .verified, rating: 4.0, reviewCount: 1, photoURL: nil)
        let later = Circuit(id: UUID(), vetId: vet.id, vet: vet, clusterArea: "A",
                             schedule: [ScheduleSlot(id: UUID(), dayOfWeek: 2, startTime: .now.addingTimeInterval(7200), endTime: .now.addingTimeInterval(10800))])
        let sooner = Circuit(id: UUID(), vetId: vet.id, vet: vet, clusterArea: "B",
                              schedule: [ScheduleSlot(id: UUID(), dayOfWeek: 2, startTime: .now.addingTimeInterval(1800), endTime: .now.addingTimeInterval(3600))])
        let sorted = CircuitSortOption.sort([later, sooner], by: .soonest)
        #expect(sorted.first?.clusterArea == "B")
    }

    @Test("previouslyBooked ranks a previously-booked vet's circuit first")
    func previouslyBookedRanksFirst() {
        let newVet = Vet(id: UUID(), name: "New", licenseNumber: "VCI-1", verificationStatus: .verified, rating: 4.9, reviewCount: 1, photoURL: nil)
        let repeatVet = Vet(id: UUID(), name: "Repeat", licenseNumber: "VCI-2", verificationStatus: .verified, rating: 4.0, reviewCount: 1, photoURL: nil)
        let circuits = [
            Circuit(id: UUID(), vetId: newVet.id, vet: newVet, clusterArea: "A", schedule: []),
            Circuit(id: UUID(), vetId: repeatVet.id, vet: repeatVet, clusterArea: "B", schedule: []),
        ]
        let sorted = CircuitSortOption.sort(circuits, by: .previouslyBooked, previouslyBookedVetIds: [repeatVet.id])
        #expect(sorted.first?.vetId == repeatVet.id)
    }
}

@Suite("GetCircuitsUseCase verification filtering")
struct GetCircuitsUseCaseVerificationTests {
    @Test("filters out circuits whose vet isn't verified (L1/L3)")
    func excludesUnverifiedVets() async throws {
        let repo = MockCircuitRepository()
        let useCase = GetCircuitsUseCase(repository: repo)
        let circuits = try await useCase.execute(area: nil, vertical: .vet)
        #expect(!circuits.isEmpty)
        #expect(circuits.allSatisfy { $0.vet?.verificationStatus == .verified })
    }
}

// MARK: - C5: vet profile / ratings histogram

@Suite("GetVetProfileUseCase")
struct GetVetProfileUseCaseTests {
    @Test("histogram counts reviews per star and computes the average")
    func histogramCountsAndAverages() {
        let useCase = GetVetProfileUseCase(reviewRepository: MockReviewRepository())
        let vetId = UUID()
        let reviews = [5, 5, 4, 3, 5].map {
            Review(id: UUID(), visitId: UUID(), vetId: vetId, userId: UUID(), rating: $0, comment: nil, createdAt: .now)
        }
        let histogram = useCase.histogram(for: reviews)
        #expect(histogram.totalCount == 5)
        #expect(histogram.countByStars[5] == 3)
        #expect(histogram.countByStars[4] == 1)
        #expect(histogram.countByStars[3] == 1)
        #expect(abs(histogram.averageRating - 4.4) < 0.001)
    }

    @Test("an empty review list produces a zeroed histogram, not a crash")
    func emptyReviewsProduceZeroedHistogram() {
        let useCase = GetVetProfileUseCase(reviewRepository: MockReviewRepository())
        let histogram = useCase.histogram(for: [])
        #expect(histogram.totalCount == 0)
        #expect(histogram.averageRating == 0)
    }
}

// MARK: - C11: emergency path

@Suite("ListEmergencyClinicsUseCase")
struct ListEmergencyClinicsUseCaseTests {
    @Test("lists the mock clinic directory")
    func listsClinics() async throws {
        let useCase = ListEmergencyClinicsUseCase(repository: MockEmergencyClinicRepository())
        let clinics = try await useCase.execute()
        #expect(!clinics.isEmpty)
        #expect(clinics.allSatisfy { $0.isOpen24x7 })
    }

    @Test("sorts by proximity when a location is given")
    func sortsByProximity() async throws {
        let useCase = ListEmergencyClinicsUseCase(repository: MockEmergencyClinicRepository())
        let near = MockData.emergencyClinics[0]
        let clinics = try await useCase.execute(fromLatitude: near.latitude, longitude: near.longitude)
        #expect(clinics.first?.id == near.id)
    }
}

@Suite("FileIncidentReportUseCase / SOSUseCase")
struct IncidentReportUseCaseTests {
    @Test("rejects an empty description for a non-SOS report")
    func rejectsEmptyDescriptionForSafetyConcern() async {
        let useCase = FileIncidentReportUseCase(repository: MockIncidentReportRepository())
        await #expect(throws: DomainError.self) {
            _ = try await useCase.execute(visitId: UUID(), reporterId: UUID(), reporterRole: .customer,
                                           type: .safetyConcern, description: "   ")
        }
    }

    @Test("allows an empty description for an SOS report")
    func allowsEmptyDescriptionForSOS() async throws {
        let useCase = FileIncidentReportUseCase(repository: MockIncidentReportRepository())
        let report = try await useCase.execute(visitId: UUID(), reporterId: UUID(), reporterRole: .customer,
                                                type: .sos, description: "")
        #expect(report.type == .sos)
    }

    @Test("SOS use case files a report and returns a matching share link")
    func sosProducesReportAndShareLink() async throws {
        let visitId = UUID()
        let useCase = SOSUseCase(incidentReportRepository: MockIncidentReportRepository())
        let result = try await useCase.execute(visitId: visitId, reporterId: UUID(), reporterRole: .customer)
        #expect(result.report.type == .sos)
        #expect(result.report.visitId == visitId)
        #expect(result.shareLink.absoluteString == "vetcircuit://visit/\(visitId.uuidString)")
    }

    @Test("share link round-trips through the existing deep link parser")
    func shareLinkParsesBackToTheSameVisit() {
        let visitId = UUID()
        let link = ShareVisitLinkUseCase.link(visitId: visitId)
        #expect(DeepLinkParser.parse(link) == .visit(visitId))
    }
}
