import Foundation

// MARK: - Use cases: pure business logic, unit-testable without UI or network

struct GetCircuitsUseCase {
    let repository: CircuitRepository

    func execute(area: String?, vertical: Vertical = .vet) async throws -> [Circuit] {
        let circuits = try await repository.listCircuits(area: area)
        return circuits
            .filter { $0.vertical == vertical }
            .sorted { $0.clusterArea < $1.clusterArea }
    }
}

struct BookVisitUseCase {
    let visitRepository: VisitRepository

    /// The atomic `book_visit()` transaction (Appendix D): capacity-checked,
    /// idempotent by construction. `idempotencyKey` defaults to a fresh UUID
    /// per call so existing call sites keep working, but a real checkout flow
    /// should generate one client-side *once* per attempt and reuse it across
    /// retries — that's what makes a retried tap safe.
    func execute(petId: UUID, vetId: UUID, circuitId: UUID, slot: ScheduleSlot, idempotencyKey: String = UUID().uuidString) async throws -> Visit {
        guard slot.isAvailable else { throw DomainError.slotUnavailable }
        guard slot.startTime > Date() else {
            throw DomainError.validation("Please choose a slot in the future.")
        }
        return try await visitRepository.createVisit(petId: petId, vetId: vetId, circuitId: circuitId, slot: slot, idempotencyKey: idempotencyKey)
    }
}

struct CancelVisitUseCase {
    let visitRepository: VisitRepository
    let refundRepository: RefundRepository

    /// F4 + G4: cancellation policy as code — free >4h, 50% <4h, 100% charged
    /// on no-show — and the refund it implies is issued in the same call,
    /// never left as a manual follow-up.
    @discardableResult
    func execute(visitId: UUID, currentStatus: Visit.VisitStatus, scheduledAt: Date, paymentId: UUID?) async throws -> CancellationPolicy.Outcome {
        guard currentStatus == .requested || currentStatus == .confirmed else {
            throw DomainError.validation("This visit can no longer be cancelled.")
        }
        let paidMinorUnits = try await visitRepository.paidAmountMinorUnits(visitId: visitId)
        let outcome = CancellationPolicy.evaluate(scheduledAt: scheduledAt, paidMinorUnits: paidMinorUnits)
        try await visitRepository.cancelVisit(visitId: visitId)
        if outcome.refundMinorUnits > 0, let paymentId {
            _ = try await refundRepository.issueRefund(
                visitId: visitId, paymentId: paymentId, amountMinorUnits: outcome.refundMinorUnits,
                reason: "Customer cancellation", initiatedByOpsUserId: nil
            )
        }
        return outcome
    }

    /// Lets the UI show "Cancelling now refunds ₹X of ₹Y" (plan §9 rule 3)
    /// *before* the customer commits, without duplicating the policy logic.
    func preview(visitId: UUID, scheduledAt: Date) async throws -> CancellationPolicy.Outcome {
        let paidMinorUnits = try await visitRepository.paidAmountMinorUnits(visitId: visitId)
        return CancellationPolicy.evaluate(scheduledAt: scheduledAt, paidMinorUnits: paidMinorUnits)
    }
}

struct RescheduleVisitUseCase {
    let visitRepository: VisitRepository

    /// F3: reschedule with the same policy window as cancellation — inside
    /// 4 hours of the original slot, a reschedule isn't allowed (it would
    /// otherwise be a way to dodge the cancellation fee).
    func execute(visitId: UUID, currentScheduledAt: Date, newSlot: ScheduleSlot, now: Date = .now) async throws -> Visit {
        let hoursUntilVisit = currentScheduledAt.timeIntervalSince(now) / 3600
        guard hoursUntilVisit >= CancellationPolicy.freeWindowHours else {
            throw DomainError.validation("This visit is too close to reschedule — cancelling now follows the cancellation policy instead.")
        }
        guard newSlot.isAvailable, newSlot.startTime > now else {
            throw DomainError.slotUnavailable
        }
        return try await visitRepository.rescheduleVisit(visitId: visitId, newSlot: newSlot)
    }
}

struct GetVisitHistoryUseCase {
    let visitRepository: VisitRepository

    func execute(userId: UUID) async throws -> [Visit] {
        let visits = try await visitRepository.listVisits(userId: userId)
        return visits.sorted { $0.scheduledAt > $1.scheduledAt }
    }
}

struct SubscribeToPlanUseCase {
    let subscriptionRepository: SubscriptionRepository
    let paymentRepository: PaymentRepository

    func execute(userId: UUID, plan: Subscription.PlanType, seatCount: Int = 1) async throws -> URL {
        if plan.isBulk {
            guard seatCount >= 5 else {
                throw DomainError.validation("Corporate/RWA plans require at least 5 seats.")
            }
        }
        return try await paymentRepository.createCheckout(forSubscription: plan)
    }
}

struct SendChatMessageUseCase {
    let chatRepository: ChatRepository

