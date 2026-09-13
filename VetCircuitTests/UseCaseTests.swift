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

    @Test("rejects a quote for an empty cart")
    func rejectsEmptyCartQuote() async {
        let quoteUseCase = GetQuoteUseCase(quoteRepository: MockQuoteRepository(), catalogRepository: MockCatalogRepository())
        let emptyCart = Cart(id: UUID(), userId: UUID())

        await #expect(throws: DomainError.self) {
            _ = try await quoteUseCase.execute(cart: emptyCart)
        }
    }

    @Test("a real cart produces a signed, itemized, unexpired quote")
    func producesRealQuote() async throws {
        let cartRepo = MockCartRepository()
        let cartUseCase = ManageCartUseCase(cartRepository: cartRepo)
        let quoteUseCase = GetQuoteUseCase(quoteRepository: MockQuoteRepository(), catalogRepository: MockCatalogRepository())

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
