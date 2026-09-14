import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Use cases: pure business logic, unit-testable without UI or network

struct GetCircuitsUseCase {
    let repository: CircuitRepository
    /// F9: optional so existing call sites/tests that don't care about
    /// blackouts keep working unchanged — when present, circuits whose vet
    /// is currently on a blackout are excluded entirely.
    var vetBlackoutRepository: VetBlackoutRepository? = nil

    /// C3/C4: `filter` narrows the fetched list, `sort` orders what's left —
    /// both client-side over the already-fetched circuits (simpler than a
    /// server round trip per filter change, and still correct since a
    /// customer's whole area is a small list). `previouslyBookedVetIds`
    /// backs the "previously booked" sort without this use case needing its
    /// own visit-history dependency. `estimatedVisitDurationMinutes` +
    /// `slotBufferMinutes` back F8: each circuit's schedule is filtered so a
    /// still-empty slot within travel-buffer distance of an already-booked
    /// one on the same day isn't offered.
    func execute(
        area: String?, vertical: Vertical = .vet,
        filter: CircuitFilter = CircuitFilter(), sort: CircuitSortOption? = nil,
        catalog: [Service] = [], previouslyBookedVetIds: Set<UUID> = [],
        estimatedVisitDurationMinutes: Int = 30, slotBufferMinutes: Int = SlotBufferPolicy.defaultBufferMinutes,
        now: Date = .now
    ) async throws -> [Circuit] {
        let circuits = try await repository.listCircuits(area: area)
        var scoped = circuits.filter { $0.vertical == vertical }

        // F9: drop circuits whose vet is currently on a blackout window.
        if let vetBlackoutRepository {
            let vetIds = Array(Set(scoped.map { $0.vetId }))
            let blackouts = try await vetBlackoutRepository.blackouts(vetIds: vetIds)
            if !blackouts.isEmpty {
                scoped = scoped.filter { !VetBlackout.isVetBlackedOut(vetId: $0.vetId, blackouts: blackouts, on: now) }
            }
        }

        // F8: within each remaining circuit, don't offer a still-empty slot
        // that leaves the vet zero travel time after/before a booked one.
        scoped = scoped.map { circuit in
            var circuit = circuit
            circuit.schedule = SlotBufferPolicy.filterOfferableSlots(
                circuit.schedule, visitDurationMinutes: estimatedVisitDurationMinutes, bufferMinutes: slotBufferMinutes
            )
            return circuit
        }

        let filtered = CircuitFilter.apply(filter, to: scoped, catalog: catalog)
        if let sort {
            return CircuitSortOption.sort(filtered, by: sort, previouslyBookedVetIds: previouslyBookedVetIds)
        }
        return filtered.sorted { $0.clusterArea < $1.clusterArea }
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

/// F4: closes the "no-show detection still manual" gap the same way I8
/// closed its equivalent gap for `SendPostVisitSummaryUseCase` — client
/// detects it the next time it's open, de-duplicated locally via
/// `NoShowDetectionRepository`, rather than a server-side cron. A visit
/// stuck in `.requested`/`.confirmed` past `CancellationPolicy.noShowGraceMinutes`
/// was never assigned/started, so nothing else in the state machine will
/// ever move it off that status; this is what actually applies F4's
/// 100%-charged-on-no-show branch (`CancelVisitUseCase`'s `isPastVisitTime`
/// case) to it instead of leaving it open forever.
struct FlagVisitNoShowUseCase {
    let cancelVisitUseCase: CancelVisitUseCase
    let noShowDetectionRepository: NoShowDetectionRepository

    @discardableResult
    func execute(visit: Visit, now: Date = .now) async throws -> Bool {
        guard visit.status == .requested || visit.status == .confirmed else { return false }
        let minutesPastScheduled = now.timeIntervalSince(visit.scheduledAt) / 60
        guard minutesPastScheduled >= CancellationPolicy.noShowGraceMinutes else { return false }
        guard !(try await noShowDetectionRepository.hasFlagged(visitId: visit.id)) else { return false }
        try await cancelVisitUseCase.execute(
            visitId: visit.id, currentStatus: visit.status, scheduledAt: visit.scheduledAt, paymentId: visit.paymentId
        )
        try await noShowDetectionRepository.markFlagged(visitId: visit.id)
        return true
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

/// F6: vet-initiated reschedule — the customer accepts or declines a
/// vet-proposed slot. Accepting bypasses `RescheduleVisitUseCase`'s 4h
/// policy window entirely (the vet moved the slot, not the customer), and
/// declining awards a goodwill loyalty credit since the customer is now
/// inconvenienced through no fault of their own.
struct RespondToRescheduleProposalUseCase {
    let proposalRepository: RescheduleProposalRepository
    let visitRepository: VisitRepository
    let circuitRepository: CircuitRepository
    let loyaltyRepository: LoyaltyRepository

    @discardableResult
    func execute(proposal: RescheduleProposal, visit: Visit, accept: Bool) async throws -> RescheduleProposal {
        guard proposal.status == .pending, proposal.proposedByRole == .vet else {
            throw DomainError.validation("This proposal has already been responded to.")
        }
        let updated = try await proposalRepository.respond(id: proposal.id, accept: accept)
        if accept {
            let circuit = try await circuitRepository.circuit(id: visit.circuitId)
            guard let slot = circuit.schedule.first(where: { $0.id == proposal.proposedSlotId }) else {
                throw DomainError.notFound("Proposed slot")
            }
            // Vet-initiated, so the customer-side 4h policy window doesn't
            // apply here — go straight to the repository, not through
            // RescheduleVisitUseCase.execute's guard.
            _ = try await visitRepository.rescheduleVisit(visitId: visit.id, newSlot: slot)
        } else {
            _ = try await loyaltyRepository.awardPoints(userId: visit.userId, points: NoShowPolicy.goodwillCreditPoints)
        }
        return updated
    }
}

/// F7: no-show handling for both directions (Appendix B). Customer no-show
/// is reported vet-side (out of scope for this customer app); a *vet*
/// no-show is what the customer app itself needs to let a customer report
/// once the grace window has passed.
struct ReportVetNoShowUseCase {
    let visitRepository: VisitRepository
    let refundRepository: RefundRepository
    let loyaltyRepository: LoyaltyRepository

    @discardableResult
    func execute(visit: Visit, now: Date = .now) async throws -> NoShowPolicy.Outcome {
        guard visit.status == .assigned || visit.status == .enRoute else {
            throw DomainError.validation("This visit isn't in a state where a vet no-show can be reported.")
        }
        let minutesLate = now.timeIntervalSince(visit.scheduledAt) / 60
        guard minutesLate >= NoShowPolicy.vetGraceWindowMinutes else {
            throw DomainError.validation("Please wait a little longer before reporting a no-show.")
        }
        let paidMinorUnits = try await visitRepository.paidAmountMinorUnits(visitId: visit.id)
        let outcome = NoShowPolicy.vetNoShow(paidMinorUnits: paidMinorUnits)
        _ = try await visitRepository.updateStatus(visitId: visit.id, status: .noShowVet)
        if outcome.refundMinorUnits > 0, let paymentId = visit.paymentId {
            _ = try await refundRepository.issueRefund(
                visitId: visit.id, paymentId: paymentId, amountMinorUnits: outcome.refundMinorUnits,
                reason: "Vet no-show", initiatedByOpsUserId: nil
            )
        }
        if outcome.goodwillCreditPoints > 0 {
            _ = try await loyaltyRepository.awardPoints(userId: visit.userId, points: outcome.goodwillCreditPoints)
        }
        return outcome
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

/// H3: upgrade/downgrade/pause/resume/cancel, each validated against
/// `SubscriptionManagementPolicy` before touching the repository — the
/// repository is a dumb writer, the use case is where the real rules live.
struct ManageSubscriptionUseCase {
    let subscriptionRepository: SubscriptionRepository

    private func currentOrThrow(_ subscriptionId: UUID, userId: UUID) async throws -> Subscription {
        guard let subscription = try await subscriptionRepository.currentSubscription(userId: userId), subscription.id == subscriptionId else {
            throw DomainError.notFound("Subscription")
        }
        return subscription
    }

    func upgrade(subscriptionId: UUID, userId: UUID, to plan: Subscription.PlanType) async throws -> Subscription {
        let current = try await currentOrThrow(subscriptionId, userId: userId)
        if let error = SubscriptionManagementPolicy.validate(.upgrade, subscription: current, targetPlan: plan) { throw error }
        return try await subscriptionRepository.changePlan(subscriptionId: subscriptionId, to: plan)
    }

    func downgrade(subscriptionId: UUID, userId: UUID, to plan: Subscription.PlanType) async throws -> Subscription {
        let current = try await currentOrThrow(subscriptionId, userId: userId)
        if let error = SubscriptionManagementPolicy.validate(.downgrade, subscription: current, targetPlan: plan) { throw error }
        return try await subscriptionRepository.changePlan(subscriptionId: subscriptionId, to: plan)
    }

    func pause(subscriptionId: UUID, userId: UUID) async throws -> Subscription {
        let current = try await currentOrThrow(subscriptionId, userId: userId)
        if let error = SubscriptionManagementPolicy.validate(.pause, subscription: current) { throw error }
        return try await subscriptionRepository.pause(subscriptionId: subscriptionId)
    }

    func resume(subscriptionId: UUID, userId: UUID) async throws -> Subscription {
        let current = try await currentOrThrow(subscriptionId, userId: userId)
        if let error = SubscriptionManagementPolicy.validate(.resume, subscription: current) { throw error }
        return try await subscriptionRepository.resume(subscriptionId: subscriptionId)
    }

    func cancel(subscriptionId: UUID, userId: UUID) async throws {
        let current = try await currentOrThrow(subscriptionId, userId: userId)
        if let error = SubscriptionManagementPolicy.validate(.cancel, subscription: current) { throw error }
        try await subscriptionRepository.cancel(subscriptionId: subscriptionId)
    }
}

/// H5: dunning — surfaces the retry-ladder/grace state read-only ("payment
/// failed, retrying...") and, once grace has expired, performs the
/// auto-downgrade `DunningPolicy` calls for. The actual "a renewal charge
/// just failed" trigger is a gateway webhook (no gateway is wired into this
/// codebase), so `recordFailure` exists for that future caller/scheduled job
/// (plan §6.5) to invoke — this use case's real job today is reading and
/// resolving whatever dunning state already exists.
struct DunningStatusUseCase {
    let subscriptionRepository: SubscriptionRepository

    /// Called by the (not-yet-wired) renewal-failure webhook or a scheduled
    /// job each time a charge fails; advances the retry ladder into grace.
    @discardableResult
    func recordFailure(subscriptionId: UUID, now: Date = .now) async throws -> DunningPolicy.Outcome {
        let existing = try await subscriptionRepository.dunningState(subscriptionId: subscriptionId)
        let outcome = DunningPolicy.onChargeFailed(state: existing, subscriptionId: subscriptionId, now: now)
        switch outcome {
        case .retryScheduled(let state), .graceStarted(let state):
            try await subscriptionRepository.recordDunningState(state)
        case .downgraded:
            break
        }
        return outcome
    }

    /// Read-only status for the customer app: nil once there's no unresolved
    /// dunning state, otherwise the current retry/grace snapshot to show as
    /// "payment failed, retrying on <date>" / "your plan will downgrade on <date>".
    func currentStatus(subscriptionId: UUID) async throws -> DunningState? {
        try await subscriptionRepository.dunningState(subscriptionId: subscriptionId)
    }

    /// The scheduled job (plan §6.5) calls this once grace has elapsed with
    /// no successful charge — downgrades the subscription rather than
    /// leaving it past-due indefinitely, and clears the dunning state.
    @discardableResult
    func resolveIfGraceExpired(subscriptionId: UUID, now: Date = .now) async throws -> Bool {
        guard let state = try await subscriptionRepository.dunningState(subscriptionId: subscriptionId),
              DunningPolicy.shouldAutoDowngrade(state: state, now: now) else {
            return false
        }
        _ = try await subscriptionRepository.changePlan(subscriptionId: subscriptionId, to: DunningPolicy.downgradeTarget)
        try await subscriptionRepository.recordDunningState(DunningState(subscriptionId: subscriptionId, failedAttempts: 0, nextRetryAt: nil, gracePeriodEndsAt: nil))
        return true
    }
}

/// H4: renewal reminders (T-7, T-1). `RenewalReminderPolicy` decides whether
/// today is a reminder day; this wires that into the existing transactional
/// notification pipeline (J8) rather than inventing a second one. Like J8
/// itself, actually *invoking* this once a day is a scheduled job (plan
/// §6.5) — no cron exists in this codebase to call it, so it's exercised
/// from wherever a daily check will eventually live (or a test).
struct RenewalReminderUseCase {
    let sendTransactionalNotificationUseCase: SendTransactionalNotificationUseCase

    @discardableResult
    func execute(user: User, subscription: Subscription, now: Date = .now) async throws -> RenewalReminderPolicy.Stage? {
        guard subscription.status == .active, let stage = RenewalReminderPolicy.dueStage(renewalDate: subscription.renewalDate, now: now) else {
            return nil
        }
        let body: String = {
            switch stage {
            case .sevenDaysBefore: return "Your \(subscription.planType.displayName) plan renews in 7 days."
            case .oneDayBefore: return "Your \(subscription.planType.displayName) plan renews tomorrow."
            }
        }()
        _ = try await sendTransactionalNotificationUseCase.execute(user: user, category: .subscriptionRenewalDue, body: body)
        return stage
    }
}

/// H7: corporate/RWA seat assignment — the roster of who fills each of a
/// corporate subscription's billed seats.
struct ManageCorporateSeatsUseCase {
    let repository: CorporateSeatAssignmentRepository

    func list(subscriptionId: UUID) async throws -> [CorporateSeatAssignment] {
        try await repository.assignments(subscriptionId: subscriptionId)
    }

    func assign(subscriptionId: UUID, phone: String, seatCount: Int) async throws -> CorporateSeatAssignment {
        let trimmed = phone.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw DomainError.validation("Enter a phone number.") }
        return try await repository.assignSeat(subscriptionId: subscriptionId, phone: trimmed, seatCount: seatCount)
    }

    func unassign(id: UUID) async throws {
        try await repository.unassignSeat(id: id)
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

    /// L6: runs `comment` through `ReviewModerationPolicy` before it ever
    /// reaches the repository. Profanity rejects the submission outright;
    /// PII is auto-redacted in place; defamation-risk language is flagged
    /// (`needsModeration`) but never blocks — a false positive there must
    /// not silently eat a legitimate review.
    func execute(visitId: UUID, rating: Int, comment: String?) async throws -> Review {
        guard (1...5).contains(rating) else {
            throw DomainError.validation("Rating must be between 1 and 5.")
        }

        var moderatedComment = comment
        var needsModeration = false
        var flags: [String] = []

        if let comment, !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                let result = try ReviewModerationPolicy.moderate(comment)
                moderatedComment = result.text
                needsModeration = result.needsModeration
                flags = result.moderationFlags
            } catch ReviewModerationPolicy.Violation.profanity {
                throw DomainError.validation("Your review contains language we can't publish — please rephrase and try again.")
            }
        }

        return try await reviewRepository.submit(
            visitId: visitId, rating: rating, comment: moderatedComment,
            needsModeration: needsModeration, moderationFlags: flags
        )
    }
}

struct ManagePetsUseCase {
    let petRepository: PetRepository

    /// B8: archived pets are excluded by default — this is the single choke
    /// point that keeps them out of the booking "which pet" picker and out
    /// of vaccination-due nagging without every call site re-filtering.
    /// `includeArchived: true` is for the profile's pet-management screen,
    /// which still needs to show (and let someone unarchive) a past pet.
    func list(ownerId: UUID, includeArchived: Bool = false) async throws -> [Pet] {
        let pets = try await petRepository.listPets(ownerId: ownerId)
        return includeArchived ? pets : pets.filter { !$0.isArchived }
    }

    func add(_ pet: Pet) async throws -> Pet {
        guard !pet.name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw DomainError.validation("Pet name is required.")
        }
        return try await petRepository.addPet(pet)
    }

    func update(_ pet: Pet) async throws -> Pet {
        try await petRepository.updatePet(pet)
    }

    func remove(id: UUID) async throws {
        try await petRepository.deletePet(id: id)
    }

    /// B2: uploads a new pet photo, returning the pet with `photoURL` set.
    func updatePhoto(petId: UUID, data: Data) async throws -> Pet {
        try await petRepository.updatePhoto(petId: petId, data: data)
    }

    /// B8: soft-delete with sensitive copy handled at the call site — this
    /// just stamps the flag, never touches the pet's visit history.
    func archive(_ pet: Pet, reason: Pet.ArchiveReason, now: Date = .now) async throws -> Pet {
        var pet = pet
        pet.archivedAt = now
        pet.archiveReason = reason
        return try await petRepository.updatePet(pet)
    }

    func unarchive(_ pet: Pet) async throws -> Pet {
        var pet = pet
        pet.archivedAt = nil
        pet.archiveReason = nil
        return try await petRepository.updatePet(pet)
    }
}

// MARK: - Pet health records (plan §3 B, §3 K)

struct ManagePetWeightsUseCase {
    let repository: PetWeightRepository

    func history(petId: UUID) async throws -> [PetWeightEntry] {
        try await repository.history(petId: petId).sorted { $0.recordedAt < $1.recordedAt }
    }

    /// B3: `temperatureCelsius`/`heartRateBpm` are optional vitals beyond
    /// weight — an owner logging weight at home won't have a thermometer or
    /// stethoscope reading, so neither is required.
    func addEntry(petId: UUID, weightKg: Double, temperatureCelsius: Double? = nil, heartRateBpm: Int? = nil, recordedAt: Date = .now) async throws -> PetWeightEntry {
        guard weightKg > 0 else {
            throw DomainError.validation("Enter a valid weight.")
        }
        if let temperatureCelsius, !(30...45).contains(temperatureCelsius) {
            throw DomainError.validation("Enter a plausible temperature (30-45°C).")
        }
        if let heartRateBpm, !(20...300).contains(heartRateBpm) {
            throw DomainError.validation("Enter a plausible heart rate (20-300 bpm).")
        }
        return try await repository.addEntry(PetWeightEntry(id: UUID(), petId: petId, weightKg: weightKg, recordedAt: recordedAt,
                                                              temperatureCelsius: temperatureCelsius, heartRateBpm: heartRateBpm))
    }
}

/// B4 (P0): vaccination history plus the next-due computation that makes the
/// reminder loop ("repeat-purchase driver") actually happen.
struct ManageVaccinationsUseCase {
    let repository: VaccinationRepository

    func history(petId: UUID) async throws -> [Vaccination] {
        try await repository.history(petId: petId).sorted { $0.nextDueAt < $1.nextDueAt }
    }

    /// Marking a vaccine as given auto-populates `nextDueAt` (K4) rather
    /// than leaving the next booking to memory.
    func recordGiven(petId: UUID, vaccineName: String, givenAt: Date = .now, batchNumber: String?, visitId: UUID?) async throws -> Vaccination {
        let nextDueAt = VaccinationPolicy.suggestedNextDueDate(givenAt: givenAt)
        let vaccination = Vaccination(id: UUID(), petId: petId, vaccineName: vaccineName, givenAt: givenAt,
                                       nextDueAt: nextDueAt, batchNumber: batchNumber, visitId: visitId)
        return try await repository.record(vaccination)
    }

    /// Whichever upcoming/overdue vaccination the "book vaccination visit"
    /// 1-tap action should point at, or nil if this pet is fully up to date.
    func nextActionable(petId: UUID, now: Date = .now) async throws -> Vaccination? {
        let history = try await history(petId: petId)
        return history.first { $0.dueStatus(now: now) != .upToDate }
    }
}

/// K5: "book a follow-up in 1 tap" — pure eligibility check so
/// `VisitDetailView` can decide whether to show the button without
/// duplicating the 14-day window rule.
struct FollowUpBookingPolicy {
    static let windowDays = 14

    static func isEligible(visit: Visit, now: Date = .now) -> Bool {
        guard visit.status == .completed, let completedAt = visit.completedAt else { return false }
        let days = Calendar.current.dateComponents([.day], from: completedAt, to: now).day ?? .max
        return days <= windowDays
    }
}

// MARK: - B6: document vault use case

struct ManagePetDocumentsUseCase {
    let repository: PetDocumentRepository

    func list(petId: UUID) async throws -> [PetDocument] {
        try await repository.list(petId: petId).sorted { $0.uploadedAt > $1.uploadedAt }
    }

    func upload(petId: UUID, uploaderId: UUID, title: String, data: Data) async throws -> PetDocument {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw DomainError.validation("Give this document a title.")
        }
        guard !data.isEmpty else {
            throw DomainError.validation("That file looks empty.")
        }
        return try await repository.upload(petId: petId, uploaderId: uploaderId, title: trimmed, data: data)
    }

    func delete(id: UUID) async throws {
        try await repository.delete(id: id)
    }
}

// MARK: - B7: shareable pet health summary (PDF)

/// Renders a one-page PDF summary of a pet's health record — name, species,
/// breed, DOB, latest weight (plus trend context), vaccination status, and
/// chronic conditions/allergies — for boarding/travel/clinic referral (plan
/// §B7). Framework-native `UIGraphicsPDFRenderer`, no third-party dependency.
/// Pure rendering: the caller supplies the pet's already-fetched weight and
/// vaccination history rather than this use case reaching into repositories
/// itself, which keeps the layout logic directly testable (byte count/PDF
/// magic header) without spinning up mock repositories.
struct GeneratePetHealthSummaryUseCase {
    /// A4-sized page, matching the paper size boarding/travel/clinic staff
    /// are most likely to print this on.
    private let pageWidth: CGFloat = 595.2
    private let pageHeight: CGFloat = 841.8

    func execute(pet: Pet, weightHistory: [PetWeightEntry], vaccinations: [Vaccination], generatedAt: Date = .now) -> Data {
        #if canImport(UIKit)
        let pageRect = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        return renderer.pdfData { context in
            context.beginPage()
            draw(pet: pet, weightHistory: weightHistory, vaccinations: vaccinations, generatedAt: generatedAt, in: pageRect)
        }
        #else
        return Data()
        #endif
    }

    #if canImport(UIKit)
    private func draw(pet: Pet, weightHistory: [PetWeightEntry], vaccinations: [Vaccination], generatedAt: Date, in pageRect: CGRect) {
        let margin: CGFloat = 40
        var y: CGFloat = margin
        let contentWidth = pageRect.width - margin * 2

        let titleAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 22)]
        let headingAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 14)]
        let bodyAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 12)]
        let captionAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 10), .foregroundColor: UIColor.darkGray]

        func drawText(_ text: String, attrs: [NSAttributedString.Key: Any], spacingAfter: CGFloat = 6) {
            let bounds = (text as NSString).boundingRect(
                with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
                options: .usesLineFragmentOrigin, attributes: attrs, context: nil)
            (text as NSString).draw(in: CGRect(x: margin, y: y, width: contentWidth, height: bounds.height), withAttributes: attrs)
            y += bounds.height + spacingAfter
        }

        drawText("\(pet.name) — Health Summary", attrs: titleAttrs, spacingAfter: 4)
        drawText("Generated \(generatedAt.formatted(date: .abbreviated, time: .shortened)) · VetCircuit", attrs: captionAttrs, spacingAfter: 16)

        drawText("Pet details", attrs: headingAttrs, spacingAfter: 4)
        drawText("Species: \(pet.species.rawValue.capitalized)", attrs: bodyAttrs, spacingAfter: 2)
        if let breed = pet.breed, !breed.isEmpty {
            drawText("Breed: \(breed)", attrs: bodyAttrs, spacingAfter: 2)
        }
        if let dob = pet.dateOfBirth {
            drawText("Date of birth: \(dob.formatted(date: .abbreviated, time: .omitted))", attrs: bodyAttrs, spacingAfter: 2)
        }
        if let sex = pet.sex {
            drawText("Sex: \(sex.rawValue.capitalized)\(pet.isNeutered == true ? " (neutered/spayed)" : "")", attrs: bodyAttrs, spacingAfter: 2)
        }
        y += 8

        drawText("Weight", attrs: headingAttrs, spacingAfter: 4)
        if let latest = weightHistory.sorted(by: { $0.recordedAt < $1.recordedAt }).last {
            drawText("Latest: \(String(format: "%.1f", latest.weightKg)) kg (\(latest.recordedAt.formatted(date: .abbreviated, time: .omitted)))",
                      attrs: bodyAttrs, spacingAfter: 2)
        } else {
            drawText("No weight readings recorded.", attrs: bodyAttrs, spacingAfter: 2)
        }
        y += 8

        drawText("Vaccination status", attrs: headingAttrs, spacingAfter: 4)
        if vaccinations.isEmpty {
            drawText("No vaccination records.", attrs: bodyAttrs, spacingAfter: 2)
        } else {
            for vaccination in vaccinations.sorted(by: { $0.nextDueAt < $1.nextDueAt }) {
                let status: String
                switch vaccination.dueStatus(now: generatedAt) {
                case .upToDate: status = "up to date"
                case .dueSoon: status = "due soon"
                case .overdue: status = "overdue"
                }
                let given = vaccination.givenAt.map { "given \($0.formatted(date: .abbreviated, time: .omitted)), " } ?? ""
                drawText("\(vaccination.vaccineName) — \(given)next due \(vaccination.nextDueAt.formatted(date: .abbreviated, time: .omitted)) (\(status))",
                          attrs: bodyAttrs, spacingAfter: 2)
            }
        }
        y += 8

        drawText("Chronic conditions & allergies", attrs: headingAttrs, spacingAfter: 4)
        drawText("Chronic conditions: \(pet.chronicConditions?.isEmpty == false ? pet.chronicConditions! : "None recorded")", attrs: bodyAttrs, spacingAfter: 2)
        drawText("Allergies: \(pet.allergies?.isEmpty == false ? pet.allergies! : "None recorded")", attrs: bodyAttrs, spacingAfter: 2)
    }
    #endif
}