    func execute(visitId: UUID, body: String) async throws -> ChatMessage {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DomainError.validation("Message can't be empty.")
        }
        guard trimmed.count <= 2000 else {
            throw DomainError.validation("Message is too long.")
        }
        return try await chatRepository.send(visitId: visitId, body: trimmed)
    }

    /// J2: a max size guard is the only client-side validation — the real
    /// content check (virus scan, format) happens in the storage bucket's
    /// trusted upload path, not here.
    func sendPhoto(visitId: UUID, imageData: Data) async throws -> ChatMessage {
        let maxBytes = 10 * 1024 * 1024
        guard !imageData.isEmpty else {
            throw DomainError.validation("Couldn't read that photo.")
        }
        guard imageData.count <= maxBytes else {
            throw DomainError.validation("Photo is too large — please choose one under 10MB.")
        }
        return try await chatRepository.sendPhoto(visitId: visitId, imageData: imageData)
    }
}

struct SubmitReviewUseCase {
    let reviewRepository: ReviewRepository

    func execute(visitId: UUID, rating: Int, comment: String?) async throws -> Review {
        guard (1...5).contains(rating) else {
            throw DomainError.validation("Rating must be between 1 and 5.")
        }
        return try await reviewRepository.submit(visitId: visitId, rating: rating, comment: comment)
    }
}

struct ManagePetsUseCase {
    let petRepository: PetRepository

    func list(ownerId: UUID) async throws -> [Pet] {
        try await petRepository.listPets(ownerId: ownerId)
    }

    func add(_ pet: Pet) async throws -> Pet {
        guard !pet.name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw DomainError.validation("Pet name is required.")
        }
        return try await petRepository.addPet(pet)
    }

    func remove(id: UUID) async throws {
        try await petRepository.deletePet(id: id)
    }
}

struct StartCheckoutUseCase {
    let paymentRepository: PaymentRepository

    func execute(visitId: UUID, amountMinorUnits: Int) async throws -> URL {
        guard amountMinorUnits > 0 else {
            throw DomainError.validation("Invalid amount.")
        }
        return try await paymentRepository.createCheckout(forVisit: visitId, amountMinorUnits: amountMinorUnits)
    }
}

// MARK: - V2 use cases

struct TrackVetUseCase {
    let liveTrackingRepository: LiveTrackingRepository

    func execute(visitId: UUID) async throws -> VetLocation? {
        try await liveTrackingRepository.currentLocation(visitId: visitId)
    }

    func subscribe(visitId: UUID, onUpdate: @escaping @Sendable (VetLocation) -> Void) -> AnyObject {
        liveTrackingRepository.subscribeToLocation(visitId: visitId, onUpdate: onUpdate)
    }
}

struct StartCallUseCase {
    let callRepository: CallRepository

    func execute(visitId: UUID) async throws -> URL {
        try await callRepository.startCall(visitId: visitId)
    }
}

struct GetLoyaltyAccountUseCase {
    let loyaltyRepository: LoyaltyRepository

    func execute(userId: UUID) async throws -> LoyaltyAccount {
        try await loyaltyRepository.account(userId: userId)
    }
}

struct ManageAccountDeletionUseCase {
    let accountRepository: AccountRepository
    let authRepository: AuthRepository

    /// A6: App Store guideline 5.1.1(v) — in-app account deletion, with a
    /// 30-day soft window during which the customer can cancel the request.
    func requestDeletion(userId: UUID) async throws -> DeletionRequest {
        try await accountRepository.requestDeletion(userId: userId)
    }

    func cancelPendingDeletion(userId: UUID) async throws {
        try await accountRepository.cancelDeletionRequest(userId: userId)
    }

    func pendingDeletion(userId: UUID) async throws -> DeletionRequest? {
        try await accountRepository.pendingDeletionRequest(userId: userId)
    }
}

struct ExportDataUseCase {
    let accountRepository: AccountRepository

    func execute(userId: UUID) async throws -> DataExport {
        try await accountRepository.exportData(userId: userId)
    }
}

struct StartVisitUseCase {
    let visitOTPRepository: VisitOTPRepository
    let visitRepository: VisitRepository

    /// I5: verifying the OTP is the only way a visit moves from `arrived`
    /// to `in_progress` — proof the vet is actually on-site with the customer.
    func verify(visitId: UUID, code: String) async throws -> Visit {
        guard code.count == 4, code.allSatisfy(\.isNumber) else {
            throw DomainError.validation("Enter the 4-digit code.")
        }
        let verified = try await visitOTPRepository.verifyOTP(visitId: visitId, code: code)
        guard verified else {
            throw DomainError.validation("That code doesn't match. Ask the vet to check with you.")
        }
        return try await visitRepository.updateStatus(visitId: visitId, status: .inProgress)
    }
}

struct ManageConsentUseCase {
    let consentRepository: ConsentRepository

    static let liabilityWaiverPurpose = "liability_waiver"
    static let currentWaiverVersion = "2026-09"

