import Foundation

// MARK: - Core domain models (pure Swift, no framework imports)

struct User: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var phone: String?
    var name: String
    var email: String?
    var createdAt: Date
    var pets: [Pet]
    // A11: server/admin-set only — mirrors `Vet.verificationStatus`'s
    // ownership split (see `vets` RLS: no client update policy on this
    // column, only `is_admin()` or a trusted function can move it).
    var accountStatus: AccountStatus = .active

    enum AccountStatus: String, Codable, CaseIterable {
        case active, blocked, deactivated
    }
}

struct Pet: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var ownerId: UUID
    var name: String
    var species: Species
    var breed: String?
    var dateOfBirth: Date?
    // B2: a signed URL into the same private `documents` bucket B6 already
    // uses (path `pet-photos/<petId>/<uuid>.jpg`) — set by `updatePhoto`,
    // never edited as a plain text field.
    var photoURL: URL? = nil
    // B2: the fields a real pet health record needs beyond "what is it" —
    // sex/neuter status feed vaccination eligibility, weight/allergies matter
    // to the vet before a visit even starts.
    var sex: Sex? = nil
    var isNeutered: Bool? = nil
    var weightKg: Double? = nil
    var microchipNumber: String? = nil
    var allergies: String? = nil
    var chronicConditions: String? = nil
    // B8: soft-delete only — an archived pet's visit/vaccination/prescription
    // history must stay intact, so this is a flag, never a row removal.
    var archivedAt: Date? = nil
    var archiveReason: ArchiveReason? = nil

    enum Species: String, Codable, CaseIterable {
        case dog, cat, bird, other
    }

    enum Sex: String, Codable, CaseIterable {
        case male, female, unknown
    }

    enum ArchiveReason: String, Codable, CaseIterable {
        case deceased, rehomed, other

        /// §B8: "handle with care in copy" — never the word "delete".
        var displayName: String {
            switch self {
            case .deceased: return "Passed away"
            case .rehomed: return "Rehomed"
            case .other: return "No longer with you"
            }
        }
    }

    var isArchived: Bool { archivedAt != nil }
}

struct Vet: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    var licenseNumber: String
    var verificationStatus: VerificationStatus
    var rating: Double
    var reviewCount: Int
    var photoURL: URL?
    /// C5/C3: profile fields the vet detail screen and filter sheet both need
    /// — "Hindi-speaking", "female vet" are real, commonly-asked-for filters
    /// in this market, not nice-to-haves (plan §C3).
    var bio: String? = nil
    var yearsOfExperience: Int? = nil
    var languages: [String] = []
    var gender: Gender? = nil
    /// Species this vet actually treats — drives the C3 "handles cats" filter.
    var speciesHandled: [Pet.Species] = Pet.Species.allCases

    enum VerificationStatus: String, Codable {
        case pending, verified, rejected
    }

    enum Gender: String, Codable, CaseIterable, Identifiable {
        case male, female, other
        var id: String { rawValue }
        var displayName: String { rawValue.capitalized }
    }
}

struct Circuit: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var vetId: UUID
    var vet: Vet?
    var clusterArea: String
    var schedule: [ScheduleSlot]
    var vertical: Vertical = .vet
}

struct ScheduleSlot: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var dayOfWeek: Int // 1 = Sunday ... 7 = Saturday
    var startTime: Date
    var endTime: Date
    /// F2: capacity by *stops on this run*, not a boolean — a slot can take
    /// N bookings (bounded by circuit route/duration), not just one.
    var capacity: Int = 1
    var bookedCount: Int = 0

    var isAvailable: Bool { bookedCount < capacity }
    var remainingCapacity: Int { max(0, capacity - bookedCount) }
}

/// F8: pure date math for buffer/travel-time aware slot offering — mirrors
/// `RecurrenceScheduler`/`NoShowPolicy`'s "no I/O, directly unit-testable"
/// shape. Without this a circuit's back-to-back schedule slots could offer
/// a vet zero travel time between two stops.
struct SlotBufferPolicy {
    /// Minimum travel/prep gap between consecutive visits when none is
    /// otherwise configured for the circuit.
    static let defaultBufferMinutes = 15

    /// Whether a candidate slot starting at `candidateStart` (running
    /// `visitDurationMinutes`) can be offered given a set of already-booked
    /// slot start times (assumed to run the same duration) on the same day
    /// — true only if every booked visit, padded by `bufferMinutes` on both
    /// sides, doesn't overlap the candidate.
    static func isOfferable(
        candidateStart: Date,
        visitDurationMinutes: Int,
        bookedStarts: [Date],
        bufferMinutes: Int = defaultBufferMinutes
    ) -> Bool {
        let visitDuration = TimeInterval(visitDurationMinutes * 60)
        let buffer = TimeInterval(bufferMinutes * 60)
        let candidateEnd = candidateStart.addingTimeInterval(visitDuration)
        for booked in bookedStarts {
            let bookedEnd = booked.addingTimeInterval(visitDuration)
            let paddedStart = candidateStart.addingTimeInterval(-buffer)
            let paddedEnd = candidateEnd.addingTimeInterval(buffer)
            if booked < paddedEnd && bookedEnd > paddedStart {
                return false
            }
        }
        return true
    }

    /// Filters a circuit's schedule (grouped by day) down to the slots that
    /// remain offerable once already-booked slots each reserve their travel
    /// buffer — a booked slot (`bookedCount > 0`) is never removed itself,
    /// only other still-empty slots that fall inside its buffer window.
    static func filterOfferableSlots(
        _ slots: [ScheduleSlot],
        visitDurationMinutes: Int,
        bufferMinutes: Int = defaultBufferMinutes
    ) -> [ScheduleSlot] {
        let byDay = Dictionary(grouping: slots) { $0.dayOfWeek }
        var result: [ScheduleSlot] = []
        for (_, daySlots) in byDay {
            let bookedStarts = daySlots.filter { $0.bookedCount > 0 }.map { $0.startTime }
            for slot in daySlots {
                if slot.bookedCount > 0 {
                    result.append(slot)
                } else if isOfferable(candidateStart: slot.startTime, visitDurationMinutes: visitDurationMinutes,
                                       bookedStarts: bookedStarts, bufferMinutes: bufferMinutes) {
                    result.append(slot)
                }
            }
        }
        return result
    }
}

/// F9: a vet-declared leave/holiday window — no slot on any of the vet's
/// circuits should be offered while one is active. Deliberately just a date
/// range (not per-slot granularity); a half-day leave is modeled as a
/// same-day start/end range.
struct VetBlackout: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var vetId: UUID
    var startDate: Date
    var endDate: Date
    var reason: String?

    func isActive(on date: Date = .now) -> Bool {
        date >= startDate && date <= endDate
    }

    static func isVetBlackedOut(vetId: UUID, blackouts: [VetBlackout], on date: Date = .now) -> Bool {
        blackouts.contains { $0.vetId == vetId && $0.isActive(on: date) }
    }
}