struct ManagePrescriptionsUseCase {
    let repository: PrescriptionRepository

    func history(petId: UUID) async throws -> [Prescription] {
        try await repository.history(petId: petId).sorted { $0.issuedAt > $1.issuedAt }
    }
}

/// F9: a vet's own leave/holiday windows. There's no vet-facing UI surface
/// in this app today (known gap — see TECHNICAL_PLAN.md's F9 row), so this
/// use case is exercised directly by tests/a future vet-side screen; its
/// *effect* on customer-facing availability is enforced in `GetCircuitsUseCase`.
struct ManageVetBlackoutsUseCase {
    let repository: VetBlackoutRepository

    func list(vetId: UUID) async throws -> [VetBlackout] {
        try await repository.blackouts(vetId: vetId).sorted { $0.startDate < $1.startDate }
    }

    func add(vetId: UUID, startDate: Date, endDate: Date, reason: String?) async throws -> VetBlackout {
        guard startDate <= endDate else {
            throw DomainError.validation("A blackout's end date must be on or after its start date.")
        }
        let blackout = VetBlackout(id: UUID(), vetId: vetId, startDate: startDate, endDate: endDate, reason: reason)
        return try await repository.create(blackout)
    }

    func remove(id: UUID) async throws {
        try await repository.delete(id: id)
    }
}