    func hasAcceptedLiabilityWaiver(userId: UUID) async throws -> Bool {
        let consents = try await consentRepository.activeConsents(userId: userId)
        return consents.contains { $0.purpose == Self.liabilityWaiverPurpose && $0.version == Self.currentWaiverVersion }
    }

    func acceptLiabilityWaiver(userId: UUID) async throws -> ConsentRecord {
        try await consentRepository.grant(userId: userId, purpose: Self.liabilityWaiverPurpose, version: Self.currentWaiverVersion)
    }
}

struct ManageCartUseCase {
    let cartRepository: CartRepository

    func current(userId: UUID) async throws -> Cart {
        try await cartRepository.currentCart(userId: userId)
    }

    func addItem(_ item: CartItem, to cart: Cart) async throws -> Cart {
        guard !item.petIds.isEmpty else {
            throw DomainError.validation("Choose at least one pet.")
        }
        var cart = cart
        cart.items.append(item)
        return try await cartRepository.save(cart)
    }

    func removeItem(id: UUID, from cart: Cart) async throws -> Cart {
        var cart = cart
        cart.items.removeAll { $0.id == id }
        return try await cartRepository.save(cart)
    }

    func clear(userId: UUID) async throws {
        try await cartRepository.clear(userId: userId)
    }
}

struct GetQuoteUseCase {
    let quoteRepository: QuoteRepository
    let catalogRepository: CatalogRepository

    /// E6: the app hands over its selections and gets back a signed,
    /// itemized, TTL'd quote — it never assembles a rupee amount itself.
    func execute(cart: Cart) async throws -> Quote {
        guard !cart.items.isEmpty else {
            throw DomainError.validation("Your cart is empty.")
        }
        let catalog = try await catalogRepository.listServices(vertical: nil)
        return try await quoteRepository.createQuote(for: cart, catalog: catalog)
    }
}

struct HoldSlotUseCase {
    let circuitRepository: CircuitRepository
    let slotHoldRepository: SlotHoldRepository

    /// E7: reserves a slot's capacity for 10 minutes during checkout so a
    /// slot can't be sold twice while one customer is mid-payment — the
    /// hold counts against remaining capacity the same as a confirmed
    /// booking would.
    func execute(circuitId: UUID, slotId: UUID, userId: UUID) async throws -> SlotHold {
        let circuit = try await circuitRepository.circuit(id: circuitId)
        guard let slot = circuit.schedule.first(where: { $0.id == slotId }) else {
            throw DomainError.notFound("Slot")
        }
        let activeHolds = try await slotHoldRepository.activeHolds(slotId: slotId)
        let effectiveRemaining = slot.capacity - slot.bookedCount - activeHolds.count
        guard effectiveRemaining > 0 else {
            throw DomainError.slotUnavailable
        }
        return try await slotHoldRepository.placeHold(slotId: slotId, userId: userId)
    }
}

struct ManageAddressesUseCase {
    let addressRepository: AddressRepository

    func list(ownerId: UUID) async throws -> [Address] {
        try await addressRepository.listAddresses(ownerId: ownerId)
    }

    /// Adding an address always runs the geofence check first, so the address
    /// is stored already knowing whether it's inside a served cluster — the
    /// UI never has to guess or re-derive that.
    func add(_ address: Address) async throws -> Address {
        guard !address.line1.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw DomainError.validation("Address line 1 is required.")
        }
        var address = address
        address.clusterArea = try await addressRepository.matchCluster(latitude: address.latitude, longitude: address.longitude)
        return try await addressRepository.addAddress(address)
    }

    func update(_ address: Address) async throws -> Address {
        try await addressRepository.updateAddress(address)
    }

    func remove(id: UUID) async throws {
        try await addressRepository.deleteAddress(id: id)
    }

    func setDefault(id: UUID, ownerId: UUID) async throws {
        try await addressRepository.setDefault(id: id, ownerId: ownerId)
    }
}

struct GetCatalogUseCase {
    let catalogRepository: CatalogRepository

    /// Services for a vertical, filtered to ones a given pet is actually
    /// eligible for (species gate) — showing an ineligible service just to
    /// hide it behind a disabled button is a worse experience than not
    /// listing it at all.
    func execute(vertical: Vertical, forSpecies species: Pet.Species? = nil) async throws -> [Service] {
        let services = try await catalogRepository.listServices(vertical: vertical)
        let eligible = species.map { s in services.filter { $0.eligibility.allows(species: s) } } ?? services
        return eligible.sorted { $0.name < $1.name }
    }
}

struct SendReferralUseCase {
    let referralRepository: ReferralRepository

    func execute(userId: UUID, phone: String) async throws -> Referral {
        let digitsOnly = phone.filter(\.isNumber)
        guard digitsOnly.count >= 10 else {
            throw DomainError.validation("Enter a valid phone number to invite.")
        }
        return try await referralRepository.sendInvite(userId: userId, phone: phone)
    }
}
