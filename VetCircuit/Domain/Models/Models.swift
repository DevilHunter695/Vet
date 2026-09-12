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

    enum PlanType: String, Codable {
        case monthly, quarterly, annual
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