/// K3: medication reminders. Scheduling the actual local notifications is an
/// App-layer concern (`PushNotificationManager`, which already owns local
/// scheduling for renewal reminders) — this use case only owns the
/// CRUD + validation half so it stays framework-free and testable.
struct ManageMedicationRemindersUseCase {
    let repository: MedicationReminderRepository

    func list(petId: UUID) async throws -> [MedicationReminder] {
        try await repository.reminders(petId: petId).sorted { $0.medicationName < $1.medicationName }
    }

    func add(petId: UUID, medicationName: String, dosage: String, times: [TimeOfDay], startDate: Date, endDate: Date?) async throws -> MedicationReminder {
        guard !medicationName.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw DomainError.validation("Enter the medication name.")
        }
        guard !times.isEmpty else {
            throw DomainError.validation("Add at least one time of day.")
        }
        if let endDate { guard endDate >= startDate else { throw DomainError.validation("End date must be on or after the start date.") } }
        let reminder = MedicationReminder(id: UUID(), petId: petId, medicationName: medicationName, dosage: dosage,
                                           times: times, startDate: startDate, endDate: endDate, isActive: true)
        return try await repository.create(reminder)
    }

    func update(_ reminder: MedicationReminder) async throws -> MedicationReminder {
        try await repository.update(reminder)
    }

    func setActive(_ reminder: MedicationReminder, isActive: Bool) async throws -> MedicationReminder {
        var reminder = reminder
        reminder.isActive = isActive
        return try await repository.update(reminder)
    }

    func remove(id: UUID) async throws {
        try await repository.delete(id: id)
    }
}

