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

final class SupabaseSlotHoldRepository: SlotHoldRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func placeHold(slotId: UUID, userId: UUID) async throws -> SlotHold {
        struct Insert: Encodable {
            let slotId: UUID
            let userId: UUID
            let expiresAt: Date
            enum CodingKeys: String, CodingKey { case slotId = "slot_id", userId = "user_id", expiresAt = "expires_at" }
        }
        let insert = Insert(slotId: slotId, userId: userId, expiresAt: Date().addingTimeInterval(SlotHold.holdDuration))
        let rows: [SupabaseSlotHoldRow] = try await client.from("slot_holds").insert(insert).select().execute().value
        guard let row = rows.first else { throw DomainError.unknown }
        return row.toDomain()
    }

    func releaseHold(id: UUID) async throws {
        try await client.from("slot_holds").delete().eq("id", value: id).execute()
    }

    func activeHolds(slotId: UUID) async throws -> [SlotHold] {
        let rows: [SupabaseSlotHoldRow] = try await client
            .from("slot_holds").select().eq("slot_id", value: slotId)
            .gt("expires_at", value: ISO8601DateFormatter().string(from: Date()))
            .execute().value
        return rows.map { $0.toDomain() }
    }
}

final class SupabaseAddressRepository: AddressRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func listAddresses(ownerId: UUID) async throws -> [Address] {
        let rows: [SupabaseAddressRow] = try await client
            .from("addresses").select().eq("owner_id", value: ownerId)
            .order("is_default", ascending: false)
            .execute().value
        return rows.map { $0.toDomain() }
    }

    func addAddress(_ address: Address) async throws -> Address {
        let insert = SupabaseAddressInsert(address: address)
        let rows: [SupabaseAddressRow] = try await client.from("addresses").insert(insert).select().execute().value
        guard let row = rows.first else { throw DomainError.unknown }
        return row.toDomain()
    }

    func updateAddress(_ address: Address) async throws -> Address {
        let insert = SupabaseAddressInsert(address: address)
        let rows: [SupabaseAddressRow] = try await client
            .from("addresses").update(insert).eq("id", value: address.id).select().execute().value
        guard let row = rows.first else { throw DomainError.notFound("Address") }
        return row.toDomain()
    }

    func deleteAddress(id: UUID) async throws {
        try await client.from("addresses").delete().eq("id", value: id).execute()
    }

    func setDefault(id: UUID, ownerId: UUID) async throws {
        try await client.from("addresses").update(["is_default": false]).eq("owner_id", value: ownerId).execute()
        try await client.from("addresses").update(["is_default": true]).eq("id", value: id).execute()
    }

    func matchCluster(latitude: Double, longitude: Double) async throws -> String? {
        struct MatchResult: Decodable { let match_cluster: String? }
        let result: String? = try await client.rpc("match_cluster", params: ["p_lat": latitude, "p_lng": longitude]).execute().value
        return result
    }
}

