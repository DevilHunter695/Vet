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

final class SupabaseCartRepository: CartRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func currentCart(userId: UUID) async throws -> Cart {
        let rows: [SupabaseCartRow] = try await client.from("carts").select("*, cart_items(*)").eq("user_id", value: userId).execute().value
        return rows.first?.toDomain() ?? Cart(id: UUID(), userId: userId)
    }

    func save(_ cart: Cart) async throws -> Cart {
        // Upsert the cart row, then replace its items wholesale — simpler and
        // safer than diffing line items for a cart that's rebuilt on most edits.
        struct CartUpsert: Encodable {
            let id: UUID
            let userId: UUID
            enum CodingKeys: String, CodingKey { case id, userId = "user_id" }
        }
        try await client.from("carts").upsert(CartUpsert(id: cart.id, userId: cart.userId)).execute()
        try await client.from("cart_items").delete().eq("cart_id", value: cart.id).execute()
        if !cart.items.isEmpty {
            struct ItemInsert: Encodable {
                let cartId: UUID
                let serviceId: UUID
                let variantId: UUID
                let petIds: [UUID]
                let addonIds: [UUID]
                enum CodingKeys: String, CodingKey {
                    case cartId = "cart_id", serviceId = "service_id", variantId = "variant_id"
                    case petIds = "pet_ids", addonIds = "addon_ids"
                }
            }
            let inserts = cart.items.map {
                ItemInsert(cartId: cart.id, serviceId: $0.serviceId, variantId: $0.variantId, petIds: $0.petIds, addonIds: $0.addonIds)
            }
            try await client.from("cart_items").insert(inserts).execute()
        }
        return cart
    }

    func clear(userId: UUID) async throws {
        try await client.from("carts").delete().eq("user_id", value: userId).execute()
    }
}

final class SupabaseQuoteRepository: QuoteRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func createQuote(for cart: Cart, catalog: [Service]) async throws -> Quote {
        struct Response: Decodable {
            let id: UUID
            let cartId: UUID
            let breakdown: PriceBreakdown
            let totalMinorUnits: Int
            let signature: String
            let expiresAt: Date
            enum CodingKeys: String, CodingKey {
                case id, breakdown, signature
                case cartId = "cart_id", totalMinorUnits = "total_minor_units", expiresAt = "expires_at"
            }
        }
        let response: Response = try await client.functions.invoke("create-quote", options: .init(body: ["cart_id": cart.id.uuidString])).value
        return Quote(id: response.id, cartId: response.cartId, breakdown: response.breakdown,
                     signature: response.signature, expiresAt: response.expiresAt)
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

    func createVisit(petId: UUID, vetId: UUID, circuitId: UUID, slot: ScheduleSlot, idempotencyKey: String) async throws -> Visit {
        // Calls the atomic book_visit() Postgres function (Appendix D) rather
        // than a raw insert — it locks the slot row, checks capacity, and
        // records the idempotency key all inside one transaction, so a
        // retried request can never oversell or double-book.
        let row: SupabaseVisitRow = try await client.rpc("book_visit", params: [
            "p_pet_id": petId.uuidString, "p_vet_id": vetId.uuidString, "p_circuit_id": circuitId.uuidString,
            "p_slot_id": slot.id.uuidString, "p_scheduled_at": ISO8601DateFormatter().string(from: slot.startTime),
            "p_idempotency_key": idempotencyKey,
        ]).execute().value
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
        try await client.from("visits").update(["status": Visit.VisitStatus.cancelledByUser.rawValue])
            .eq("id", value: visitId).execute()
    }

    func rescheduleVisit(visitId: UUID, newSlot: ScheduleSlot) async throws -> Visit {
        let rows: [SupabaseVisitRow] = try await client
            .from("visits")
            .update(["scheduled_at": ISO8601DateFormatter().string(from: newSlot.startTime)])
            .eq("id", value: visitId).select().execute().value
        guard let row = rows.first else { throw DomainError.notFound("Visit") }
        return row.toDomain()
    }

    func paidAmountMinorUnits(visitId: UUID) async throws -> Int {
        struct AmountRow: Decodable { let amountMinorUnits: Int
            enum CodingKeys: String, CodingKey { case amountMinorUnits = "amount_minor_units" } }
        let rows: [AmountRow] = try await client.from("payments").select("amount_minor_units").eq("visit_id", value: visitId).execute().value
        return rows.first?.amountMinorUnits ?? 0
    }
}