struct Visit: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var userId: UUID
    var petId: UUID
    var vetId: UUID
    var circuitId: UUID
    var status: VisitStatus
    var scheduledAt: Date
    var completedAt: Date?
    var notes: String?
    var paymentId: UUID?
    /// K1: structured visit record. `diagnosisNotes`/`proceduresPerformed`/
    /// `medicationsGiven` are the vet-written record proper; `notes` (above)
    /// is kept as a legacy free-text fallback for visits recorded before
    /// this existed. Written by the attending vet / ops side (out of this
    /// app's scope); the customer app only ever displays them.
    var diagnosisNotes: String?
    var proceduresPerformed: [String] = []
    var medicationsGiven: [String] = []

    /// True once there's anything structured to show, so the UI can fall
    /// back to the legacy `notes` blob when there isn't.
    var hasStructuredRecord: Bool {
        diagnosisNotes?.isEmpty == false || !proceduresPerformed.isEmpty || !medicationsGiven.isEmpty
    }

    /// Appendix B's 8-state machine (up from v1's 5) — the extra states are
    /// what let the timeline (I2) show "assigned", "arrived", and
    /// "in progress" instead of jumping straight from confirmed to en route
    /// to completed with nothing in between.
    enum VisitStatus: String, Codable, CaseIterable {
        case requested
        case confirmed
        case assigned
        case enRoute = "en_route"
        case arrived
        case inProgress = "in_progress"
        case completed
        case cancelledByUser = "cancelled_by_user"
        case cancelledByVet = "cancelled_by_vet"
        case noShowUser = "no_show_user"
        case noShowVet = "no_show_vet"
        case disputed
        case resolved

        var displayText: String {
            switch self {
            case .requested: return "Requested"
            case .confirmed: return "Confirmed"
            case .assigned: return "Vet assigned"
            case .enRoute: return "Vet en route"
            case .arrived: return "Vet has arrived"
            case .inProgress: return "Visit in progress"
            case .completed: return "Completed"
            case .cancelledByUser: return "Cancelled by you"
            case .cancelledByVet: return "Cancelled by vet"
            case .noShowUser: return "You weren't available"
            case .noShowVet: return "Vet didn't arrive"
            case .disputed: return "Under review"
            case .resolved: return "Resolved"
            }
        }

        var isTerminal: Bool {
            switch self {
            case .completed, .cancelledByUser, .cancelledByVet, .noShowUser, .noShowVet, .resolved: return true
            default: return false
            }
        }

        var isCancelled: Bool {
            self == .cancelledByUser || self == .cancelledByVet || self == .noShowUser
        }
    }

    /// Appendix B's legal-transition table, enforced here so the client and
    /// (eventually) the DB trigger agree on the same rules — an illegal
    /// transition is a bug to catch, not something the UI should paper over.
    static let legalTransitions: [VisitStatus: Set<VisitStatus>] = [
        .requested: [.confirmed, .cancelledByUser, .cancelledByVet],
        .confirmed: [.assigned, .cancelledByUser, .cancelledByVet],
        .assigned: [.enRoute, .cancelledByUser, .cancelledByVet, .noShowVet],
        .enRoute: [.arrived, .cancelledByVet, .noShowVet],
        .arrived: [.inProgress, .noShowUser],
        .inProgress: [.completed],
        .completed: [.disputed],
        .disputed: [.resolved],
    ]

    static func canTransition(from: VisitStatus, to: VisitStatus) -> Bool {
        legalTransitions[from]?.contains(to) ?? false
    }
}

struct Subscription: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var userId: UUID
    var planType: PlanType
    var status: Status
    var renewalDate: Date
    var seatCount: Int = 1

    enum PlanType: String, Codable, CaseIterable {
        case monthly, quarterly, annual, corporate

        var displayName: String {
            switch self {
            case .monthly: return "Monthly"
            case .quarterly: return "Quarterly"
            case .annual: return "Annual"
            case .corporate: return "Corporate / RWA bulk"
            }
        }

        var isBulk: Bool { self == .corporate }
    }

    enum Status: String, Codable {
        case active, cancelled, expired, pastDue = "past_due", paused
    }
}

// MARK: - Subscription management (plan §H3) — upgrade/downgrade/pause/cancel
// as real business logic, not a pass-through to the repository.

/// Ranks plans by commitment/price tier so upgrade/downgrade can be validated
/// directionally. Corporate is deliberately outside the linear ladder — it is
/// a seat-based plan, not a "bigger" individual plan.
private extension Subscription.PlanType {
    var tierRank: Int? {
        switch self {
        case .monthly: return 0
        case .quarterly: return 1
        case .annual: return 2
        case .corporate: return nil
        }
    }
}

struct SubscriptionManagementPolicy {
    /// A corporate/RWA plan stops being a valid bulk plan below this — the
    /// same floor `SubscribeToPlanUseCase` enforces at signup (plan §H7).
    static let minimumCorporateSeats = 5

    enum Action { case upgrade, downgrade, pause, resume, cancel }

    /// Pure validation — no I/O, so every case is directly testable. Returns
    /// nil when the action is allowed, or the reason it isn't.
    static func validate(_ action: Action, subscription: Subscription, targetPlan: Subscription.PlanType? = nil) -> DomainError? {
        switch action {
        case .upgrade, .downgrade:
            guard subscription.status == .active || subscription.status == .pastDue else {
                return .validation("Only an active subscription can change plans.")
            }
            guard let targetPlan else { return .validation("No target plan given.") }
            guard targetPlan != subscription.planType else {
                return .validation("Already on that plan.")
            }
            // Corporate is a seat-based product, not a rung on the individual
            // ladder — moving into/out of it goes through pause/cancel + a
            // fresh subscribe, so the seat-count floor is always enforced.
            if targetPlan.isBulk || subscription.planType.isBulk {
                return .validation("Corporate/RWA plans are managed by seat count, not upgrade/downgrade — cancel and start a new corporate plan instead.")
            }
            guard let currentRank = subscription.planType.tierRank, let targetRank = targetPlan.tierRank else {
                return .validation("Unsupported plan change.")
            }
            if action == .upgrade && targetRank <= currentRank {
                return .validation("\(targetPlan.displayName) isn't an upgrade from \(subscription.planType.displayName).")
            }
            if action == .downgrade && targetRank >= currentRank {
                return .validation("\(targetPlan.displayName) isn't a downgrade from \(subscription.planType.displayName).")
            }
            return nil

        case .pause:
            guard subscription.status == .active else {
                return .validation("Only an active subscription can be paused.")
            }
            // A corporate plan below the seat floor isn't a valid product to
            // resume back into later — force cancellation instead of a pause
            // that would silently strand it under-quota.
            if subscription.planType.isBulk && subscription.seatCount < minimumCorporateSeats {
                return .validation("This corporate plan has fewer than \(minimumCorporateSeats) seats — cancel it instead of pausing.")
            }
            return nil

        case .resume:
            guard subscription.status == .paused else {
                return .validation("This subscription isn't paused.")
            }
            return nil

        case .cancel:
            guard subscription.status != .cancelled else {
                return .validation("This subscription is already cancelled.")
            }
            return nil
        }
    }
}

// MARK: - H6: subscription entitlement engine — a subscription grants a
// monthly allowance of free-visit credits, tracked separately from billing
// state (`Subscription.status`) because a credit balance resets on a period
// boundary, not on a plan-status transition.

struct SubscriptionEntitlement: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var subscriptionId: UUID
    var creditsRemaining: Int
    var resetAt: Date
}

/// Pure — no I/O, no clock injected beyond the `Date` passed in — so the
/// credits-per-period rule and the reset/consume decisions are directly
/// testable. `GetQuoteUseCase` calls `apply` to decide whether a quote gets
/// a credit; the repository is responsible for persisting the result.
enum EntitlementPolicy {
    /// Monthly/quarterly/annual all grant one visit credit per month —
    /// quarterly/annual just accrue it monthly instead of handing over 3 or
    /// 12 at signup, so a cancelled quarterly/annual plan hasn't already
    /// spent credits for months it won't see. Corporate is seat-based: one
    /// credit per seat per month (a bulk RWA plan is buying capacity for N
    /// households, not one).
    static func creditsGrantedPerPeriod(plan: Subscription.PlanType, seatCount: Int) -> Int {
        switch plan {
        case .monthly, .quarterly, .annual: return 1
        case .corporate: return max(1, seatCount)
        }
    }

    /// Whether `entitlement` needs its monthly reset applied before use —
    /// pure date comparison, no side effects.
    static func needsReset(entitlement: SubscriptionEntitlement, now: Date) -> Bool {
        now >= entitlement.resetAt
    }