final class SupabaseCatalogRepository: CatalogRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func listServices(vertical: Vertical?) async throws -> [Service] {
        var query = client.from("services")
            .select("*, service_variants(*), addons(*)")
            .eq("is_active", value: true)
        if let vertical {
            let categories = ServiceCategory.allCases.filter { $0.vertical == vertical }.map(\.rawValue)
            query = query.in("category", values: categories)
        }
        let rows: [SupabaseServiceRow] = try await query.execute().value
        return rows.map { $0.toDomain() }
    }

    func service(id: UUID) async throws -> Service {
        let rows: [SupabaseServiceRow] = try await client
            .from("services")
            .select("*, service_variants(*), addons(*)")
            .eq("id", value: id)
            .execute()
            .value
        guard let row = rows.first else { throw DomainError.notFound("Service") }
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

private struct SupabaseSlotHoldRow: Decodable {
    let id: UUID
    let slotId: UUID
    let userId: UUID
    let expiresAt: Date

    enum CodingKeys: String, CodingKey { case id, slotId = "slot_id", userId = "user_id", expiresAt = "expires_at" }

    func toDomain() -> SlotHold { SlotHold(id: id, slotId: slotId, userId: userId, expiresAt: expiresAt) }
}

private struct SupabaseAddressRow: Decodable {
    let id: UUID
    let ownerId: UUID
    let label: String
    let line1: String
    let line2: String?
    let landmark: String?
    let accessNotes: String?
    let latitude: Double
    let longitude: Double
    let clusterArea: String?
    let isDefault: Bool

    enum CodingKeys: String, CodingKey {
        case id, label, line1, line2, landmark, latitude, longitude
        case ownerId = "owner_id", accessNotes = "access_notes", clusterArea = "cluster_area", isDefault = "is_default"
    }

    func toDomain() -> Address {
        Address(id: id, ownerId: ownerId, label: label, line1: line1, line2: line2, landmark: landmark,
                accessNotes: accessNotes, latitude: latitude, longitude: longitude,
                clusterArea: clusterArea, isDefault: isDefault)
    }
}

private struct SupabaseAddressInsert: Encodable {
    let ownerId: UUID
    let label: String
    let line1: String
    let line2: String?
    let landmark: String?
    let accessNotes: String?
    let latitude: Double
    let longitude: Double
    let clusterArea: String?
    let isDefault: Bool

    enum CodingKeys: String, CodingKey {
        case label, line1, line2, landmark, latitude, longitude
        case ownerId = "owner_id", accessNotes = "access_notes", clusterArea = "cluster_area", isDefault = "is_default"
    }

    init(address: Address) {
        ownerId = address.ownerId
        label = address.label
        line1 = address.line1
        line2 = address.line2
        landmark = address.landmark
        accessNotes = address.accessNotes
        latitude = address.latitude
        longitude = address.longitude
        clusterArea = address.clusterArea
        isDefault = address.isDefault
    }
}

private struct SupabaseServiceRow: Decodable {
    let id: UUID
    let category: String
    let name: String
    let summary: String
    let whatToPrepare: String?
    let eligibleSpecies: [String]?
    let requiresPrescriberVet: Bool
    let minPetAgeMonths: Int?
    let serviceVariants: [SupabaseServiceVariantRow]?
    let addons: [SupabaseAddonRow]?

    enum CodingKeys: String, CodingKey {
        case id, category, name, summary
        case whatToPrepare = "what_to_prepare", eligibleSpecies = "eligible_species"
        case requiresPrescriberVet = "requires_prescriber_vet", minPetAgeMonths = "min_pet_age_months"
        case serviceVariants = "service_variants", addons
    }

    func toDomain() -> Service {
        Service(
            id: id, category: ServiceCategory(rawValue: category) ?? .consult, name: name, summary: summary,
            whatToPrepare: whatToPrepare,
            variants: (serviceVariants ?? []).map { $0.toDomain(serviceId: id) },
            addons: (addons ?? []).map { $0.toDomain() },
            eligibility: ServiceEligibility(
                species: eligibleSpecies?.compactMap { Pet.Species(rawValue: $0) },
                requiresPrescriberVet: requiresPrescriberVet,
                minPetAgeMonths: minPetAgeMonths
            )
        )
    }
}

private struct SupabaseServiceVariantRow: Decodable {
    let id: UUID
    let name: String
    let durationMinutes: Int
    let priceMinorUnits: Int
    let additionalPetPriceMinorUnits: Int
    let isFollowUp: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, durationMinutes = "duration_minutes", priceMinorUnits = "price_minor_units"
        case additionalPetPriceMinorUnits = "additional_pet_price_minor_units", isFollowUp = "is_follow_up"
    }

    func toDomain(serviceId: UUID) -> ServiceVariant {
        ServiceVariant(id: id, serviceId: serviceId, name: name, durationMinutes: durationMinutes,
                       priceMinorUnits: priceMinorUnits, additionalPetPriceMinorUnits: additionalPetPriceMinorUnits,
                       isFollowUp: isFollowUp)
    }
}

private struct SupabaseAddonRow: Decodable {
    let id: UUID
    let name: String
    let priceMinorUnits: Int
    let eligibleSpecies: [String]?

    enum CodingKeys: String, CodingKey {
        case id, name, priceMinorUnits = "price_minor_units", eligibleSpecies = "eligible_species"
    }

    func toDomain() -> Addon {
        Addon(id: id, name: name, priceMinorUnits: priceMinorUnits,
              eligibility: ServiceEligibility(species: eligibleSpecies?.compactMap { Pet.Species(rawValue: $0) }))
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
    let capacity: Int
    let bookedCount: Int

    enum CodingKeys: String, CodingKey {
        case id, dayOfWeek = "day_of_week", startTime = "start_time", endTime = "end_time"
        case capacity, bookedCount = "booked_count"
    }

    func toDomain() -> ScheduleSlot {
        ScheduleSlot(id: id, dayOfWeek: dayOfWeek, startTime: startTime, endTime: endTime, capacity: capacity, bookedCount: bookedCount)
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
