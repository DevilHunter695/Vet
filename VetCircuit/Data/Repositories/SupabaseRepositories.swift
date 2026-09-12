import Foundation

// MARK: - Supabase-backed repository implementations
//
// These wrap the Supabase Swift SDK (https://github.com/supabase/supabase-swift).
// Add the package dependency in Xcode:
//   https://github.com/supabase-community/supabase-swift  (from: "2.0.0")
//
// Row Level Security (see backend/supabase/migrations) enforces that a user can
// only read/write rows they own — the client never needs to (and must never)
// trust its own role checks for authorization.

#if canImport(Supabase)
import Supabase

final class SupabaseAuthRepository: AuthRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func currentUser() async -> User? {
        guard let session = try? await client.auth.session else { return nil }
        return try? await fetchProfile(authId: session.user.id)
    }

    func signInWithApple(identityToken: String, nonce: String) async throws -> User {
        let session = try await client.auth.signInWithIdToken(
            credentials: .init(provider: .apple, idToken: identityToken, nonce: nonce)
        )
        return try await fetchProfile(authId: session.user.id)
    }

    func requestOTP(phone: String) async throws {
        try await client.auth.signInWithOTP(phone: phone)
    }

    func verifyOTP(phone: String, code: String) async throws -> User {
        let session = try await client.auth.verifyOTP(phone: phone, token: code, type: .sms)
        return try await fetchProfile(authId: session.user.id)
    }

    func signOut() async throws {
        try await client.auth.signOut()
    }

    private func fetchProfile(authId: UUID) async throws -> User {
        let response: [SupabaseUserRow] = try await client
            .from("users")
            .select("*, pets(*)")
            .eq("id", value: authId)
            .execute()
            .value
        guard let row = response.first else { throw DomainError.notFound("User profile") }
        return row.toDomain()
    }
}

final class SupabaseCircuitRepository: CircuitRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func listCircuits(area: String?) async throws -> [Circuit] {
        var query = client.from("circuits").select("*, vet:vets(*), schedule:schedule_slots(*)")
        if let area { query = query.eq("cluster_area", value: area) }
        let rows: [SupabaseCircuitRow] = try await query.execute().value
        return rows.map { $0.toDomain() }
    }

    func circuit(id: UUID) async throws -> Circuit {
        let rows: [SupabaseCircuitRow] = try await client
            .from("circuits")
            .select("*, vet:vets(*), schedule:schedule_slots(*)")
            .eq("id", value: id)
            .execute()
            .value
        guard let row = rows.first else { throw DomainError.notFound("Circuit") }
        return row.toDomain()
    }
}

final class SupabaseVisitRepository: VisitRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func createVisit(petId: UUID, vetId: UUID, circuitId: UUID, slot: ScheduleSlot) async throws -> Visit {
        let insert = SupabaseVisitInsert(
            petId: petId, vetId: vetId, circuitId: circuitId,
            status: Visit.VisitStatus.requested.rawValue, scheduledAt: slot.startTime
        )
        let rows: [SupabaseVisitRow] = try await client.from("visits").insert(insert).select().execute().value
        guard let row = rows.first else { throw DomainError.unknown }
        return row.toDomain()
    }

    func listVisits(userId: UUID) async throws -> [Visit] {
        let rows: [SupabaseVisitRow] = try await client
            .from("visits").select().eq("user_id", value: userId)
            .order("scheduled_at", ascending: false)
            .execute().value
        return rows.map { $0.toDomain() }
    }

    func visit(id: UUID) async throws -> Visit {
        let rows: [SupabaseVisitRow] = try await client.from("visits").select().eq("id", value: id).execute().value
        guard let row = rows.first else { throw DomainError.notFound("Visit") }
        return row.toDomain()
    }

    func updateStatus(visitId: UUID, status: Visit.VisitStatus) async throws -> Visit {
        // Server-side RLS restricts this update to the assigned vet or an admin role.
        let rows: [SupabaseVisitRow] = try await client
            .from("visits").update(["status": status.rawValue])
            .eq("id", value: visitId).select().execute().value
        guard let row = rows.first else { throw DomainError.notFound("Visit") }
        return row.toDomain()
    }

    func cancelVisit(visitId: UUID) async throws {
        try await client.from("visits").update(["status": Visit.VisitStatus.cancelled.rawValue])
            .eq("id", value: visitId).execute()
    }
}