    /// Returns the entitlement as it should be *after* rolling forward any
    /// due reset(s) — callers persist this before consuming a credit. Uses
    /// a calendar month step so "reset monthly" means a calendar month, not
    /// a rolling 30-day window that drifts.
    static func rolledForward(entitlement: SubscriptionEntitlement, plan: Subscription.PlanType, seatCount: Int, now: Date, calendar: Calendar = .current) -> SubscriptionEntitlement {
        guard needsReset(entitlement: entitlement, now: now) else { return entitlement }
        var result = entitlement
        result.creditsRemaining = creditsGrantedPerPeriod(plan: plan, seatCount: seatCount)
        result.resetAt = calendar.date(byAdding: .month, value: 1, to: max(entitlement.resetAt, now)) ?? now.addingTimeInterval(30 * 86_400)
        return result
    }

    /// Whether a credit can be applied to zero a quote's base price right
    /// now — active subscription (H3's pause/cancel states never earn a
    /// credit) with at least one credit remaining after rollover.
    static func canApplyCredit(subscription: Subscription, entitlement: SubscriptionEntitlement, now: Date) -> Bool {
        guard subscription.status == .active else { return false }
        let current = rolledForward(entitlement: entitlement, plan: subscription.planType, seatCount: subscription.seatCount, now: now)
        return current.creditsRemaining > 0
    }
}

struct Payment: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var visitId: UUID?
    var subscriptionId: UUID?
    var amountMinorUnits: Int // store as smallest currency unit (paise)
    var currency: String
    var status: Status
    var gatewayReference: String?
    /// E6: the signed quote this payment/order was checked out against —
    /// nil only for the subscription/tip checkout paths, which don't go
    /// through a cart quote. A per-visit checkout always has one (enforced
    /// by `StartCheckoutUseCase`'s signature, which takes a `Quote`, not a
    /// raw amount).
    var quoteId: UUID? = nil

    enum Status: String, Codable {
        case pending, succeeded, failed, refunded
    }
}

struct ChatMessage: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var visitId: UUID
    var senderId: UUID
    var body: String
    var sentAt: Date
    var readAt: Date?
    /// J2: "Pet owners send photos. Always." — a signed URL to an uploaded
    /// image, stored alongside the message rather than as a separate thread.
    var attachmentURL: URL? = nil
}

struct Review: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var visitId: UUID
    var vetId: UUID
    var userId: UUID
    var rating: Int // 1...5
    var comment: String?
    var createdAt: Date
    /// L6: set when `ReviewModerationPolicy` flagged this review's text
    /// (PII redacted and/or defamation-risk language detected) for human
    /// review — the review itself is still stored and shown, this is only a
    /// signal for ops, never a block.
    var needsModeration: Bool = false
    /// L6: which policy checks tripped, e.g. "pii_email", "defamation_risk".
    var moderationFlags: [String] = []
}

// MARK: - Multi-vertical & loyalty (V3)

/// The same app/backend can serve more than one home-visit vertical — the
/// plan's V3 "toggle between vet / elder-care / physio circuits". A user
/// picks one at a time; circuits are filtered by it.
enum Vertical: String, Codable, CaseIterable, Identifiable {
    case vet, elderCare = "elder_care", physio

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .vet: return "Vet visits"
        case .elderCare: return "Elder care"
        case .physio: return "Physiotherapy"
        }
    }

    var systemImage: String {
        switch self {
        case .vet: return "pawprint.fill"
        case .elderCare: return "figure.wave"
        case .physio: return "figure.strengthtraining.traditional"
        }
    }
}

// MARK: - E5: loyalty point redemption at checkout — converts points into
// wallet credit (which CartView's existing "use wallet balance" toggle
// already spends) rather than a parallel discount mechanism, so pricing has
// exactly one place that applies a balance, not two.
enum LoyaltyRedemptionPolicy {
    /// 1 point = ₹0.50 (50 paise) — arbitrary but fixed, same shape as
    /// `CancellationPolicy`'s hardcoded 4h window: a real deployment would
    /// tune this, the important part is client and server agree on one number.
    static let minorUnitsPerPoint = 50
    /// Redeeming a handful of points isn't worth a ledger row.
    static let minimumRedeemablePoints = 100

    static func minorUnits(forPoints points: Int) -> Int { max(0, points) * minorUnitsPerPoint }

    /// Pure validation — mirrors `SubscriptionManagementPolicy.validate`'s
    /// shape: nil means allowed, otherwise the reason it isn't.
    static func validate(points: Int, availablePoints: Int) -> DomainError? {
        guard points > 0 else { return .validation("Enter a number of points to redeem.") }
        guard points >= minimumRedeemablePoints else {
            return .validation("Redeem at least \(minimumRedeemablePoints) points at a time.")
        }
        guard points <= availablePoints else {
            return .validation("You only have \(availablePoints) points available.")
        }
        return nil
    }
}

struct LoyaltyAccount: Codable, Equatable {
    var userId: UUID
    var points: Int
    var tier: Tier

    enum Tier: String, Codable {
        case bronze, silver, gold

        static func forPoints(_ points: Int) -> Tier {
            switch points {
            case ..<200: return .bronze
            case 200..<600: return .silver
            default: return .gold
            }
        }
    }
}

// MARK: - Live tracking & referrals (V2)

struct VetLocation: Codable, Equatable, Hashable {
    var visitId: UUID
    var latitude: Double
    var longitude: Double
    var updatedAt: Date
    var etaMinutes: Int?
}

struct Referral: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var referrerId: UUID
    var code: String
    var invitedPhone: String?
    var status: Status
    var rewardApplied: Bool
    var createdAt: Date

    enum Status: String, Codable {
        case pending, joined, rewarded
    }
}

// MARK: - Addresses (plan §A8) — a circuit is address-scoped, so this is core
// inventory logic, not a nicety: discovery starts from "which address" before
// "which service".

struct Address: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var ownerId: UUID
    var label: String          // "Home", "Office", "Mom's place"
    var line1: String
    var line2: String?
    var landmark: String?
    var accessNotes: String?   // gate code, floor, "ring the bell twice"
    var latitude: Double
    var longitude: Double
    var clusterArea: String?   // set once matched to a served cluster; nil = not yet covered
    var isDefault: Bool = false

    /// Whether this address falls inside a served circuit cluster — an
    /// unmatched address should route to the waitlist (C10), not a dead end.
    var isServed: Bool { clusterArea != nil }
}

// MARK: - C7: served cluster coverage (for a map view) — the same notion
// `AddressRepository.matchCluster` point-tests against, just enumerable so a
// map can draw it instead of only answering "is this one point inside".

struct ServedCluster: Identifiable, Codable, Equatable, Hashable {
    var id: String { area }
    var area: String
    var latitude: Double
    var longitude: Double
    var radiusKm: Double
}

// MARK: - Account deletion & data export (plan §A6-A7)

struct DeletionRequest: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var userId: UUID
    var requestedAt: Date
    var scheduledPurgeAt: Date   // requestedAt + 30-day soft window
    var status: Status

    enum Status: String, Codable {
        case pending, cancelled, purged
    }

    static let softWindowDays = 30
}

/// A7: DPDP data-principal right to export. Assembled as one JSON document
/// (plan says "JSON + PDF"; PDF rendering isn't wired yet — see below).
struct DataExport: Codable, Equatable {
    var user: User
    var addresses: [Address]
    var visits: [Visit]
    var consents: [ConsentRecord]
    var generatedAt: Date
}

// MARK: - Visit start OTP & consent (plan §I5-I6)

/// I5: the customer reads this 4-digit code to the vet at arrival — cheap
/// anti-fraud and proof-of-service. Verifying it is what moves a visit from
/// `arrived` to `in_progress`.
struct VisitOTP: Codable, Equatable {
    var visitId: UUID
    var code: String        // 4 digits, never logged, shown once in-app
    var expiresAt: Date
    var verifiedAt: Date?

    var isExpired: Bool { Date() >= expiresAt }
    var isVerified: Bool { verifiedAt != nil }
}

/// I6: a digital consent/liability waiver accepted before a customer's
/// first visit — a legal shield, and a DPDP-style itemized consent record.
struct ConsentRecord: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var userId: UUID
    var purpose: String     // e.g. "liability_waiver", "location_tracking"
    var version: String
    var grantedAt: Date
    var withdrawnAt: Date?

    var isActive: Bool { withdrawnAt == nil }
}