/// E6: server-authoritative quote → checkout. The signature is the
/// enforcement: there is no overload that takes a raw amount, so a checkout
/// can only ever be started with a real, server-issued `Quote` — never a
/// client-computed rupee figure (Appendix C's central rule, applied at the
/// one place money actually changes hands).
struct StartCheckoutUseCase {
    let paymentRepository: PaymentRepository

    func execute(visitId: UUID, quote: Quote) async throws -> URL {
        guard !quote.isExpired else {
            throw DomainError.validation("This price quote has expired — refresh it and try again.")
        }
        guard quote.breakdown.totalMinorUnits > 0 else {
            throw DomainError.validation("Invalid amount.")
        }
        return try await paymentRepository.createCheckout(forVisit: visitId, quoteId: quote.id, amountMinorUnits: quote.breakdown.totalMinorUnits)
    }
}

/// E6/G6: pure decision logic for what the booking pipeline does once it
/// observes a payment's current status, kept free of I/O so the state
/// machine is directly unit-testable. Reuses `PaymentRetryPolicy` for the
/// retry-cap decision rather than duplicating it.
enum BookingCheckoutOutcome: Equatable {
    /// Payment succeeded — attach it to the visit and show confirmation.
    case confirmVisit
    /// No decision yet: the webhook hasn't landed, or the customer backed
    /// out of the checkout webview before finishing. The visit stays
    /// `requested` (never silently lost) so checkout can be resumed later.
    case awaitingPayment
    /// Payment failed or was refunded — a visit is never created/confirmed
    /// off a charge that didn't go through.
    case paymentFailed(canRetry: Bool, reason: String?)
}

struct BookingCheckoutPolicy {
    static func outcome(forPaymentStatus status: Payment.Status, priorAttempts: Int) -> BookingCheckoutOutcome {
        switch status {
        case .succeeded:
            return .confirmVisit
        case .pending:
            return .awaitingPayment
        case .failed:
            let retry = PaymentRetryPolicy.evaluate(status: status, priorAttempts: priorAttempts)
            return .paymentFailed(canRetry: retry.canRetry, reason: retry.reason)
        case .refunded:
            return .paymentFailed(canRetry: false, reason: "This payment was refunded.")
        }
    }
}

/// E6+E8+E10+G6: the one coordinating use case that turns a signed `Quote`
/// into a confirmed, payment-linked `Visit` — the pipeline this gap was
/// about. It composes `BookVisitUseCase`'s atomic (E7-hold-respecting)
/// booking, `StartCheckoutUseCase`'s quote-gated checkout, and
/// `VisitRepository.attachPayment`'s confirmation step, so `BookingView`/
/// `CartView` never have to get that ordering right themselves.
///
/// The visit is created *before* payment (status `.requested`) because
/// `PaymentRepository.createCheckout(forVisit:...)`'s own signature already
/// requires a visit id to check out against — there is no "pay first, then
/// create the visit" path available at the repository boundary. A payment
/// that never completes just leaves an uncompleted `.requested` visit
/// behind rather than losing the booking outright; `resolve` is what the UI
/// calls (on checkout-sheet dismissal, or on reopening the app) to find out
/// what actually happened and, only on `.succeeded`, confirm it.
struct BookingCheckoutUseCase {
    let bookVisitUseCase: BookVisitUseCase
    let startCheckoutUseCase: StartCheckoutUseCase
    let visitRepository: VisitRepository
    let paymentRepository: PaymentRepository

    struct Session {
        var visit: Visit
        var checkoutURL: URL
    }

    /// Step 1: book the visit (pending payment) and start checkout against
    /// the given signed quote. `StartCheckoutUseCase` itself rejects an
    /// expired quote, so a stale quote fails here rather than silently
    /// booking at the wrong price.
    func start(petId: UUID, vetId: UUID, circuitId: UUID, slot: ScheduleSlot, quote: Quote, idempotencyKey: String) async throws -> Session {
        let visit = try await bookVisitUseCase.execute(petId: petId, vetId: vetId, circuitId: circuitId, slot: slot, idempotencyKey: idempotencyKey)
        let checkoutURL = try await startCheckoutUseCase.execute(visitId: visit.id, quote: quote)
        return Session(visit: visit, checkoutURL: checkoutURL)
    }

    /// Step 2: after the checkout webview closes (success, failure, or the
    /// customer just backing out), find out what actually happened and, on
    /// success, confirm + link the payment to the visit.
    func resolve(visitId: UUID, priorAttempts: Int) async throws -> (visit: Visit, outcome: BookingCheckoutOutcome) {
        guard let paymentId = try await paymentRepository.latestPaymentId(forVisit: visitId) else {
            return (try await visitRepository.visit(id: visitId), .awaitingPayment)
        }
        let status = try await paymentRepository.paymentStatus(paymentId: paymentId)
        let outcome = BookingCheckoutPolicy.outcome(forPaymentStatus: status, priorAttempts: priorAttempts)
        if case .confirmVisit = outcome {
            let visit = try await visitRepository.attachPayment(visitId: visitId, paymentId: paymentId)
            return (visit, outcome)
        }
        return (try await visitRepository.visit(id: visitId), outcome)
    }
}

/// G3: payment retry on failure, with a clear stopping point instead of an
/// endless "try again" loop — `PaymentRetryPolicy` decides whether another
/// attempt is even offered before this ever calls the gateway again.
struct RetryPaymentUseCase {
    let paymentRepository: PaymentRepository

    /// Mid-checkout retry (`BookingView`/`CartView`, still holding the
    /// original `Quote`): a retry there is still a new order and must stay
    /// gated on a real, unexpired, signed quote (Appendix C).
    func execute(visitId: UUID, paymentId: UUID, quote: Quote, priorAttempts: Int) async throws -> URL {
        let status = try await paymentRepository.paymentStatus(paymentId: paymentId)
        let outcome = PaymentRetryPolicy.evaluate(status: status, priorAttempts: priorAttempts)
        guard outcome.canRetry else {
            throw DomainError.validation(outcome.reason ?? "This payment can't be retried right now.")
        }
        guard !quote.isExpired else {
            throw DomainError.validation("This price quote has expired — refresh it and try again.")
        }
        return try await paymentRepository.createCheckout(forVisit: visitId, quoteId: quote.id, amountMinorUnits: quote.breakdown.totalMinorUnits)
    }

