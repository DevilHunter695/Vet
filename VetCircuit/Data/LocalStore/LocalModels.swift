import Foundation
import SwiftData

// MARK: - SwiftData models for offline caching (bookings, chat, vet profiles)
// These mirror Domain models but are framework-bound, kept isolated to the Data layer.

@Model
final class CachedVisit {
    @Attribute(.unique) var id: UUID
    var userId: UUID
    var petId: UUID
    var vetId: UUID
    var circuitId: UUID
    var status: String
    var scheduledAt: Date
    var completedAt: Date?
    var notes: String?
    var paymentId: UUID?
    var lastSyncedAt: Date

    init(from visit: Visit, lastSyncedAt: Date = .now) {
        self.id = visit.id
        self.userId = visit.userId
        self.petId = visit.petId
        self.vetId = visit.vetId
        self.circuitId = visit.circuitId
        self.status = visit.status.rawValue
        self.scheduledAt = visit.scheduledAt
        self.completedAt = visit.completedAt
        self.notes = visit.notes
        self.paymentId = visit.paymentId
        self.lastSyncedAt = lastSyncedAt
    }

    func toDomain() -> Visit {
        Visit(
            id: id, userId: userId, petId: petId, vetId: vetId, circuitId: circuitId,
            status: Visit.VisitStatus(rawValue: status) ?? .requested,
            scheduledAt: scheduledAt, completedAt: completedAt, notes: notes, paymentId: paymentId
        )
    }
}

@Model
final class CachedChatMessage {
    @Attribute(.unique) var id: UUID
    var visitId: UUID
    var senderId: UUID
    var body: String
    var sentAt: Date
    var readAt: Date?

    init(from message: ChatMessage) {
        self.id = message.id
        self.visitId = message.visitId
        self.senderId = message.senderId
        self.body = message.body
        self.sentAt = message.sentAt
        self.readAt = message.readAt
    }

    func toDomain() -> ChatMessage {
        ChatMessage(id: id, visitId: visitId, senderId: senderId, body: body, sentAt: sentAt, readAt: readAt)
    }
}

@Model
final class CachedVetProfile {
    @Attribute(.unique) var id: UUID
    var name: String
    var licenseNumber: String
    var verificationStatus: String
    var rating: Double
    var reviewCount: Int

    init(from vet: Vet) {
        self.id = vet.id
        self.name = vet.name
        self.licenseNumber = vet.licenseNumber
        self.verificationStatus = vet.verificationStatus.rawValue
        self.rating = vet.rating
        self.reviewCount = vet.reviewCount
    }

    func toDomain() -> Vet {
        Vet(
            id: id, name: name, licenseNumber: licenseNumber,
            verificationStatus: Vet.VerificationStatus(rawValue: verificationStatus) ?? .pending,
            rating: rating, reviewCount: reviewCount, photoURL: nil
        )
    }
}

enum LocalStoreSchema {
    static var models: [any PersistentModel.Type] {
        [CachedVisit.self, CachedChatMessage.self, CachedVetProfile.self]
    }
}