final class SupabaseAccountRepository: AccountRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func requestDeletion(userId: UUID) async throws -> DeletionRequest {
        struct Response: Decodable { let id: UUID }
        // Calls a trusted Edge Function rather than inserting directly — it
        // schedules the purge job and can immediately pause the account
        // (e.g. block new bookings) in the same transaction.
        let response: Response = try await client.functions.invoke("request-account-deletion", options: .init(body: [:])).value
        let scheduledPurgeAt = Calendar.current.date(byAdding: .day, value: DeletionRequest.softWindowDays, to: .now) ?? .now
        return DeletionRequest(id: response.id, userId: userId, requestedAt: .now, scheduledPurgeAt: scheduledPurgeAt, status: .pending)
    }

    func cancelDeletionRequest(userId: UUID) async throws {
        try await client.from("deletion_requests").update(["status": "cancelled"])
            .eq("user_id", value: userId).eq("status", value: "pending").execute()
    }

    func pendingDeletionRequest(userId: UUID) async throws -> DeletionRequest? {
        struct Row: Decodable {
            let id: UUID, userId: UUID, requestedAt: Date, scheduledPurgeAt: Date, status: String
            enum CodingKeys: String, CodingKey {
                case id, status
                case userId = "user_id", requestedAt = "requested_at", scheduledPurgeAt = "scheduled_purge_at"
            }
        }
        let rows: [Row] = try await client.from("deletion_requests").select()
            .eq("user_id", value: userId).eq("status", value: "pending").execute().value
        guard let row = rows.first else { return nil }
        return DeletionRequest(id: row.id, userId: row.userId, requestedAt: row.requestedAt,
                                scheduledPurgeAt: row.scheduledPurgeAt, status: .pending)
    }

    func exportData(userId: UUID) async throws -> DataExport {
        // A real deployment does this as an async job (plan Appendix A:
        // GET /v1/account/export returns a signed download once ready);
        // this synchronous version is the client-visible contract for now.
        let response: DataExport = try await client.functions.invoke("export-account-data", options: .init(body: [:])).value
        return response
    }
}

final class SupabaseCallRepository: CallRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func startCall(visitId: UUID) async throws -> CallSession {
        struct Response: Decodable {
            let id: UUID, visitId: UUID, proxyNumber: String, expiresAt: Date
            enum CodingKeys: String, CodingKey {
                case id, proxyNumber = "proxy_number", expiresAt = "expires_at", visitId = "visit_id"
            }
        }
        let response: Response = try await client.functions.invoke("start-call", options: .init(body: ["visit_id": visitId.uuidString])).value
        return CallSession(id: response.id, visitId: response.visitId, proxyNumber: response.proxyNumber, expiresAt: response.expiresAt)
    }
}

final class SupabaseVisitOTPRepository: VisitOTPRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func generateOTP(visitId: UUID) async throws -> VisitOTP {
        // A real deployment generates this server-side (Edge Function) so the
        // code is never round-tripped through client-writable request data;
        // this reads back whatever the trusted function already wrote.
        let rows: [SupabaseVisitOTPRow] = try await client.from("visit_otps").select().eq("visit_id", value: visitId).execute().value
        guard let row = rows.first else { throw DomainError.notFound("Visit OTP") }
        return row.toDomain()
    }

    func verifyOTP(visitId: UUID, code: String) async throws -> Bool {
        try await client.rpc("verify_visit_otp", params: ["p_visit_id": visitId.uuidString, "p_code": code]).execute().value
    }
}

final class SupabaseConsentRepository: ConsentRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func activeConsents(userId: UUID) async throws -> [ConsentRecord] {
        let rows: [SupabaseConsentRow] = try await client
            .from("consents").select().eq("user_id", value: userId).is("withdrawn_at", value: nil).execute().value
        return rows.map { $0.toDomain() }
    }

    func grant(userId: UUID, purpose: String, version: String) async throws -> ConsentRecord {
        struct Insert: Encodable {
            let userId: UUID, purpose: String, version: String
            enum CodingKeys: String, CodingKey { case userId = "user_id", purpose, version }
        }
        let rows: [SupabaseConsentRow] = try await client.from("consents")
            .insert(Insert(userId: userId, purpose: purpose, version: version)).select().execute().value
        guard let row = rows.first else { throw DomainError.unknown }
        return row.toDomain()
    }

    func withdraw(userId: UUID, purpose: String) async throws {
        try await client.from("consents").update(["withdrawn_at": ISO8601DateFormatter().string(from: Date())])
            .eq("user_id", value: userId).eq("purpose", value: purpose).execute()
    }
}