    /// Post-booking retry (`VisitDetailView`, no quote in scope): re-charges
    /// the same already-agreed amount for an existing payment — no new quote
    /// is being negotiated here.
    func execute(visitId: UUID, paymentId: UUID, amountMinorUnits: Int, priorAttempts: Int) async throws -> URL {
        let status = try await paymentRepository.paymentStatus(paymentId: paymentId)
        let outcome = PaymentRetryPolicy.evaluate(status: status, priorAttempts: priorAttempts)
        guard outcome.canRetry else {
            throw DomainError.validation(outcome.reason ?? "This payment can't be retried right now.")
        }
        return try await paymentRepository.createCheckout(forVisit: visitId, retryingPaymentId: paymentId, amountMinorUnits: amountMinorUnits)
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

    func execute(visitId: UUID) async throws -> CallSession {
        try await callRepository.startCall(visitId: visitId)
    }
}

struct GetLoyaltyAccountUseCase {
    let loyaltyRepository: LoyaltyRepository

    func execute(userId: UUID) async throws -> LoyaltyAccount {
        try await loyaltyRepository.account(userId: userId)
    }
}

/// E5: loyalty point redemption — validates against the caller's own real
/// balance (never a client-supplied one) before asking the repository to
/// perform the redemption.
struct RedeemLoyaltyPointsUseCase {
    let loyaltyRepository: LoyaltyRepository

    func execute(userId: UUID, points: Int) async throws -> LoyaltyAccount {
        let account = try await loyaltyRepository.account(userId: userId)
        if let error = LoyaltyRedemptionPolicy.validate(points: points, availablePoints: account.points) {
            throw error
        }
        return try await loyaltyRepository.redeemPoints(userId: userId, points: points)
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

/// A5: edit profile (name, email, photo, language).
struct EditProfileUseCase {
    let accountRepository: AccountRepository

    func updateProfile(_ user: User, name: String, email: String?, language: String?) async throws -> User {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw DomainError.validation("Enter your name.")
        }
        if let email, !email.isEmpty {
            guard email.contains("@"), email.contains(".") else {
                throw DomainError.validation("Enter a valid email address.")
            }
        }
        var updated = user
        updated.name = trimmedName
        updated.email = (email?.isEmpty ?? true) ? nil : email
        updated.preferredLanguage = language
        return try await accountRepository.updateProfile(updated)
    }

    func updatePhoto(userId: UUID, data: Data) async throws -> User {
        try await accountRepository.updatePhoto(userId: userId, data: data)
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

    /// E1: change quantity — a line's quantity can never drop below 1
    /// (that's what "remove" is for) or be set to something absurd.
    func setQuantity(_ quantity: Int, forItemId id: UUID, in cart: Cart) async throws -> Cart {
        guard (1...20).contains(quantity) else {
            throw DomainError.validation("Quantity must be between 1 and 20.")
        }
        var cart = cart
        guard let index = cart.items.firstIndex(where: { $0.id == id }) else {
            throw DomainError.notFound("Cart item")
        }
        cart.items[index].quantity = quantity
        return try await cartRepository.save(cart)
    }

    func clear(userId: UUID) async throws {
        try await cartRepository.clear(userId: userId)
    }
}

struct GetQuoteUseCase {
    let quoteRepository: QuoteRepository
    let catalogRepository: CatalogRepository
    let circuitRepository: CircuitRepository
    let vetServiceOverrideRepository: VetServiceOverrideRepository
    // H6: optional so existing call sites/tests that don't care about
    // entitlements keep working — without these, a quote is priced with no
    // credit applied, same as before this feature existed.
    var subscriptionRepository: SubscriptionRepository? = nil
    var entitlementRepository: SubscriptionEntitlementRepository? = nil

    /// E6: the app hands over its selections and gets back a signed,
    /// itemized, TTL'd quote — it never assembles a rupee amount itself.
    /// D5: the booking vet's price overrides (if the cart is on a circuit)
    /// are fetched and threaded through so the quote reflects the vet's own
    /// pricing rather than always the catalog default.
    /// `cart.couponCode` and `useWalletBalance` are the customer's *intent*;
    /// the repository (server-side in the Supabase path) is what actually
    /// re-validates the coupon and looks up the real wallet balance before
    /// folding either into the signed total (Appendix C). H6: if the user
    /// separately has an active subscription with a credit left this period,
    /// the quote also comes back with the base price zeroed — this only
    /// *asks* for that (see `QuoteRepository.createQuote`'s doc comment);
    /// the server independently re-checks and is the one that actually
    /// spends the credit.
    func execute(cart: Cart, useWalletBalance: Bool = false) async throws -> Quote {
        guard !cart.items.isEmpty else {
            throw DomainError.validation("Your cart is empty.")
        }
        let catalog = try await catalogRepository.listServices(vertical: nil)
        var overrides: [VetServiceOverride] = []
        if let circuitId = cart.circuitId {
            let circuit = try await circuitRepository.circuit(id: circuitId)
            overrides = try await vetServiceOverrideRepository.overrides(vetId: circuit.vetId)
        }
        let applyCredit = await entitlementEligible(userId: cart.userId)
        return try await quoteRepository.createQuote(for: cart, catalog: catalog, overrides: overrides, useWalletBalance: useWalletBalance, applyEntitlementCredit: applyCredit)
    }

    private func entitlementEligible(userId: UUID) async -> Bool {
        guard let subscriptionRepository, let entitlementRepository else { return false }
        guard let subscription = try? await subscriptionRepository.currentSubscription(userId: userId),
              subscription.status == .active,
              let entitlement = try? await entitlementRepository.currentEntitlement(subscriptionId: subscription.id)
        else { return false }
        return EntitlementPolicy.canApplyCredit(subscription: subscription, entitlement: entitlement, now: .now)
    }
}

struct GetWalletBalanceUseCase {
    let walletRepository: WalletRepository

    func balance(userId: UUID) async throws -> Int {
        try await walletRepository.balanceMinorUnits(userId: userId)
    }

    func entries(userId: UUID) async throws -> [WalletLedgerEntry] {
        try await walletRepository.entries(userId: userId)
    }
}

struct ApplyCouponUseCase {
    let couponRepository: CouponRepository

    /// E4: validation happens against the real cart total, not a
    /// client-guessed one — a coupon that would out-discount the cart (or
    /// has expired/hit its usage limit) simply comes back nil rather than
    /// letting the client decide it "should" apply (plan §N2 stacking rules
    /// live entirely server-side in validate_coupon()).
    func execute(code: String, userId: UUID, cartTotalMinorUnits: Int) async throws -> Coupon {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DomainError.validation("Enter a promo code.")
        }
        guard let coupon = try await couponRepository.validate(code: trimmed, userId: userId, cartTotalMinorUnits: cartTotalMinorUnits) else {
            throw DomainError.validation("That code isn't valid for this order.")
        }
        return coupon
    }
}

struct TipUseCase {
    let paymentRepository: PaymentRepository

    static let presetAmountsMinorUnits = [5_000, 10_000, 15_000] // ₹50/₹100/₹150

    /// E11: a tip is 100% the vet's — no platform cut, unlike a regular
    /// visit's ~70% split (0014_payouts.sql credit_vet_on_visit_completed).
    /// The credit itself happens server-side (a trigger on this payment
    /// row, see 0028_tips.sql) once the tip payment succeeds.
    func execute(visitId: UUID, amountMinorUnits: Int) async throws -> URL {
        guard amountMinorUnits > 0, amountMinorUnits <= 50_000_00 else {
            throw DomainError.validation("Enter a tip amount between ₹1 and ₹50,000.")
        }
        return try await paymentRepository.createTipCheckout(forVisit: visitId, amountMinorUnits: amountMinorUnits)
    }
}

/// F5: create/manage a recurring booking rule. Spawning the actual next
/// visit each cycle is a scheduled-job concern (plan §6.5-style), not
/// something a client app can run itself while backgrounded — known gap,
/// tracked in TECHNICAL_PLAN.md's F5 row.
struct ManageRecurringBookingUseCase {
    let recurringBookingRuleRepository: RecurringBookingRuleRepository

    func execute(userId: UUID, petId: UUID, serviceId: UUID, variantId: UUID, circuitId: UUID, cadence: RecurringBookingRule.Cadence, firstOccurrenceAt: Date) async throws -> RecurringBookingRule {
        let rule = RecurringBookingRule(
            id: UUID(), userId: userId, petId: petId, serviceId: serviceId, variantId: variantId,
            circuitId: circuitId, cadence: cadence, nextOccurrenceAt: firstOccurrenceAt, isActive: true
        )
        return try await recurringBookingRuleRepository.create(rule)
    }

    func list(userId: UUID) async throws -> [RecurringBookingRule] {
        try await recurringBookingRuleRepository.rules(userId: userId)
    }

    func setActive(id: UUID, isActive: Bool) async throws -> RecurringBookingRule {
        try await recurringBookingRuleRepository.setActive(id: id, isActive: isActive)
    }