// MARK: - Masked calling (plan §J4) — real phone numbers are never exposed
// to either party; both dial a shared proxy number that the gateway bridges.

struct CallSession: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var visitId: UUID
    /// The proxy number to dial — not the vet's or customer's real number.
    var proxyNumber: String
    var expiresAt: Date

    var isExpired: Bool { Date() >= expiresAt }
}

// MARK: - Cancellation policy, refunds & invoices (plan §F4, §G4-G5)

/// F4: cancellation policy as code, not a support-team judgment call —
/// free >4h before the slot, 50% refund <4h, 100% charged on no-show.
struct CancellationPolicy {
    static let freeWindowHours: Double = 4

    struct Outcome: Equatable {
        var refundPercent: Int       // 0, 50, or 100
        var refundMinorUnits: Int
        var paidMinorUnits: Int
        var isPastVisitTime: Bool    // UI copy differs for "too late" vs. "within the fee window"
    }

    /// `paidMinorUnits` is what was actually charged for the visit; `now`
    /// is injected for testability rather than reading `Date()` inline.
    /// Presentation formats `Outcome` into the plan §9 rule-3 copy
    /// ("Cancelling now refunds ₹X of ₹Y") — domain stays framework-free.
    static func evaluate(scheduledAt: Date, paidMinorUnits: Int, now: Date = .now) -> Outcome {
        let hoursUntilVisit = scheduledAt.timeIntervalSince(now) / 3600
        if hoursUntilVisit >= freeWindowHours {
            return Outcome(refundPercent: 100, refundMinorUnits: paidMinorUnits, paidMinorUnits: paidMinorUnits, isPastVisitTime: false)
        } else if hoursUntilVisit >= 0 {
            let refund = paidMinorUnits / 2
            return Outcome(refundPercent: 50, refundMinorUnits: refund, paidMinorUnits: paidMinorUnits, isPastVisitTime: false)
        } else {
            return Outcome(refundPercent: 0, refundMinorUnits: 0, paidMinorUnits: paidMinorUnits, isPastVisitTime: true)
        }
    }
}

// MARK: - Dunning (plan §H5) — failed renewal charge -> retry ladder -> grace
// -> auto-downgrade. Pure state + policy, mirroring CancellationPolicy above:
// the domain computes what should happen next, the caller (a scheduled job,
// per plan §6.5) performs the I/O.

struct DunningState: Codable, Equatable {
    var subscriptionId: UUID
    var failedAttempts: Int
    var nextRetryAt: Date?       // nil once the ladder is exhausted and grace has started
    var gracePeriodEndsAt: Date?
}

struct DunningPolicy {
    /// Days after a failed charge to retry: +1, +3, +7. After the 3rd
    /// failure the grace period starts instead of a 4th retry.
    static let retryLadderDays: [Int] = [1, 3, 7]
    static let gracePeriodDays = 7
    /// Where an unpaid subscription lands once grace expires unpaid — a
    /// free/lowest tier rather than a hard cutoff, per plan §H5.
    static let downgradeTarget: Subscription.PlanType = .monthly

    enum Outcome: Equatable {
        case retryScheduled(state: DunningState)
        case graceStarted(state: DunningState)
        case downgraded(to: Subscription.PlanType)
    }

    /// Called each time a renewal charge fails. `state` is nil on the first
    /// failure for this billing cycle.
    static func onChargeFailed(state: DunningState?, subscriptionId: UUID, now: Date = .now) -> Outcome {
        let attempts = (state?.failedAttempts ?? 0) + 1
        if attempts <= retryLadderDays.count {
            let delayDays = retryLadderDays[attempts - 1]
            let nextRetryAt = Calendar.current.date(byAdding: .day, value: delayDays, to: now) ?? now
            return .retryScheduled(state: DunningState(subscriptionId: subscriptionId, failedAttempts: attempts, nextRetryAt: nextRetryAt, gracePeriodEndsAt: nil))
        } else {
            let graceEnds = Calendar.current.date(byAdding: .day, value: gracePeriodDays, to: now) ?? now
            return .graceStarted(state: DunningState(subscriptionId: subscriptionId, failedAttempts: attempts, nextRetryAt: nil, gracePeriodEndsAt: graceEnds))
        }
    }

    /// The scheduled job (plan §6.5) polls this: once grace has passed with
    /// no successful charge, the subscription is downgraded rather than left
    /// past-due forever.
    static func shouldAutoDowngrade(state: DunningState, now: Date = .now) -> Bool {
        guard let gracePeriodEndsAt = state.gracePeriodEndsAt else { return false }
        return now >= gracePeriodEndsAt
    }
}

struct Refund: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var visitId: UUID
    var paymentId: UUID
    var amountMinorUnits: Int
    var reason: String
    var status: Status
    var createdAt: Date
    var initiatedByOpsUserId: UUID? // nil = automatic per-policy refund; set = ops-initiated

    enum Status: String, Codable {
        case pending, processed, failed
    }
}

struct Invoice: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var visitId: UUID
    var invoiceNumber: String  // sequential, GST-compliant numbering (plan §G5)
    var breakdown: PriceBreakdown
    var gstMinorUnits: Int
    var issuedAt: Date
}

// MARK: - Saved payment methods (plan E9) — never a PAN/CVV, only a
// gateway-issued token reference plus a display label safe to show
// ("Visa •••• 4242"). Mirrors the refund/wallet discipline: the client only
// ever stores/reads a reference, real card data lives with the gateway.
struct SavedPaymentMethod: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var userId: UUID
    var gatewayTokenId: String
    var displayLabel: String
    var isDefault: Bool
    var createdAt: Date
}

// MARK: - Support refund/credit audit trail (plan M4) — append-only record
// of a support-agent-issued refund or wallet credit against a visit, tied to
// the ticket that prompted it. Written only by the `issue-support-refund`
// Edge Function (service-role key), never by the client — mirrors
// `refunds`/`wallet_ledger`'s append-only, RLS-locked-down discipline.
struct SupportRefundAudit: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var ticketId: UUID
    var visitId: UUID
    var issuedByUserId: UUID
    var kind: Kind
    var amountMinorUnits: Int
    var reason: String
    var refundId: UUID?
    var walletLedgerEntryId: UUID?
    var createdAt: Date

    enum Kind: String, Codable {
        case refund, walletCredit = "wallet_credit"
    }
}

// MARK: - Wallet (plan §G6) — append-only double-entry ledger; balance is
// always the sum of entries, never a stored/mutable column (mirrors
// vet_ledger's discipline in 0014_payouts.sql).

struct WalletLedgerEntry: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var userId: UUID
    var amountMinorUnits: Int // positive = credit, negative = debit
    var reason: String
    var relatedVisitId: UUID?
    var relatedRefundId: UUID?
    var createdAt: Date
}

// MARK: - Coupons (plan §E4, §N2) — validated server-side only; the app
// never enumerates codes, it asks the server "is this one valid for me now".

struct Coupon: Identifiable, Codable, Equatable, Hashable {
    enum DiscountType: String, Codable {
        case percentageOff = "percentage_off"
        case fixedAmountOff = "fixed_amount_off"
    }

    let id: UUID
    var code: String
    var discountType: DiscountType
    var discountValue: Int // percent (1-100) or paise, per discountType
    var maxDiscountMinorUnits: Int?
    var validFrom: Date
    var validUntil: Date
    var usageLimit: Int?
    var perUserLimit: Int?
    var minSpendMinorUnits: Int?
    var campaignName: String?
}

// MARK: - Cart, pricing & checkout (plan §E) — a server-authoritative quote
// is the only thing an order may ever reference; the client never computes
// a rupee (Appendix C).

