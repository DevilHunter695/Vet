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
    var isAvailable: Bool
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

    enum VisitStatus: String, Codable, CaseIterable {
        case requested
        case confirmed
        case enRoute = "en_route"
        case completed
        case cancelled

        var displayText: String {
            switch self {
            case .requested: return "Requested"
            case .confirmed: return "Confirmed"
            case .enRoute: return "Vet en route"
            case .completed: return "Completed"
            case .cancelled: return "Cancelled"
            }
        }
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