    func cancel(id: UUID) async throws {
        try await recurringBookingRuleRepository.delete(id: id)
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

/// C7: map view of cluster coverage — a thin read-only wrapper, same shape as
/// `GetLabTestReportsUseCase`, so the presentation layer never talks to
/// `AddressRepository` directly for something it only ever reads.
struct GetServedClustersUseCase {
    let addressRepository: AddressRepository

    func execute() async throws -> [ServedCluster] {
        try await addressRepository.listServedClusters()
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

struct BrowsePackagesUseCase {
    let packageRepository: PackageRepository

    func execute(vertical: Vertical?) async throws -> [Package] {
        try await packageRepository.listPackages(vertical: vertical)
    }
}

/// D4 stub: buying a package expands it into one cart line per included
/// service occurrence (its cheapest variant, for every selected pet) so the
/// customer reaches the same checkout/quote path as an à la carte booking.
/// Full redemption/entitlement tracking — crediting "3 of 4 visits used"
/// against future bookings instead of charging each one — is out of scope
/// here; see Appendix F gap list.
struct BuyPackageUseCase {
    let packageRepository: PackageRepository
    let catalogRepository: CatalogRepository
    let cartRepository: CartRepository

    func execute(packageId: UUID, petIds: [UUID], userId: UUID) async throws -> Cart {
        guard !petIds.isEmpty else {
            throw DomainError.validation("Choose at least one pet.")
        }
        let package = try await packageRepository.package(id: packageId)
        var cart = try await cartRepository.currentCart(userId: userId)
        for item in package.items {
            let service = try await catalogRepository.service(id: item.serviceId)
            guard let variant = service.variants.first else { continue }
            for _ in 0..<item.quantity {
                cart.items.append(CartItem(id: UUID(), serviceId: service.id, variantId: variant.id, petIds: petIds))
            }
        }
        return try await cartRepository.save(cart)
    }
}

/// N1: fraud guard — pure, so it's covered by unit tests without spinning
/// up a repository. Blocks the two cheapest ways to farm referral rewards:
/// inviting your own number, and re-inviting a number you've already
/// invited (each of those would otherwise mint a fresh `pending` reward
/// attempt for free). A per-day cap keeps a compromised/scripted account
/// from spamming invites.
enum ReferralFraudGuard {
    static let maxInvitesPerDay = 10

    enum Violation: LocalizedError, Equatable {
        case selfReferral
        case alreadyInvited
        case dailyLimitExceeded

        var errorDescription: String? {
            switch self {
            case .selfReferral: return "You can't refer your own number."
            case .alreadyInvited: return "You've already invited this number."
            case .dailyLimitExceeded: return "You've reached today's invite limit — try again tomorrow."
            }
        }
    }

    static func normalize(_ phone: String) -> String { phone.filter(\.isNumber).suffix(10).description }

    static func validate(invitePhone: String, referrerPhone: String?, existingReferrals: [Referral], now: Date = .now) throws {
        let normalizedInvite = normalize(invitePhone)
        if let referrerPhone, normalize(referrerPhone) == normalizedInvite {
            throw Violation.selfReferral
        }
        if existingReferrals.contains(where: { normalize($0.invitedPhone ?? "") == normalizedInvite }) {
            throw Violation.alreadyInvited
        }
        let calendar = Calendar.current
        let todaysInvites = existingReferrals.filter { calendar.isDate($0.createdAt, inSameDayAs: now) }.count
        if todaysInvites >= maxInvitesPerDay {
            throw Violation.dailyLimitExceeded
        }
    }
}

struct SendReferralUseCase {
    let referralRepository: ReferralRepository

    /// `referrerPhone` and `existingReferrals` drive `ReferralFraudGuard` —
    /// both optional/defaulted so existing call sites that don't pass them
    /// still work, same pattern as `GetQuoteUseCase`'s optional H6 params.
    func execute(userId: UUID, phone: String, referrerPhone: String? = nil, existingReferrals: [Referral] = []) async throws -> Referral {
        let digitsOnly = phone.filter(\.isNumber)
        guard digitsOnly.count >= 10 else {
            throw DomainError.validation("Enter a valid phone number to invite.")
        }
        try ReferralFraudGuard.validate(invitePhone: phone, referrerPhone: referrerPhone, existingReferrals: existingReferrals)
        return try await referralRepository.sendInvite(userId: userId, phone: phone)
    }
}

/// O1: per-category push preferences.
struct ManageNotificationPreferencesUseCase {
    let repository: NotificationPreferencesRepository

    func load(userId: UUID) async throws -> NotificationPreferences {
        try await repository.preferences(userId: userId)
    }

    func save(_ preferences: NotificationPreferences) async throws -> NotificationPreferences {
        try await repository.save(preferences)
    }
}

/// O7/O8: evaluated once at launch against the running app's
/// `CFBundleShortVersionString` — the single gate `RootView` checks before
/// showing sign-in or the tab bar.

/// O7/O8: evaluated once at launch against the running app's
/// `CFBundleShortVersionString` — the single gate `RootView` checks before
/// showing sign-in or the tab bar.
/// C11: fetches the emergency clinic directory, closest-first — pure
/// straight-line distance is good enough for "which is nearest", the same
/// tradeoff `MockAddressRepository.matchCluster` makes for geofencing.
struct ListEmergencyClinicsUseCase {
    let repository: EmergencyClinicRepository

    func execute(fromLatitude latitude: Double? = nil, longitude: Double? = nil) async throws -> [EmergencyClinic] {
        let clinics = try await repository.listClinics()
        guard let latitude, let longitude else { return clinics }
        func distanceSquared(_ clinic: EmergencyClinic) -> Double {
            let dLat = clinic.latitude - latitude
            let dLng = clinic.longitude - longitude
            return dLat * dLat + dLng * dLng
        }
        return clinics.sorted { distanceSquared($0) < distanceSquared($1) }
    }
}

/// C5: assembles the ratings histogram for a vet's profile from raw reviews
/// — kept as pure domain logic so the histogram math is unit-testable
/// without rendering a single pixel.
struct GetVetProfileUseCase {
    let reviewRepository: ReviewRepository

    struct RatingsHistogram: Equatable {
        /// Count of reviews per star rating, 1...5.
        var countByStars: [Int: Int]
        var totalCount: Int
        var averageRating: Double
    }

    func reviews(vetId: UUID) async throws -> [Review] {
        try await reviewRepository.reviews(vetId: vetId)
    }

    func histogram(for reviews: [Review]) -> RatingsHistogram {
        var counts: [Int: Int] = [1: 0, 2: 0, 3: 0, 4: 0, 5: 0]
        for review in reviews {
            let clamped = min(5, max(1, review.rating))
            counts[clamped, default: 0] += 1
        }
        let total = reviews.count
        let average = total == 0 ? 0 : Double(reviews.map(\.rating).reduce(0, +)) / Double(total)
        return RatingsHistogram(countByStars: counts, totalCount: total, averageRating: average)
    }
}

struct CheckAppConfigUseCase {
    let repository: AppConfigRepository

    enum Gate: Equatable {
        case ok
        case maintenance(message: String?)
        case forceUpgrade(minVersion: String)
    }

    func execute(currentVersion: String) async -> Gate {
        guard let config = try? await repository.fetchConfig() else {
            // Fail open: an unreachable config endpoint must never itself
            // become an outage (plan §7 — kill switches must fail safe).
            return .ok
        }
        if config.isMaintenanceMode {
            return .maintenance(message: config.maintenanceMessage)
        }
        if !RemoteAppConfig.isSupported(currentVersion: currentVersion, minSupportedVersion: config.minSupportedVersion) {
            return .forceUpgrade(minVersion: config.minSupportedVersion)
        }
        return .ok
    }
}

// MARK: - Help centre, support tickets & notification centre (plan §M, §J7)

struct GetHelpArticlesUseCase {
    let repository: HelpRepository

    func execute() async throws -> [HelpArticle] {
        try await repository.listArticles()
    }
}

struct ContactSupportUseCase {
    let repository: SupportRepository

    /// M2/K8: a ticket must actually say something — an empty subject/body
    /// reaches the ops queue as noise a human then has to triage away.
    func execute(userId: UUID, visitId: UUID?, subject: String, body: String) async throws -> SupportTicket {
        let subject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subject.isEmpty else { throw DomainError.validation("Please add a subject.") }
        guard !body.isEmpty else { throw DomainError.validation("Please describe what happened.") }
        return try await repository.createTicket(userId: userId, visitId: visitId, subject: subject, body: body)
    }

    func myTickets(userId: UUID) async throws -> [SupportTicket] {
        try await repository.myTickets(userId: userId)
    }
}

struct GetNotificationCenterUseCase {
    let repository: AppNotificationRepository

    func execute(userId: UUID) async throws -> [AppNotification] {
        try await repository.notifications(userId: userId)
    }

    func markRead(id: UUID) async throws {
        try await repository.markRead(id: id)
    }
}


/// O7/O8: evaluated once at launch against the running app's
/// `CFBundleShortVersionString` — the single gate `RootView` checks before
/// showing sign-in or the tab bar.
// MARK: - A9 household

struct ManageHouseholdUseCase {
    let householdRepository: HouseholdRepository

    func current(userId: UUID) async throws -> Household? {
        try await householdRepository.myHousehold(userId: userId)
    }

    func create(name: String, ownerId: UUID) async throws -> Household {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw DomainError.validation("Give your household a name.")
        }
        return try await householdRepository.createHousehold(name: trimmed, ownerId: ownerId)
    }

    func members(householdId: UUID) async throws -> [HouseholdMember] {
        try await householdRepository.members(householdId: householdId)
    }

    func invite(householdId: UUID, phone: String) async throws -> HouseholdMember {
        let digitsOnly = phone.filter(\.isNumber)
        guard digitsOnly.count >= 10 else {
            throw DomainError.validation("Enter a valid phone number to invite.")
        }
        return try await householdRepository.invite(householdId: householdId, phone: phone)
    }

    func removeMember(householdId: UUID, memberId: UUID) async throws {
        try await householdRepository.removeMember(householdId: householdId, memberId: memberId)
    }
}

// MARK: - C8 search

/// Client-facing entry point for "search by vet name, service, symptom"
/// (plan §3 C8) — fans a single query out across circuits (vet/area) and the
/// service catalog, since a customer doesn't know or care which table their
/// term matches.
struct SearchUseCase {
    let circuitRepository: CircuitRepository
    let catalogRepository: CatalogRepository

    struct Result {
        var circuits: [Circuit]
        var services: [Service]
    }

    func execute(term: String, vertical: Vertical) async throws -> Result {
        guard !term.trimmingCharacters(in: .whitespaces).isEmpty else {
            return Result(circuits: [], services: [])
        }
        async let circuits = circuitRepository.searchCircuits(term: term, area: nil)
        async let services = catalogRepository.searchServices(term: term, vertical: vertical)
        return try await Result(
            circuits: circuits.filter { $0.vertical == vertical },
            services: services
        )
    }
}

// MARK: - C9 rebook last visit

/// "Rebook last visit" — plan §3 C9 calls this the highest-converting
/// element in repeat marketplaces. Pulls the most recent *completed* visit
/// (not just most recent by date, which could be a future booking) and
/// resolves the circuit it belongs to so the UI can jump straight into
/// `BookingView` pre-filled with the same circuit/pet.
struct RebookLastVisitUseCase {
    let visitRepository: VisitRepository
    let circuitRepository: CircuitRepository

    struct Suggestion {
        var visit: Visit
        var circuit: Circuit
    }

    func execute(userId: UUID) async throws -> Suggestion? {
        let visits = try await visitRepository.listVisits(userId: userId)
        guard let lastCompleted = visits
            .filter({ $0.status == .completed })
            .sorted(by: { ($0.completedAt ?? $0.scheduledAt) > ($1.completedAt ?? $1.scheduledAt) })
            .first
        else { return nil }
        let circuit = try await circuitRepository.circuit(id: lastCompleted.circuitId)
        return Suggestion(visit: lastCompleted, circuit: circuit)
    }
}

// MARK: - C10 waitlist

struct JoinWaitlistUseCase {
    let waitlistRepository: WaitlistRepository

    func execute(userId: UUID, addressId: UUID?, latitude: Double, longitude: Double, areaLabel: String?) async throws -> WaitlistEntry {
        try await waitlistRepository.join(userId: userId, addressId: addressId, latitude: latitude, longitude: longitude, areaLabel: areaLabel)
    }

    /// "N neighbours already waiting" — deliberately excludes the caller's
    /// own just-joined entry from the displayed count would require a
    /// second round trip; the plan's copy ("N neighbours") already implies
    /// *other* people, so callers should join first, then read this against
    /// the same radius used at join time.
    func neighbourCount(latitude: Double, longitude: Double, radiusKm: Double = 3.0) async throws -> Int {
        try await waitlistRepository.countNear(latitude: latitude, longitude: longitude, radiusKm: radiusKm)
    }

    func hasJoined(userId: UUID, addressId: UUID?) async throws -> Bool {
        try await waitlistRepository.hasJoined(userId: userId, addressId: addressId)
    }
}

// MARK: - L4/L5: incident reporting + SOS
//
// SOS is not a separate model — pressing it files the same `IncidentReport`
// with `type == .sos`, so it shows up in the exact same reporter-facing and
// (eventually) ops-facing queue as a filed-after-the-fact safety concern,
// rather than a disconnected alert nobody reviews after the moment passes.

struct FileIncidentReportUseCase {
    let repository: IncidentReportRepository

    /// SOS carries no free-text requirement (someone in danger doesn't stop
    /// to type first) — every other type does.
    func execute(visitId: UUID, reporterId: UUID, reporterRole: IncidentReport.ReporterRole,
                 type: IncidentReport.IncidentType, description: String) async throws -> IncidentReport {
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if type != .sos {
            guard !description.isEmpty else { throw DomainError.validation("Please describe what happened.") }
        }
        let report = IncidentReport(id: UUID(), visitId: visitId, reporterId: reporterId, reporterRole: reporterRole,
                                     type: type, description: description, createdAt: .now)
        return try await repository.fileReport(report)
    }

    func myReports(reporterId: UUID) async throws -> [IncidentReport] {
        try await repository.myReports(reporterId: reporterId)
    }
}

/// L4: pressing SOS both logs the incident and hands back a link a trusted
/// contact can open to see the visit's live status — two outcomes from one
/// tap, since the plan is explicit that a stranger being in a home is not a
/// moment to make someone fill out a form before help is on the way.
struct SOSUseCase {
    let incidentReportRepository: IncidentReportRepository

    struct Result {
        var report: IncidentReport
        var shareLink: URL
    }

    func execute(visitId: UUID, reporterId: UUID, reporterRole: IncidentReport.ReporterRole) async throws -> Result {
        let report = try await FileIncidentReportUseCase(repository: incidentReportRepository)
            .execute(visitId: visitId, reporterId: reporterId, reporterRole: reporterRole, type: .sos, description: "")
        let link = ShareVisitLinkUseCase.link(visitId: visitId)
        return Result(report: report, shareLink: link)
    }
}

/// L4: builds the `vetcircuit://visit/<id>` deep link `DeepLinkParser`
/// already understands (N7) — reused here rather than inventing a second
/// link format, so a trusted contact who opens it lands exactly where the
/// existing deep-link routing sends anyone else.
enum ShareVisitLinkUseCase {
    static func link(visitId: UUID) -> URL {
        URL(string: "vetcircuit://visit/\(visitId.uuidString)")!
    }

    static func shareMessage(visitId: UUID) -> String {
        "I'm on a VetCircuit home visit right now — track it live: \(link(visitId: visitId).absoluteString)"
    }
}

// MARK: - E9: saved payment methods

struct ManageSavedPaymentMethodsUseCase {
    let repository: SavedPaymentMethodRepository

    func list(userId: UUID) async throws -> [SavedPaymentMethod] {
        try await repository.list(userId: userId)
    }

    /// `gatewayTokenId`/`displayLabel` are handed back by the gateway SDK's
    /// tokenization step (not yet wired into this codebase) — this use case
    /// never sees, and never accepts, raw card/UPI details.
    @discardableResult
    func save(userId: UUID, gatewayTokenId: String, displayLabel: String, makeDefault: Bool = false) async throws -> SavedPaymentMethod {
        guard !gatewayTokenId.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw DomainError.validation("Missing payment token from gateway.")
        }
        return try await repository.save(userId: userId, gatewayTokenId: gatewayTokenId, displayLabel: displayLabel, makeDefault: makeDefault)
    }

    func remove(id: UUID) async throws {
        try await repository.remove(id: id)
    }

    func setDefault(id: UUID, userId: UUID) async throws {
        try await repository.setDefault(id: id, userId: userId)
    }
}

// MARK: - M4: support-issued refund/credit, with audit trail

struct IssueSupportRefundUseCase {
    let repository: SupportRefundAuditRepository

    @discardableResult
    func execute(
        ticketId: UUID, visitId: UUID, issuedByUserId: UUID,
        kind: SupportRefundAudit.Kind, amountMinorUnits: Int, reason: String
    ) async throws -> SupportRefundAudit {
        guard amountMinorUnits > 0 else {
            throw DomainError.validation("Enter an amount greater than zero.")
        }
        guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DomainError.validation("A reason is required for the audit trail.")
        }
        return try await repository.issueSupportRefund(
            ticketId: ticketId, visitId: visitId, issuedByUserId: issuedByUserId,
            kind: kind, amountMinorUnits: amountMinorUnits, reason: reason
        )
    }

    func auditTrail(ticketId: UUID) async throws -> [SupportRefundAudit] {
        try await repository.auditTrail(ticketId: ticketId)
    }
}

// MARK: - M5: call support, gated by business hours

/// Pure domain policy — no dependency on `Date()` at the call site, so it's
/// trivially unit-testable against fixed dates/time zones.
enum BusinessHoursPolicy {
    /// 9am–9pm IST (plan M5), inclusive of 9:00, exclusive of 21:00.
    static let openHour = 9
    static let closeHour = 21
    static let timeZone = TimeZone(identifier: "Asia/Kolkata")!