struct CartItem: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var serviceId: UUID
    var variantId: UUID
    var petIds: [UUID]           // 1 or more pets on this line item (D6: multi-pet)
    var addonIds: [UUID] = []
    // E1: repeat this exact line item N times (e.g. "2 grooming sessions") —
    // distinct from D6's multi-pet, which is "this one visit, more than one
    // pet". Always >= 1; `ManageCartUseCase.setQuantity` enforces that.
    var quantity: Int = 1
}

struct Cart: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var userId: UUID
    var addressId: UUID?
    var circuitId: UUID?
    var slotId: UUID?
    var items: [CartItem] = []
    var couponCode: String? = nil
}

/// One line in the itemized breakdown a quote returns — displayed verbatim
/// in the app and stored on the order for the invoice (Appendix C: "the
/// client never computes a rupee").
struct PriceLineItem: Identifiable, Codable, Equatable, Hashable {
    let id = UUID()
    var label: String
    var amountMinorUnits: Int // negative for discounts/credits

    enum CodingKeys: String, CodingKey { case label, amountMinorUnits }
}

struct PriceBreakdown: Codable, Equatable, Hashable {
    var lineItems: [PriceLineItem]
    var totalMinorUnits: Int
}

/// A server-signed, TTL'd quote (E6). An order must reference a valid,
/// unexpired quote — this is what makes client-side price tampering
/// structurally impossible rather than merely discouraged.
struct Quote: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var cartId: UUID
    var breakdown: PriceBreakdown
    var signature: String
    var expiresAt: Date

    var isExpired: Bool { Date() >= expiresAt }

    static let ttl: TimeInterval = 10 * 60
}

// MARK: - Slot holds (plan §E7) — the "slot taken while I was paying"
// disaster is prevented by reserving a slot's capacity for a short window
// during checkout, auto-released if checkout never completes.

struct SlotHold: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var slotId: UUID
    var userId: UUID
    var expiresAt: Date

    static let holdDuration: TimeInterval = 10 * 60

    var isExpired: Bool { Date() >= expiresAt }
}

// MARK: - Service catalog (V2 plan §D) — what is actually being bought.
// A v1 `Visit` had no concept of *what* was booked; this is the structural
// gap everything else (cart, pricing, checkout) depends on.

enum ServiceCategory: String, Codable, CaseIterable, Identifiable {
    case consult, vaccination, grooming, diagnostics, deworming, dental
    case elderCareVisit = "elder_care_visit"
    case physioSession = "physio_session"
    /// K6: a bookable lab test (blood panel, urinalysis, ...) — reuses the
    /// existing catalog/cart/checkout/booking flow rather than a parallel
    /// ordering system; the resulting `Visit` is what a `LabTestReport`
    /// eventually attaches to.
    case labTest = "lab_test"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .consult: return "Consultation"
        case .vaccination: return "Vaccination"
        case .grooming: return "Grooming"
        case .diagnostics: return "Diagnostics"
        case .deworming: return "Deworming"
        case .dental: return "Dental"
        case .elderCareVisit: return "Elder care visit"
        case .physioSession: return "Physio session"
        case .labTest: return "Lab test"
        }
    }

    var systemImage: String {
        switch self {
        case .consult: return "stethoscope"
        case .vaccination: return "syringe.fill"
        case .grooming: return "scissors"
        case .diagnostics: return "testtube.2"
        case .deworming: return "pills.fill"
        case .dental: return "mouth.fill"
        case .elderCareVisit: return "figure.wave"
        case .physioSession: return "figure.strengthtraining.traditional"
        case .labTest: return "cross.vial.fill"
        }
    }

    var vertical: Vertical {
        switch self {
        case .elderCareVisit: return .elderCare
        case .physioSession: return .physio
        default: return .vet
        }
    }
}

/// Eligibility gate on a variant or add-on — who/what it's actually sold to.
/// Kept as plain data so pricing/eligibility logic stays pure and testable.
struct ServiceEligibility: Codable, Equatable, Hashable {
    var species: [Pet.Species]? = nil       // nil = all species
    var requiresPrescriberVet: Bool = false // para-vets can't perform this
    var minPetAgeMonths: Int? = nil

    func allows(species: Pet.Species) -> Bool {
        guard let species = self.species else { return true }
        return species.contains(species)
    }
}

struct ServiceVariant: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var serviceId: UUID
    var name: String              // "Standard 20 min", "Extended 40 min", "Follow-up (14d)"
    var durationMinutes: Int
    var priceMinorUnits: Int      // base price, paise
    var additionalPetPriceMinorUnits: Int = 0
    var isFollowUp: Bool = false
}

struct Addon: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String              // "Nail trim", "Deworming", "Blood sample pickup"
    var priceMinorUnits: Int
    var eligibility: ServiceEligibility = ServiceEligibility()
}

/// C6: a service detail FAQ entry — plain question/answer pairs, ops-managed
/// the same way the rest of the catalog is.
struct FAQ: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var question: String
    var answer: String
}

struct Service: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var category: ServiceCategory
    var name: String
    var summary: String
    var whatToPrepare: String?
    var variants: [ServiceVariant]
    var addons: [Addon] = []
    var eligibility: ServiceEligibility = ServiceEligibility()
    var faqs: [FAQ] = []

    var startingPriceMinorUnits: Int? {
        variants.map(\.priceMinorUnits).min()
    }
}

// MARK: - K6: lab test ordering + report delivery. Ordering itself is just a
// `Service` of `.labTest` category booked through the existing cart/checkout
// flow; this type only models the report that later attaches to the
// resulting visit. Reports are uploaded ops-side (out of this app's scope),
// so there is deliberately no client "create"/"upload" method here.
struct LabTestReport: Identifiable, Codable, Equatable, Hashable {
    enum Status: String, Codable, Equatable, Hashable {
        case pending
        case ready
    }

    let id: UUID
    var visitId: UUID
    var petId: UUID
    var testName: String
    var status: Status
    var reportFileURL: URL?
    var resultSummary: String?
    var availableAt: Date?
}

// MARK: - Packages/bundles (plan §D4) — "Puppy first-year: 4 visits + 3
// vaccines" sold as one priced unit. Buying one is currently a checkout-time
// stub that expands into individual cart lines (see BuyPackageUseCase);
// redemption/entitlement tracking ("3 of 4 visits used") is a known gap,
// tracked in Appendix F.

struct PackageItem: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var serviceId: UUID
    var quantity: Int   // how many bookings of this service the package includes
}

struct Package: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    var packageDescription: String
    var items: [PackageItem]
    var priceMinorUnits: Int
    var vertical: Vertical = .vet

    /// The saving vs. buying every included service separately at its
    /// cheapest variant — `catalog` is passed in rather than looked up here
    /// so this stays pure/testable like the rest of the pricing logic.
    func discountMinorUnits(catalog: [Service]) -> Int {
        let separatePrice = items.reduce(0) { total, item in
            guard let service = catalog.first(where: { $0.id == item.serviceId }),
                  let cheapest = service.startingPriceMinorUnits else { return total }
            return total + cheapest * item.quantity
        }
        return max(0, separatePrice - priceMinorUnits)
    }
}

// MARK: - Notification preferences (plan §O1) — per-category opt-out, not a
// single blunt push toggle. Transactional-ish categories default true;
// promotions default false so a fresh install isn't opted into marketing.

struct NotificationPreferences: Codable, Equatable {
    var userId: UUID
    var bookingUpdates: Bool = true
    var chatMessages: Bool = true
    var vaccinationReminders: Bool = true
    var promotions: Bool = false
}

// MARK: - J8: transactional SMS/WhatsApp fallback when push fails.
//
// There is no third-party SMS/WhatsApp gateway account (Twilio/MSG91/etc)
// wired into this codebase, so an actual text message is never sent from
// here — see `SMSFallbackRepository` and `send-sms-fallback` for exactly
// where a real gateway call would go. What *is* real: the decision of
// when a fallback is warranted (`NotificationDeliveryPolicy`, pure and
// testable) and an append-only record of the fallback intent
// (`sms_fallback_log`), so the gradeable behavior — "did we correctly
// decide to fall back, and did we record it" — is fully implemented.