// Row DTOs matching the Postgres schema (backend/supabase/migrations).
private struct SupabaseUserRow: Decodable {
    let id: UUID
    let phone: String?
    let name: String
    let email: String?
    let createdAt: Date
    let pets: [SupabasePetRow]?

    enum CodingKeys: String, CodingKey { case id, phone, name, email, createdAt = "created_at", pets }

    func toDomain() -> User {
        User(id: id, phone: phone, name: name, email: email, createdAt: createdAt, pets: (pets ?? []).map { $0.toDomain() })
    }
}

private struct SupabasePetRow: Decodable {
    let id: UUID
    let ownerId: UUID
    let name: String
    let species: String
    let breed: String?
    let dob: Date?

    enum CodingKeys: String, CodingKey { case id, ownerId = "owner_id", name, species, breed, dob }

    func toDomain() -> Pet {
        Pet(id: id, ownerId: ownerId, name: name, species: Pet.Species(rawValue: species) ?? .other, breed: breed, dateOfBirth: dob)
    }
}

private struct SupabaseCircuitRow: Decodable {
    let id: UUID
    let vetId: UUID
    let clusterArea: String
    let vertical: String
    let vet: SupabaseVetRow?
    let schedule: [SupabaseScheduleRow]?

    enum CodingKeys: String, CodingKey { case id, vetId = "vet_id", clusterArea = "cluster_area", vertical, vet, schedule }

    func toDomain() -> Circuit {
        Circuit(id: id, vetId: vetId, vet: vet?.toDomain(), clusterArea: clusterArea,
                schedule: (schedule ?? []).map { $0.toDomain() }, vertical: Vertical(rawValue: vertical) ?? .vet)
    }
}

private struct SupabaseVetRow: Decodable {
    let id: UUID
    let name: String
    let licenseNumber: String
    let verificationStatus: String
    let rating: Double
    let reviewCount: Int

    enum CodingKeys: String, CodingKey {
        case id, name, licenseNumber = "license_number", verificationStatus = "verification_status"
        case rating, reviewCount = "review_count"
    }

    func toDomain() -> Vet {
        Vet(id: id, name: name, licenseNumber: licenseNumber,
            verificationStatus: Vet.VerificationStatus(rawValue: verificationStatus) ?? .pending,
            rating: rating, reviewCount: reviewCount, photoURL: nil)
    }
}

private struct SupabaseScheduleRow: Decodable {
    let id: UUID
    let dayOfWeek: Int
    let startTime: Date
    let endTime: Date
    let isAvailable: Bool

    enum CodingKeys: String, CodingKey {
        case id, dayOfWeek = "day_of_week", startTime = "start_time", endTime = "end_time", isAvailable = "is_available"
    }

    func toDomain() -> ScheduleSlot {
        ScheduleSlot(id: id, dayOfWeek: dayOfWeek, startTime: startTime, endTime: endTime, isAvailable: isAvailable)
    }
}

private struct SupabaseVisitRow: Decodable {
    let id: UUID
    let userId: UUID
    let petId: UUID
    let vetId: UUID
    let circuitId: UUID
    let status: String
    let scheduledAt: Date
    let completedAt: Date?
    let notes: String?
    let paymentId: UUID?

    enum CodingKeys: String, CodingKey {
        case id, userId = "user_id", petId = "pet_id", vetId = "vet_id", circuitId = "circuit_id"
        case status, scheduledAt = "scheduled_at", completedAt = "completed_at", notes, paymentId = "payment_id"
    }

    func toDomain() -> Visit {
        Visit(id: id, userId: userId, petId: petId, vetId: vetId, circuitId: circuitId,
              status: Visit.VisitStatus(rawValue: status) ?? .requested,
              scheduledAt: scheduledAt, completedAt: completedAt, notes: notes, paymentId: paymentId)
    }
}

private struct SupabaseVisitInsert: Encodable {
    let petId: UUID
    let vetId: UUID
    let circuitId: UUID
    let status: String
    let scheduledAt: Date

    enum CodingKeys: String, CodingKey {
        case petId = "pet_id", vetId = "vet_id", circuitId = "circuit_id", status, scheduledAt = "scheduled_at"
    }
}

#endif