    static func isReachableByPhone(at date: Date = .now, calendar: Calendar = .current) -> Bool {
        var cal = calendar
        cal.timeZone = timeZone
        let hour = cal.component(.hour, from: date)
        return hour >= openHour && hour < closeHour
    }
}

struct ContactSupportByCallUseCase {
    let supportPhoneNumber: String

    enum Outcome: Equatable {
        case callURL(URL)
        /// Outside business hours — no `tel:` URL is produced; the UI should
        /// fall back to chat/email instead of dialing.
        case outsideBusinessHours
    }

    func execute(at date: Date = .now) -> Outcome {
        guard BusinessHoursPolicy.isReachableByPhone(at: date) else {
            return .outsideBusinessHours
        }
        let digits = supportPhoneNumber.filter { $0.isNumber || $0 == "+" }
        guard let url = URL(string: "tel:\(digits)") else {
            return .outsideBusinessHours
        }
        return .callURL(url)
    }
}

// MARK: - J8: transactional SMS/WhatsApp fallback when push fails.

/// Pure decision logic — no I/O, fully unit-testable — for whether a
/// transactional notification should go out over push, fall back to
/// SMS/WhatsApp, or be suppressed entirely. Kept separate from
/// `SendTransactionalNotificationUseCase` (which does the actual dispatch)
/// so the *decision* can be tested exhaustively without a repository double.
enum NotificationDeliveryPolicy {
    /// - Parameters:
    ///   - hasPushToken: does this user have any registered device token at all.
    ///   - pushDeliveryFailed: did a push send just fail (APNs error, uninstalled app, etc).
    ///   - preferences: the user's per-category opt-in/out, or nil if unknown.
    ///   - category: the transactional category being sent — promotions never fall back to SMS.
    ///   - hasPhoneNumber: is there a phone number on file to fall back to.
    static func decide(
        hasPushToken: Bool,
        pushDeliveryFailed: Bool,
        preferences: NotificationPreferences?,
        category: TransactionalNotificationCategory,
        hasPhoneNumber: Bool
    ) -> NotificationDeliveryDecision {
        // Booking-update-shaped categories respect the user's toggle; OTPs
        // are never optional (plan §7: OTP delivery is a hard requirement of
        // starting a visit, not a preference).
        let categoryEnabled = category == .otp || (preferences?.bookingUpdates ?? true)

        if !categoryEnabled {
            guard hasPhoneNumber else {
                return .suppressed(reason: "Push disabled by user and no phone number on file.")
            }
            return .smsFallback(reason: .pushDisabledByUser)
        }

        if !hasPushToken {
            guard hasPhoneNumber else {
                return .suppressed(reason: "No push token and no phone number on file.")
            }
            return .smsFallback(reason: .noPushToken)
        }

        if pushDeliveryFailed {
            guard hasPhoneNumber else {
                return .suppressed(reason: "Push delivery failed and no phone number on file.")
            }
            return .smsFallback(reason: .pushDeliveryFailed)
        }

        return .push
    }
}

/// Drives `NotificationDeliveryPolicy` against real repository state and
/// records the SMS fallback intent when the policy calls for one. There is
/// no server-side push-sending Edge Function in this codebase yet (push is
/// currently modeled client-side only via `PushTokenRepository.registerDeviceToken`),
/// so this use case is the integration point a future push-send job would
/// call into on a delivery failure — see plan note on J8 for the honest
/// scope boundary (no live SMS/WhatsApp send without gateway credentials).
struct SendTransactionalNotificationUseCase {
    let pushTokenRepository: PushTokenRepository
    let notificationPreferencesRepository: NotificationPreferencesRepository
    let smsFallbackRepository: SMSFallbackRepository