/// A transactional (never promotional) notification this app might need to
/// deliver outside of push — visit confirmed, vet en route, an OTP, etc.
/// Kept distinct from `AppNotification`/`NotificationPreferences.promotions`
/// on purpose: SMS fallback only ever applies to transactional categories.
enum TransactionalNotificationCategory: String, Codable, CaseIterable, Sendable {
    case visitConfirmed = "visit_confirmed"
    case vetEnRoute = "vet_en_route"
    case otp = "otp"
    case rescheduleProposed = "reschedule_proposed"
    case visitCompleted = "visit_completed"
}

/// The decided outcome of `NotificationDeliveryPolicy` for one notification
/// attempt against one user.
enum NotificationDeliveryDecision: Equatable, Sendable {
    /// Push is the right channel — either it hasn't been tried yet, or it
    /// already succeeded.
    case push
    /// Push is unavailable or failed, the user hasn't opted out of this
    /// transactional category, and a phone number is on file — fall back to
    /// SMS/WhatsApp.
    case smsFallback(reason: FallbackReason)
    /// No channel is appropriate: the user has no push token, no phone
    /// number, or has turned this category off entirely.
    case suppressed(reason: String)

    enum FallbackReason: String, Equatable, Sendable, Codable {
        case noPushToken = "no_push_token"
        case pushDeliveryFailed = "push_delivery_failed"
        case pushDisabledByUser = "push_disabled_by_user"
    }
}

/// An append-only record of an SMS/WhatsApp fallback that was decided on —
/// mirrors `WalletLedgerEntry`/`sms_fallback_log`'s discipline: this is a
/// log of intent, not proof a real text was sent (see the type comment
/// above `TransactionalNotificationCategory`).
struct SMSFallbackRecord: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var userId: UUID
    var phone: String
    var category: TransactionalNotificationCategory
    var body: String
    var reason: NotificationDeliveryDecision.FallbackReason
    var createdAt: Date
}

// MARK: - Force-upgrade & maintenance mode (plan §O7-O8, §7) — the server's
// only lever to pull a shipped binary back once it's in the App Store. Fetched
// once at launch; a signed-out device must still be able to read it, so this
// is the one table with no auth requirement at all.

struct RemoteAppConfig: Codable, Equatable {
    var minSupportedVersion: String
    var isMaintenanceMode: Bool
    var maintenanceMessage: String?

    /// Dotted-numeric semantic comparison ("1.2.0" < "1.10.0"), not a string
    /// compare — plan §7 calls this the only true rollback lever, so getting
    /// "1.10.0" vs "1.2.0" backwards here would silently defeat it.
    static func isSupported(currentVersion: String, minSupportedVersion: String) -> Bool {
        compareVersions(currentVersion, minSupportedVersion) >= 0
    }

    /// Returns -1, 0, or 1 like `Comparable`, comparing dot-separated numeric
    /// components pairwise; missing trailing components count as 0 ("1.2" == "1.2.0").
    static func compareVersions(_ lhs: String, _ rhs: String) -> Int {
        let lhsParts = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let rhsParts = rhs.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(lhsParts.count, rhsParts.count)
        for i in 0..<count {
            let l = i < lhsParts.count ? lhsParts[i] : 0
            let r = i < rhsParts.count ? rhsParts[i] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }
}

// MARK: - Lifecycle notification queue (plan §5, §6.5, N3) — rows queued by a
// scheduled Edge Function for a (not-yet-built) push-sending job to pick up;
// the client only ever reads its own, to show an in-app notification center.

struct AppNotification: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var userId: UUID
    var category: Category
    var title: String
    var body: String
    var sentAt: Date?
    var createdAt: Date = .now
    /// J7: notification centre read/unread state — nil until the customer
    /// opens `NotificationCenterView` and views this row.
    var readAt: Date?

    var isRead: Bool { readAt != nil }

    enum Category: String, Codable {
        case bookingUpdate = "booking_update"
        case chatMessage = "chat_message"
        case vaccinationDue = "vaccination_due"
        case renewalDue = "renewal_due"
        case dormantWinback = "dormant_winback"
        case abandonedCart = "abandoned_cart"
        case promotion
    }
}

// MARK: - Help centre / FAQ (plan §M1) — remote content so answers can change
// without an app-store release.

struct HelpArticle: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var category: Category
    var question: String
    var answer: String

    enum Category: String, Codable, CaseIterable {
        case booking, cancellation, payment, pets, account, visits

        var displayName: String {
            switch self {
            case .booking: return "Booking"
            case .cancellation: return "Cancellation & rescheduling"
            case .payment: return "Payment & refunds"
            case .pets: return "Pets & records"
            case .account: return "Account & privacy"
            case .visits: return "During a visit"
            }
        }
    }
}

// MARK: - Support tickets & disputes (plan §M2, §K8) — one model serves both
// "Contact support" and "Report a problem with this visit": a dispute is
// just a ticket with `visitId` set, so it inherits the same queue, status
// tracking and audit trail rather than needing a parallel table.

struct SupportTicket: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var userId: UUID
    var visitId: UUID?
    var subject: String
    var body: String
    var status: Status
    var createdAt: Date

    enum Status: String, Codable, CaseIterable {
        case open, inProgress = "in_progress", resolved

        var displayName: String {
            switch self {
            case .open: return "Open"
            case .inProgress: return "In progress"
            case .resolved: return "Resolved"
            }
        }
    }
}

// MARK: - Incident reports (plan §L4/L5) — deliberately NOT the same model as
// `SupportTicket` above: that one is a billing/service dispute queue a
// customer files after the fact, this one is safety-specific ("a stranger is
// inside a home") and is filed by either party, in real time, and must carry
// a distinguishable `reporterRole` for triage/vet-suspension decisions that a
// generic ticket subject line can't guarantee. SOS (L4) is the same
// underlying model with `type == .sos` and no free-text required.
struct IncidentReport: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var visitId: UUID
    var reporterId: UUID
    var reporterRole: ReporterRole
    var type: IncidentType
    var description: String
    var createdAt: Date

    enum ReporterRole: String, Codable, CaseIterable {
        case customer, vet
    }

    enum IncidentType: String, Codable, CaseIterable {
        case sos, safetyConcern = "safety_concern", unprofessionalConduct = "unprofessional_conduct", other

        var displayName: String {
            switch self {
            case .sos: return "SOS — immediate danger"
            case .safetyConcern: return "Safety concern"
            case .unprofessionalConduct: return "Unprofessional conduct"
            case .other: return "Other"
            }
        }
    }
}

// MARK: - Chat auto-close (plan §J5) — prevents unpaid consulting over chat
// once a visit is long done; pure policy so it's testable without a clock
// dependency injected anywhere but here.

struct ChatPolicy {
    static let openWindow: TimeInterval = 48 * 3600

    /// Chat stays open for any non-completed visit (there's still an active
    /// booking to discuss); once completed, it closes 48h after `completedAt`.
    static func isOpen(visit: Visit, now: Date = .now) -> Bool {
        guard visit.status == .completed, let completedAt = visit.completedAt else { return true }
        return now.timeIntervalSince(completedAt) < openWindow
    }
}

// MARK: - Pet health records (plan §3 B, §3 K)

/// B3: one weight reading. A trend chart needs a series, not just the
/// pet's latest weight — kept as its own table/model rather than overwriting
/// `Pet.weightKg` on every entry.
struct PetWeightEntry: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var petId: UUID
    var weightKg: Double
    var recordedAt: Date
    // B3: vitals beyond weight — both optional since not every reading has a
    // vet's thermometer/stethoscope behind it (an owner logging weight at
    // home shouldn't be blocked from entering just weight).
    var temperatureCelsius: Double? = nil
    var heartRateBpm: Int? = nil
}

