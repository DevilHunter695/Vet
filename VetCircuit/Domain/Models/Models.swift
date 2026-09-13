import Foundation

// MARK: - Core domain models (pure Swift, no framework imports)

struct User: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var phone: String?
    var name: String
    var email: String?
    var createdAt: Date
    var pets: [Pet]
}

struct Pet: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var ownerId: UUID
    var name: String
    var species: Species
    var breed: String?
    var dateOfBirth: Date?

    enum Species: String, Codable, CaseIterable {
        case dog, cat, bird, other
    }
}

struct Vet: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    var licenseNumber: String
    var verificationStatus: VerificationStatus
    var rating: Double
    var reviewCount: Int
    var photoURL: URL?

    enum VerificationStatus: String, Codable {
        case pending, verified, rejected
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
        .assigned: [.enRoute, .cancelledByUser, .cancelledByVet],
        .enRoute: [.arrived, .cancelledByVet],
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
        case active, cancelled, expired, pastDue = "past_due"
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
}

struct Review: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var visitId: UUID
    var vetId: UUID
    var userId: UUID
    var rating: Int // 1...5
    var comment: String?
    var createdAt: Date
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

// MARK: - Cart, pricing & checkout (plan §E) — a server-authoritative quote
// is the only thing an order may ever reference; the client never computes
// a rupee (Appendix C).

struct CartItem: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var serviceId: UUID
    var variantId: UUID
    var petIds: [UUID]           // 1 or more pets on this line item (D6: multi-pet)
    var addonIds: [UUID] = []
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

struct PriceBreakdown: Codable, Equatable {
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

struct Service: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var category: ServiceCategory
    var name: String
    var summary: String
    var whatToPrepare: String?
    var variants: [ServiceVariant]
    var addons: [Addon] = []
    var eligibility: ServiceEligibility = ServiceEligibility()

    var startingPriceMinorUnits: Int? {
        variants.map(\.priceMinorUnits).min()
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