    @discardableResult
    func execute(
        user: User, category: TransactionalNotificationCategory, body: String,
        pushDeliveryFailed: Bool = false
    ) async throws -> NotificationDeliveryDecision {
        async let hasToken = pushTokenRepository.hasDeviceToken(userId: user.id)
        async let prefs = try? notificationPreferencesRepository.preferences(userId: user.id)
        let decision = NotificationDeliveryPolicy.decide(
            hasPushToken: try await hasToken,
            pushDeliveryFailed: pushDeliveryFailed,
            preferences: await prefs,
            category: category,
            hasPhoneNumber: (user.phone?.isEmpty == false)
        )
        if case .smsFallback(let reason) = decision, let phone = user.phone {
            _ = try await smsFallbackRepository.sendFallback(
                userId: user.id, phone: phone, category: category, body: body, reason: reason
            )
        }
        return decision
    }
}

// MARK: - L2: document-backed vet onboarding. The applicant supplies a URL
// for each of five required documents (already uploaded to Storage by the
// caller — this use case only validates and writes the reference row); all
// five are mandatory because a partial application cannot be reviewed.
struct SubmitVetOnboardingApplicationUseCase {
    let repository: VetOnboardingRepository

    func submit(applicantUserId: UUID, degreeDocumentURL: URL?, vciCertificateURL: URL?,
                idDocumentURL: URL?, policeVerificationURL: URL?, photoURL: URL?) async throws -> VetOnboardingApplication {
        guard let degreeDocumentURL else { throw DomainError.validation("Please upload your degree document.") }
        guard let vciCertificateURL else { throw DomainError.validation("Please upload your VCI certificate.") }
        guard let idDocumentURL else { throw DomainError.validation("Please upload a government ID document.") }
        guard let policeVerificationURL else { throw DomainError.validation("Please upload your police verification certificate.") }
        guard let photoURL else { throw DomainError.validation("Please upload a photo.") }

        let application = VetOnboardingApplication(
            id: UUID(), applicantUserId: applicantUserId, degreeDocumentURL: degreeDocumentURL,
            vciCertificateURL: vciCertificateURL, idDocumentURL: idDocumentURL,
            policeVerificationURL: policeVerificationURL, photoURL: photoURL,
            status: .submitted, submittedAt: .now, reviewedAt: nil, reviewNotes: nil
        )
        return try await repository.submit(application)
    }

    func myApplications(applicantUserId: UUID) async throws -> [VetOnboardingApplication] {
        try await repository.myApplications(applicantUserId: applicantUserId)
    }

    /// Lets the applicant correct/replace a document reference before ops
    /// starts reviewing. The repository (mock: in-memory check; Supabase:
    /// RLS) is the real authority that the application is still
    /// `submitted` — this is a convenience guard so the caller gets an
    /// immediate, friendly error instead of a silent no-op.
    func update(_ application: VetOnboardingApplication) async throws -> VetOnboardingApplication {
        guard application.status == .submitted else {
            throw DomainError.validation("This application is already under review and can no longer be edited.")
        }
        return try await repository.update(application)
    }
}

/// I8: post-visit summary push. `PostVisitSummaryRepository` is the guard
/// against re-sending it every time the app happens to notice the visit is
/// still completed (there is no server-side "has this been sent" flag —
/// see the honest gap on the repository protocol).
struct SendPostVisitSummaryUseCase {
    let sendTransactionalNotificationUseCase: SendTransactionalNotificationUseCase
    let postVisitSummaryRepository: PostVisitSummaryRepository

    @discardableResult
    func execute(user: User, visit: Visit) async throws -> Bool {
        guard visit.status == .completed, !(try await postVisitSummaryRepository.hasSent(visitId: visit.id)) else {
            return false
        }
        let body = visit.notes?.isEmpty == false
            ? "Your visit summary is ready: \(visit.notes!)"
            : "Your visit summary is ready — tap to see the full record."
        _ = try await sendTransactionalNotificationUseCase.execute(user: user, category: .visitCompleted, body: body)
        try await postVisitSummaryRepository.markSent(visitId: visit.id)
        return true
    }
}

// MARK: - K6: lab test ordering + report delivery. Ordering reuses the
// existing catalog/cart/checkout flow (`Service` of `.labTest` category);
// this use case only surfaces the resulting reports.
struct GetLabTestReportsUseCase {
    let repository: LabTestReportRepository

    func forPet(_ petId: UUID) async throws -> [LabTestReport] {
        try await repository.reports(petId: petId)
    }

    func forVisit(_ visitId: UUID) async throws -> [LabTestReport] {
        try await repository.reports(visitId: visitId)
    }
}

/// I7: the vet's in-visit checklist, once it becomes the customer's record —
/// sorted by `sortOrder` so it reads as the order the vet actually worked
/// through it.
struct GetVisitChecklistUseCase {
    let repository: VisitChecklistRepository

    func execute(visitId: UUID) async throws -> [VisitChecklistItem] {
        try await repository.items(visitId: visitId).sorted { $0.sortOrder < $1.sortOrder }
    }
}