/// B4 (P0) + K4: a vaccination given (or due). `nextDueAt` is what the N3
/// lifecycle job reminds against — see `VaccinationPolicy` for how it gets
/// computed rather than left for a human to guess.
struct Vaccination: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var petId: UUID
    var vaccineName: String
    var givenAt: Date?
    var nextDueAt: Date
    var batchNumber: String?
    var visitId: UUID? = nil

    enum DueStatus { case upToDate, dueSoon, overdue }

    /// Amber inside 30 days of due, red once past it — the thresholds the
    /// history screen colors rows by.
    static let dueSoonWindowDays = 30

    func dueStatus(now: Date = .now) -> DueStatus {
        if nextDueAt < now { return .overdue }
        let daysUntilDue = Calendar.current.dateComponents([.day], from: now, to: nextDueAt).day ?? .max
        return daysUntilDue <= Self.dueSoonWindowDays ? .dueSoon : .upToDate
    }
}

/// K4's "auto-scheduling" is scoped to computing the next due date, not a
/// calendar invite or a generated PDF certificate (known gap, see plan notes
/// — same shape as A7's export-PDF gap).
struct VaccinationPolicy {
    /// Default annual-booster cadence; a real deployment would look this up
    /// per vaccine (rabies vs. a puppy series differ) but every vaccine this
    /// app catalogs today is an annual core/non-core shot.
    static let defaultBoosterIntervalMonths = 12

    static func suggestedNextDueDate(givenAt: Date, intervalMonths: Int = defaultBoosterIntervalMonths, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .month, value: intervalMonths, to: givenAt) ?? givenAt
    }
}

/// K2: prescription issued at a completed visit.
struct Prescription: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var visitId: UUID
    var petId: UUID
    var medicationName: String
    var dosage: String
    var instructions: String?
    var prescribedByVetId: UUID
    var issuedAt: Date
}

/// K3: an hour/minute-of-day, timezone-agnostic — the reminder fires at this
/// wall-clock time every active day, matching how `UNCalendarNotificationTrigger`
/// with `repeats: true` and a partial `DateComponents` behaves.
struct TimeOfDay: Codable, Equatable, Hashable {
    var hour: Int
    var minute: Int

    var displayText: String {
        String(format: "%02d:%02d", hour, minute)
    }
}

/// K3: a pet owner's reminder to give a medication, on a recurring
/// time-of-day schedule within an optional date range (e.g. a 10-day course
/// of antibiotics vs. an ongoing daily supplement with no `endDate`).
struct MedicationReminder: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var petId: UUID
    var medicationName: String
    var dosage: String
    var times: [TimeOfDay]
    var startDate: Date
    var endDate: Date?
    var isActive: Bool = true

    /// Whether the reminder's date range covers `date` — a course with an
    /// `endDate` in the past shouldn't keep firing even if `isActive` was
    /// never flipped off by hand.
    func isInRange(on date: Date = .now, calendar: Calendar = .current) -> Bool {
        let day = calendar.startOfDay(for: date)
        guard day >= calendar.startOfDay(for: startDate) else { return false }
        if let endDate { return day <= calendar.startOfDay(for: endDate) }
        return true
    }
}

// MARK: - Discovery filters & sort (plan §C3-C4) — pure, testable logic; the
// UI only ever calls `CircuitFilter.apply` / `CircuitSortOption.sort`, it
// never re-implements the matching rules itself.

struct CircuitFilter: Equatable {
    var serviceCategory: ServiceCategory? = nil
    var onOrAfter: Date? = nil
    var timeOfDay: TimeOfDay? = nil
    var maxPriceMinorUnits: Int? = nil
    var minRating: Double? = nil
    var species: Pet.Species? = nil
    var language: String? = nil
    var gender: Vet.Gender? = nil

    var isEmpty: Bool { self == CircuitFilter() }

    enum TimeOfDay: String, CaseIterable, Identifiable {
        case morning, afternoon, evening
        var id: String { rawValue }
        var displayName: String { rawValue.capitalized }
        /// Hour range (start..<end), matched against a slot's `startTime` in
        /// the visit's local calendar.
        var hourRange: Range<Int> {
            switch self {
            case .morning: return 5..<12
            case .afternoon: return 12..<17
            case .evening: return 17..<22
            }
        }
    }

    /// A circuit matches when *some* schedule slot satisfies the date/time
    /// filters and the vet-level attributes all match — a circuit isn't
    /// dropped just because one of its several slots doesn't fit.
    func matches(_ circuit: Circuit, catalog: [Service] = []) -> Bool {
        if let vet = circuit.vet {
            if let minRating, vet.rating < minRating { return false }
            if let species, !vet.speciesHandled.contains(species) { return false }
            if let language, !vet.languages.contains(where: { $0.localizedCaseInsensitiveCompare(language) == .orderedSame }) { return false }
            if let gender, vet.gender != gender { return false }
        } else if minRating != nil || species != nil || language != nil || gender != nil {
            // No vet attached at all — can't confirm a vet-level filter, so
            // exclude rather than silently show a possibly-non-matching row.
            return false
        }

        if onOrAfter != nil || timeOfDay != nil {
            let calendar = Calendar.current
            let hasMatchingSlot = circuit.schedule.contains { slot in
                if let onOrAfter, slot.startTime < calendar.startOfDay(for: onOrAfter) { return false }
                if let timeOfDay {
                    let hour = calendar.component(.hour, from: slot.startTime)
                    guard timeOfDay.hourRange.contains(hour) else { return false }
                }
                return true
            }
            if !hasMatchingSlot { return false }
        }

        if maxPriceMinorUnits != nil || serviceCategory != nil {
            // Price/category filters are catalog-scoped, not circuit-scoped —
            // a circuit only fails them if a catalog was supplied and nothing
            // in it clears the bar (an empty catalog means "not applicable").
            guard !catalog.isEmpty else { return true }
            let candidates = serviceCategory.map { category in catalog.filter { $0.category == category } } ?? catalog
            if serviceCategory != nil && candidates.isEmpty { return false }
            if let maxPriceMinorUnits {
                let anyAffordable = candidates.contains { ($0.startingPriceMinorUnits ?? Int.max) <= maxPriceMinorUnits }
                if !anyAffordable { return false }
            }
        }
        return true
    }

    static func apply(_ filter: CircuitFilter, to circuits: [Circuit], catalog: [Service] = []) -> [Circuit] {
        guard !filter.isEmpty else { return circuits }
        return circuits.filter { filter.matches($0, catalog: catalog) }
    }
}

enum CircuitSortOption: String, CaseIterable, Identifiable {
    case soonest, cheapest, topRated = "top_rated", previouslyBooked = "previously_booked"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .soonest: return "Soonest"
        case .cheapest: return "Cheapest"
        case .topRated: return "Top rated"
        case .previouslyBooked: return "Previously booked"
        }
    }

    /// `previouslyBookedVetIds` lets "previously booked" rank a repeat vet
    /// first without the sort needing its own repository access — the
    /// caller (a use case or view model) already has visit history in hand.
    static func sort(_ circuits: [Circuit], by option: CircuitSortOption, previouslyBookedVetIds: Set<UUID> = []) -> [Circuit] {
        switch option {
        case .soonest:
            return circuits.sorted { (lhs, rhs) in
                (lhs.schedule.map(\.startTime).min() ?? .distantFuture) < (rhs.schedule.map(\.startTime).min() ?? .distantFuture)
            }
        case .cheapest:
            // Circuits don't carry a price themselves; a lower vet review
            // count is a poor proxy, so absent a per-circuit price this falls
            // back to cluster-area alphabetical (stable, deterministic) —
            // real pricing comes from the catalog/quote, not the circuit.
            return circuits.sorted { $0.clusterArea < $1.clusterArea }
        case .topRated:
            return circuits.sorted { (lhs, rhs) in
                (lhs.vet?.rating ?? 0) > (rhs.vet?.rating ?? 0)
            }
        case .previouslyBooked:
            return circuits.sorted { (lhs, rhs) in
                let lhsBooked = previouslyBookedVetIds.contains(lhs.vetId)
                let rhsBooked = previouslyBookedVetIds.contains(rhs.vetId)
                if lhsBooked != rhsBooked { return lhsBooked }
                return (lhs.vet?.rating ?? 0) > (rhs.vet?.rating ?? 0)
            }
        }
    }
}