final class SupabaseRefundRepository: RefundRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func issueRefund(visitId: UUID, paymentId: UUID, amountMinorUnits: Int, reason: String, initiatedByOpsUserId: UUID?) async throws -> Refund {
        // Refunds are money creation (plan §6.2) — the refunds table is
        // select-only under RLS for every client role, customer or admin.
        // This calls the issue-refund Edge Function, the only writer,
        // instead of inserting directly (which RLS would reject outright).
        let row: SupabaseRefundRow = try await client.functions.invoke("issue-refund", options: .init(body: [
            "visit_id": visitId.uuidString, "payment_id": paymentId.uuidString,
            "amount_minor_units": amountMinorUnits, "reason": reason,
        ])).value
        return row.toDomain()
    }

    func refunds(visitId: UUID) async throws -> [Refund] {
        let rows: [SupabaseRefundRow] = try await client.from("refunds").select().eq("visit_id", value: visitId).execute().value
        return rows.map { $0.toDomain() }
    }
}

final class SupabaseInvoiceRepository: InvoiceRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func invoice(visitId: UUID) async throws -> Invoice? {
        let rows: [SupabaseInvoiceRow] = try await client.from("invoices").select().eq("visit_id", value: visitId).execute().value
        return rows.first?.toDomain()
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

private struct SupabaseVisitOTPRow: Decodable {
    let visitId: UUID
    let code: String
    let expiresAt: Date
    let verifiedAt: Date?

    enum CodingKeys: String, CodingKey { case code, visitId = "visit_id", expiresAt = "expires_at", verifiedAt = "verified_at" }

    func toDomain() -> VisitOTP { VisitOTP(visitId: visitId, code: code, expiresAt: expiresAt, verifiedAt: verifiedAt) }
}

private struct SupabaseConsentRow: Decodable {
    let id: UUID
    let userId: UUID
    let purpose: String
    let version: String
    let grantedAt: Date
    let withdrawnAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, purpose, version
        case userId = "user_id", grantedAt = "granted_at", withdrawnAt = "withdrawn_at"
    }

    func toDomain() -> ConsentRecord {
        ConsentRecord(id: id, userId: userId, purpose: purpose, version: version, grantedAt: grantedAt, withdrawnAt: withdrawnAt)
    }
}

private struct SupabaseRefundRow: Decodable {
    let id: UUID
    let visitId: UUID
    let paymentId: UUID
    let amountMinorUnits: Int
    let reason: String
    let status: String
    let createdAt: Date
    let initiatedByOpsUserId: UUID?

    enum CodingKeys: String, CodingKey {
        case id, reason, status
        case visitId = "visit_id", paymentId = "payment_id", amountMinorUnits = "amount_minor_units"
        case createdAt = "created_at", initiatedByOpsUserId = "initiated_by_ops_user_id"
    }

    func toDomain() -> Refund {
        Refund(id: id, visitId: visitId, paymentId: paymentId, amountMinorUnits: amountMinorUnits,
               reason: reason, status: Refund.Status(rawValue: status) ?? .pending, createdAt: createdAt,
               initiatedByOpsUserId: initiatedByOpsUserId)
    }
}

private struct SupabaseInvoiceRow: Decodable {
    let id: UUID
    let visitId: UUID
    let invoiceNumber: String
    let breakdown: PriceBreakdown
    let gstMinorUnits: Int
    let issuedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, breakdown
        case visitId = "visit_id", invoiceNumber = "invoice_number", gstMinorUnits = "gst_minor_units", issuedAt = "issued_at"
    }

    func toDomain() -> Invoice {
        Invoice(id: id, visitId: visitId, invoiceNumber: invoiceNumber, breakdown: breakdown, gstMinorUnits: gstMinorUnits, issuedAt: issuedAt)
    }
}

private struct SupabaseCartRow: Decodable {
    let id: UUID
    let userId: UUID
    let addressId: UUID?
    let circuitId: UUID?
    let slotId: UUID?
    let couponCode: String?
    let cartItems: [SupabaseCartItemRow]?

    enum CodingKeys: String, CodingKey {
        case id, userId = "user_id", addressId = "address_id", circuitId = "circuit_id"
        case slotId = "slot_id", couponCode = "coupon_code", cartItems = "cart_items"
    }

    func toDomain() -> Cart {
        Cart(id: id, userId: userId, addressId: addressId, circuitId: circuitId, slotId: slotId,
             items: (cartItems ?? []).map { $0.toDomain() }, couponCode: couponCode)
    }
}

private struct SupabaseCartItemRow: Decodable {
    let id: UUID
    let serviceId: UUID
    let variantId: UUID
    let petIds: [UUID]
    let addonIds: [UUID]

    enum CodingKeys: String, CodingKey {
        case id, serviceId = "service_id", variantId = "variant_id", petIds = "pet_ids", addonIds = "addon_ids"
    }

    func toDomain() -> CartItem { CartItem(id: id, serviceId: serviceId, variantId: variantId, petIds: petIds, addonIds: addonIds) }
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

#endif