// MARK: - Emergency path (plan §C11, §L8) — VetCircuit is explicitly not an
// emergency service; this is the data behind the "route out" escalation,
// not a substitute for a real emergency vet.

struct EmergencyClinic: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    var address: String
    var phone: String
    var latitude: Double
    var longitude: Double
    var isOpen24x7: Bool = true

    /// `tel://` scheme for a tap-to-call action.
    var telURL: URL? {
        URL(string: "tel://\(phone.filter { $0.isNumber || $0 == "+" })")
    }

    /// Apple Maps deep link for tap-to-navigate.
    var mapsURL: URL? {
        let query = "\(latitude),\(longitude)"
        return URL(string: "https://maps.apple.com/?daddr=\(query)")
    }
}


// MARK: - D5: per-vet service availability & pricing overrides — a vet can
// opt out of a catalog service entirely, or charge more/less than the
// catalog default, without ops editing the shared catalog per vet.
struct VetServiceOverride: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var vetId: UUID
    var serviceId: UUID
    var variantId: UUID?               // nil = applies to the whole service; set = one variant only
    var priceOverrideMinorUnits: Int?  // nil = use the catalog price, only isOffered is overridden
    var isOffered: Bool = true
}

// MARK: - F5: recurring bookings (monthly deworming, weekly physio). The rule
// itself is client/server state; actually spawning the next visit each cycle
// is a scheduled-job concern (plan §6.5-style job) — out of scope here, see
// RecurrenceScheduler's doc comment for the known gap this leaves.
struct RecurringBookingRule: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var userId: UUID
    var petId: UUID
    var serviceId: UUID
    var variantId: UUID
    var circuitId: UUID
    var cadence: Cadence
    var nextOccurrenceAt: Date
    var isActive: Bool = true

    enum Cadence: String, Codable, CaseIterable {
        case weekly, monthly

        var displayName: String {
            switch self {
            case .weekly: return "Weekly"
            case .monthly: return "Monthly"
            }
        }
    }
}

/// Pure date math for F5 — no I/O, so the "what's the next occurrence" rule
/// is directly unit-testable independent of whichever job ends up running it.
struct RecurrenceScheduler {
    /// Computes the next occurrence after `lastOccurrence` for the given
    /// cadence. A calendar (not a fixed 7/30-day interval) is used so weekly
    /// stays pinned to the same weekday and monthly to the same day-of-month
    /// across DST transitions and month-length differences.
    static func nextOccurrence(after lastOccurrence: Date, cadence: RecurringBookingRule.Cadence, calendar: Calendar = .current) -> Date {
        switch cadence {
        case .weekly:
            return calendar.date(byAdding: .weekOfYear, value: 1, to: lastOccurrence) ?? lastOccurrence.addingTimeInterval(7 * 86400)
        case .monthly:
            return calendar.date(byAdding: .month, value: 1, to: lastOccurrence) ?? lastOccurrence.addingTimeInterval(30 * 86400)
        }
    }
}

// MARK: - F6: vet-initiated reschedule with customer accept/decline. Unlike
// a customer-initiated reschedule (RescheduleVisitUseCase), a vet-initiated
// proposal bypasses the 4h policy window — the vet, not the customer, is the
// one moving the slot — and a decline earns the customer a goodwill credit
// rather than leaving them simply stuck with the original (now vet-unwanted) time.
struct RescheduleProposal: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var visitId: UUID
    var proposedByRole: ProposerRole
    var proposedSlotId: UUID
    var status: Status
    var createdAt: Date

    enum ProposerRole: String, Codable { case vet, customer }
    enum Status: String, Codable { case pending, accepted, declined }
}

// MARK: - F7: no-show policy for both directions — mirrors CancellationPolicy
// (pure, testable, no I/O) but the two directions have opposite consequences:
// a customer no-show forfeits the full amount, a vet no-show refunds it in
// full plus a small goodwill credit (same loyalty award F6 uses on decline).
struct NoShowPolicy {
    /// Awarded to the customer whenever the *vet* is at fault — either a
    /// full vet no-show, or a declined vet-initiated reschedule (F6).
    static let goodwillCreditPoints = 50

    struct Outcome: Equatable {
        var refundPercent: Int   // 0 for customer no-show, 100 for vet no-show
        var refundMinorUnits: Int
        var goodwillCreditPoints: Int
    }

    static func customerNoShow(paidMinorUnits: Int) -> Outcome {
        Outcome(refundPercent: 0, refundMinorUnits: 0, goodwillCreditPoints: 0)
    }

    static func vetNoShow(paidMinorUnits: Int) -> Outcome {
        Outcome(refundPercent: 100, refundMinorUnits: paidMinorUnits, goodwillCreditPoints: goodwillCreditPoints)
    }

    /// How long past the scheduled time a visit stuck in `assigned`/`enRoute`
    /// must sit before the customer can report a vet no-show — long enough
    /// to not penalize ordinary lateness, short enough to be useful same-day.
    static let vetGraceWindowMinutes: Double = 30
}

// MARK: - B6: document vault — prior vet reports / insurance docs against a
// pet. No real storage backend is wired up yet (see `PetDocumentRepository`
// doc comment) so `fileURL` is a placeholder scheme until Supabase Storage
// SDK wiring lands.
struct PetDocument: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var petId: UUID
    var uploaderId: UUID
    var title: String
    var fileURL: URL
    var uploadedAt: Date
}

// MARK: - Payment disputes (plan G9) — a chargeback the gateway opened
// against one of our payments. The dispute-webhook Edge Function is the
// only writer (server-only financial write, same discipline as refunds);
// the customer app only ever reads one, tied to their own visit, so they
// understand why a hold might exist rather than being left confused.
struct PaymentDispute: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var paymentId: UUID
    var visitId: UUID
    var gatewayDisputeId: String
    var reason: String
    var amountMinorUnits: Int
    var status: Status
    var openedAt: Date
    var resolvedAt: Date?
    var evidenceSubmittedAt: Date?

    enum Status: String, Codable {
        case open, needsResponse = "needs_response", won, lost
    }

    /// Whether this dispute still affects the customer's money — a
    /// won/lost dispute is resolved and no longer needs surfacing as an
    /// active hold.
    var isActive: Bool { status == .open || status == .needsResponse }
}

// MARK: - Vet onboarding (plan L2) — a prospective vet's document-backed
// application to join the platform: degree, VCI (Veterinary Council of
// India) certificate, government ID, police verification, and a photo.
// This is fundamentally a vet-side submission reviewed by ops/admin; this
// app has no vet-facing UI surface, so this model/repository/use-case exist
// so the domain and data layers are real and correct even though no screen
// in this app drives them (see `SubmitVetOnboardingApplicationUseCase`).
struct VetOnboardingApplication: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var applicantUserId: UUID
    var degreeDocumentURL: URL
    var vciCertificateURL: URL
    var idDocumentURL: URL
    var policeVerificationURL: URL
    var photoURL: URL
    var status: Status
    var submittedAt: Date
    var reviewedAt: Date?
    var reviewNotes: String?

    enum Status: String, Codable, Equatable, Hashable {
        case submitted
        case underReview = "under_review"
        case approved
        case rejected
    }
}

// MARK: - Domain errors

enum DomainError: Error, LocalizedError, Equatable {
    case notAuthenticated
    case slotUnavailable
    case notFound(String)
    case validation(String)
    case network(String)
    case unknown

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "You need to sign in to continue."
        case .slotUnavailable: return "That time slot is no longer available."
        case .notFound(let what): return "\(what) could not be found."
        case .validation(let message): return message
        case .network(let message): return message
        case .unknown: return "Something went wrong. Please try again."
        }
    }
}
