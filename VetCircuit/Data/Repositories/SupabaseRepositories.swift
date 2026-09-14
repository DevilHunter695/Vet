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
        // L1/L3: server-side filter (RLS/query, not a client-side badge) so
        // an unverified vet is never reachable in the customer booking flow.
        var query = client.from("circuits").select("*, vet:vets!inner(*), schedule:schedule_slots(*)")
            .eq("vet.verification_status", value: Vet.VerificationStatus.verified.rawValue)
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

    // Pricing (including D5 overrides) runs entirely inside the
    // `create-quote` edge function server-side (Appendix C) — `overrides`
    // is accepted here only to match the protocol; the function reads
    // vet_service_overrides itself from cart_id's circuit.
    func createQuote(for cart: Cart, catalog: [Service], overrides: [VetServiceOverride], useWalletBalance: Bool, applyEntitlementCredit: Bool) async throws -> Quote {
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
        // H6: the edge function re-derives and re-checks entitlement
        // eligibility itself (see the protocol doc comment) — this flag is
        // only "the client thinks a credit applies here," never authority.
        struct Body: Encodable {
            let cartId: String
            let useWalletBalance: Bool
            let applyEntitlementCredit: Bool

            enum CodingKeys: String, CodingKey {
                case cartId = "cart_id"
                case useWalletBalance = "use_wallet_balance"
                case applyEntitlementCredit = "apply_entitlement_credit"
            }
        }

        let body = Body(
            cartId: cart.id.uuidString,
            useWalletBalance: useWalletBalance,
            applyEntitlementCredit: applyEntitlementCredit
        )
        let response: Response = try await client.functions.invoke(
            "create-quote",
            options: .init(body: body)
        )
        return Quote(id: response.id, cartId: response.cartId, breakdown: response.breakdown,
                     signature: response.signature, expiresAt: response.expiresAt)
    }
}

final class SupabaseWalletRepository: WalletRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    struct Row: Decodable {
        let id: UUID
        let userId: UUID
        let amountMinorUnits: Int
        let reason: String
        let relatedVisitId: UUID?
        let relatedRefundId: UUID?
        let createdAt: Date
        enum CodingKeys: String, CodingKey {
            case id, reason
            case userId = "user_id", amountMinorUnits = "amount_minor_units"
            case relatedVisitId = "related_visit_id", relatedRefundId = "related_refund_id"
            case createdAt = "created_at"
        }
        func toDomain() -> WalletLedgerEntry {
            WalletLedgerEntry(id: id, userId: userId, amountMinorUnits: amountMinorUnits, reason: reason,
                               relatedVisitId: relatedVisitId, relatedRefundId: relatedRefundId, createdAt: createdAt)
        }
    }

    // The client has no insert policy on wallet_ledger at all (0026), so
    // this is read-only by construction — the balance is just a fold, not
    // a separate trusted column, matching the ledger's "no stored balance" rule.
    func balanceMinorUnits(userId: UUID) async throws -> Int {
        try await entries(userId: userId).reduce(0) { $0 + $1.amountMinorUnits }
    }

    func entries(userId: UUID) async throws -> [WalletLedgerEntry] {
        let rows: [Row] = try await client.from("wallet_ledger").select()
            .eq("user_id", value: userId).order("created_at", ascending: false).execute().value
        return rows.map { $0.toDomain() }
    }
}

final class SupabaseCouponRepository: CouponRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    struct Row: Decodable {
        let id: UUID
        let code: String
        let discountType: String
        let discountValue: Int
        let maxDiscountMinorUnits: Int?
        let validFrom: Date
        let validUntil: Date
        let usageLimit: Int?
        let perUserLimit: Int?
        let minSpendMinorUnits: Int?
        let campaignName: String?
        enum CodingKeys: String, CodingKey {
            case id, code
            case discountType = "discount_type", discountValue = "discount_value"
            case maxDiscountMinorUnits = "max_discount_minor_units"
            case validFrom = "valid_from", validUntil = "valid_until"
            case usageLimit = "usage_limit", perUserLimit = "per_user_limit"
            case minSpendMinorUnits = "min_spend_minor_units", campaignName = "campaign_name"
        }
        func toDomain() -> Coupon? {
            guard let type = Coupon.DiscountType(rawValue: discountType) else { return nil }
            return Coupon(id: id, code: code, discountType: type, discountValue: discountValue,
                           maxDiscountMinorUnits: maxDiscountMinorUnits, validFrom: validFrom, validUntil: validUntil,
                           usageLimit: usageLimit, perUserLimit: perUserLimit, minSpendMinorUnits: minSpendMinorUnits,
                           campaignName: campaignName)
        }
    }

    /// Goes through the validate_coupon() RPC (0027_coupons.sql), never a
    /// direct table select — a client-readable coupons table would let a
    /// code be enumerated/brute-forced (plan §E4).
    func validate(code: String, userId: UUID, cartTotalMinorUnits: Int) async throws -> Coupon? {
        let rows: [Row] = try await client.rpc("validate_coupon", params: [
            "p_code": code, "p_user_id": userId.uuidString, "p_cart_total": String(cartTotalMinorUnits),
        ]).execute().value
        return rows.first?.toDomain()
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

final class SupabasePetRepository: PetRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func listPets(ownerId: UUID) async throws -> [Pet] {
        let rows: [SupabasePetRow] = try await client
            .from("pets").select().eq("owner_id", value: ownerId).execute().value
        return rows.map { $0.toDomain() }
    }

    func addPet(_ pet: Pet) async throws -> Pet {
        let insert = SupabasePetInsert(pet: pet)
        let rows: [SupabasePetRow] = try await client.from("pets").insert(insert).select().execute().value
        guard let row = rows.first else { throw DomainError.unknown }
        return row.toDomain()
    }

    func updatePet(_ pet: Pet) async throws -> Pet {
        let insert = SupabasePetInsert(pet: pet)
        let rows: [SupabasePetRow] = try await client
            .from("pets").update(insert).eq("id", value: pet.id).select().execute().value
        guard let row = rows.first else { throw DomainError.notFound("Pet") }
        return row.toDomain()
    }

    func deletePet(id: UUID) async throws {
        try await client.from("pets").delete().eq("id", value: id).execute()
    }
}

/// B3: weight/vitals history.
final class SupabasePetWeightRepository: PetWeightRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func history(petId: UUID) async throws -> [PetWeightEntry] {
        let rows: [SupabasePetWeightRow] = try await client
            .from("pet_weights").select().eq("pet_id", value: petId).order("recorded_at").execute().value
        return rows.map { $0.toDomain() }
    }

    func addEntry(_ entry: PetWeightEntry) async throws -> PetWeightEntry {
        let insert = SupabasePetWeightInsert(entry: entry)
        let rows: [SupabasePetWeightRow] = try await client.from("pet_weights").insert(insert).select().execute().value
        guard let row = rows.first else { throw DomainError.unknown }
        return row.toDomain()
    }
}

/// B4 (P0): vaccination history + next-due reminders.
final class SupabaseVaccinationRepository: VaccinationRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func history(petId: UUID) async throws -> [Vaccination] {
        let rows: [SupabaseVaccinationRow] = try await client
            .from("vaccinations").select().eq("pet_id", value: petId).order("next_due_at").execute().value
        return rows.map { $0.toDomain() }
    }

    func record(_ vaccination: Vaccination) async throws -> Vaccination {
        let insert = SupabaseVaccinationInsert(vaccination: vaccination)
        let rows: [SupabaseVaccinationRow] = try await client.from("vaccinations").insert(insert).select().execute().value
        guard let row = rows.first else { throw DomainError.unknown }
        return row.toDomain()
    }
}

/// K2: prescription history — read-only from the client (see 0020's RLS: no
/// insert/update policy, a vet/ops flow writes these).
final class SupabasePrescriptionRepository: PrescriptionRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func history(petId: UUID) async throws -> [Prescription] {
        let rows: [SupabasePrescriptionRow] = try await client
            .from("prescriptions").select().eq("pet_id", value: petId).order("issued_at", ascending: false).execute().value
        return rows.map { $0.toDomain() }
    }
}

final class SupabaseVetOnboardingRepository: VetOnboardingRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func submit(_ application: VetOnboardingApplication) async throws -> VetOnboardingApplication {
        let insert = SupabaseVetOnboardingInsert(application: application)
        let rows: [SupabaseVetOnboardingRow] = try await client
            .from("vet_onboarding_applications").insert(insert).select().execute().value
        guard let row = rows.first else { throw DomainError.unknown }
        return row.toDomain()
    }

    func myApplications(applicantUserId: UUID) async throws -> [VetOnboardingApplication] {
        let rows: [SupabaseVetOnboardingRow] = try await client
            .from("vet_onboarding_applications").select().eq("applicant_user_id", value: applicantUserId)
            .order("submitted_at", ascending: false).execute().value
        return rows.map { $0.toDomain() }
    }

    func update(_ application: VetOnboardingApplication) async throws -> VetOnboardingApplication {
        let update = SupabaseVetOnboardingUpdate(application: application)
        let rows: [SupabaseVetOnboardingRow] = try await client
            .from("vet_onboarding_applications").update(update).eq("id", value: application.id).select().execute().value
        guard let row = rows.first else {
            // RLS silently returns 0 rows for an update the policy refuses
            // (e.g. status has moved past `submitted`) rather than an error.
            throw DomainError.validation("This application is already under review and can no longer be edited.")
        }
        return row.toDomain()
    }
}

final class SupabasePetDocumentRepository: PetDocumentRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func list(petId: UUID) async throws -> [PetDocument] {
        let rows: [SupabasePetDocumentRow] = try await client
            .from("pet_documents").select().eq("pet_id", value: petId).order("uploaded_at", ascending: false).execute().value
        return rows.map { $0.toDomain() }
    }

    func upload(petId: UUID, uploaderId: UUID, title: String, data: Data) async throws -> PetDocument {
        // TODO(Storage SDK): actually upload `data` to the `documents` bucket
        // at this path (`client.storage.from("documents").upload(path, data: data)`)
        // before inserting the row — today only the reference row is real.
        let path = "documents/\(petId)/\(UUID().uuidString).pdf"
        let insert = SupabasePetDocumentInsert(petId: petId, uploaderId: uploaderId, title: title, filePath: path)
        let rows: [SupabasePetDocumentRow] = try await client.from("pet_documents").insert(insert).select().execute().value
        guard let row = rows.first else { throw DomainError.unknown }
        return row.toDomain()
    }

    func delete(id: UUID) async throws {
        try await client.from("pet_documents").delete().eq("id", value: id).execute()
    }
}

final class SupabaseVetBlackoutRepository: VetBlackoutRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func blackouts(vetId: UUID) async throws -> [VetBlackout] {
        let rows: [SupabaseVetBlackoutRow] = try await client
            .from("vet_blackouts").select().eq("vet_id", value: vetId).order("start_date").execute().value
        return rows.map { $0.toDomain() }
    }

    func blackouts(vetIds: [UUID]) async throws -> [VetBlackout] {
        guard !vetIds.isEmpty else { return [] }
        let rows: [SupabaseVetBlackoutRow] = try await client
            .from("vet_blackouts").select().in("vet_id", values: vetIds).execute().value
        return rows.map { $0.toDomain() }
    }

    func create(_ blackout: VetBlackout) async throws -> VetBlackout {
        let insert = SupabaseVetBlackoutInsert(blackout: blackout)
        let rows: [SupabaseVetBlackoutRow] = try await client.from("vet_blackouts").insert(insert).select().execute().value
        guard let row = rows.first else { throw DomainError.unknown }
        return row.toDomain()
    }

    func delete(id: UUID) async throws {
        try await client.from("vet_blackouts").delete().eq("id", value: id).execute()
    }
}

/// K3: medication reminders.
final class SupabaseMedicationReminderRepository: MedicationReminderRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func reminders(petId: UUID) async throws -> [MedicationReminder] {
        let rows: [SupabaseMedicationReminderRow] = try await client
            .from("medication_reminders").select().eq("pet_id", value: petId).order("medication_name").execute().value
        return rows.map { $0.toDomain() }
    }

    func create(_ reminder: MedicationReminder) async throws -> MedicationReminder {
        let insert = SupabaseMedicationReminderInsert(reminder: reminder)
        let rows: [SupabaseMedicationReminderRow] = try await client.from("medication_reminders").insert(insert).select().execute().value
        guard let row = rows.first else { throw DomainError.unknown }
        return row.toDomain()
    }

    func update(_ reminder: MedicationReminder) async throws -> MedicationReminder {
        let insert = SupabaseMedicationReminderInsert(reminder: reminder)
        let rows: [SupabaseMedicationReminderRow] = try await client
            .from("medication_reminders").update(insert).eq("id", value: reminder.id).select().execute().value
        guard let row = rows.first else { throw DomainError.notFound("Medication reminder") }
        return row.toDomain()
    }

    func delete(id: UUID) async throws {
        try await client.from("medication_reminders").delete().eq("id", value: id).execute()
    }
}

final class SupabaseCatalogRepository: CatalogRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func listServices(vertical: Vertical?) async throws -> [Service] {
        var query = client.from("services")
            .select("*, service_variants(*), addons(*), faqs(*)")
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
            .select("*, service_variants(*), addons(*), faqs(*)")
            .eq("id", value: id)
            .execute()
            .value
        guard let row = rows.first else { throw DomainError.notFound("Service") }
        return row.toDomain()
    }
}

/// D4/D7: packages are ops-managed rows, same read pattern as the service
/// catalog — the app never hardcodes a bundle's contents or price.
final class SupabasePackageRepository: PackageRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func listPackages(vertical: Vertical?) async throws -> [Package] {
        var query = client.from("packages")
            .select("*, package_items(*)")
            .eq("is_active", value: true)
        if let vertical {
            query = query.eq("vertical", value: vertical.rawValue)
        }
        let rows: [SupabasePackageRow] = try await query.execute().value
        return rows.map { $0.toDomain() }
    }

    func package(id: UUID) async throws -> Package {
        let rows: [SupabasePackageRow] = try await client
            .from("packages")
            .select("*, package_items(*)")
            .eq("id", value: id)
            .execute()
            .value
        guard let row = rows.first else { throw DomainError.notFound("Package") }
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
        let response: Response = try await client.functions.invoke("request-account-deletion")
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
        let response: DataExport = try await client.functions.invoke("export-account-data")
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
        let response: Response = try await client.functions.invoke("start-call", options: .init(body: ["visit_id": visitId.uuidString]))
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
        struct Body: Encodable {
            let visitId: UUID
            let paymentId: UUID
            let amountMinorUnits: Int
            let reason: String
            enum CodingKeys: String, CodingKey {
                case visitId = "visit_id", paymentId = "payment_id"
                case amountMinorUnits = "amount_minor_units", reason
            }
        }
        let body = Body(visitId: visitId, paymentId: paymentId, amountMinorUnits: amountMinorUnits, reason: reason)
        let row: SupabaseRefundRow = try await client.functions.invoke("issue-refund", options: .init(body: body))
        return row.toDomain()
    }

    func refunds(visitId: UUID) async throws -> [Refund] {
        let rows: [SupabaseRefundRow] = try await client.from("refunds").select().eq("visit_id", value: visitId).execute().value
        return rows.map { $0.toDomain() }
    }
}

final class SupabasePaymentDisputeRepository: PaymentDisputeRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func disputes(visitId: UUID) async throws -> [PaymentDispute] {
        // Plain RLS-direct select — payment_disputes' "select own visit"
        // policy already scopes this to the signed-in customer's own visits
        // (or an admin), so there is no trusted-endpoint indirection needed
        // here the way a write would require.
        let rows: [SupabasePaymentDisputeRow] = try await client.from("payment_disputes")
            .select().eq("visit_id", value: visitId).order("opened_at", ascending: false).execute().value
        return rows.map { $0.toDomain() }
    }
}

final class SupabaseSavedPaymentMethodRepository: SavedPaymentMethodRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func list(userId: UUID) async throws -> [SavedPaymentMethod] {
        let rows: [SupabaseSavedPaymentMethodRow] = try await client.from("saved_payment_methods")
            .select().eq("user_id", value: userId).order("created_at", ascending: false).execute().value
        return rows.map { $0.toDomain() }
    }

    func save(userId: UUID, gatewayTokenId: String, displayLabel: String, makeDefault: Bool) async throws -> SavedPaymentMethod {
        // Only the gateway's token reference and a display label are ever
        // sent here — never a PAN/CVV, which this app's client never holds.
        struct Insert: Encodable {
            let userId: UUID, gatewayTokenId: String, displayLabel: String, isDefault: Bool
            enum CodingKeys: String, CodingKey {
                case userId = "user_id", gatewayTokenId = "gateway_token_id"
                case displayLabel = "display_label", isDefault = "is_default"
            }
        }
        if makeDefault {
            try await client.from("saved_payment_methods").update(["is_default": false])
                .eq("user_id", value: userId).execute()
        }
        let rows: [SupabaseSavedPaymentMethodRow] = try await client.from("saved_payment_methods")
            .insert(Insert(userId: userId, gatewayTokenId: gatewayTokenId, displayLabel: displayLabel, isDefault: makeDefault))
            .select().execute().value
        guard let row = rows.first else { throw DomainError.unknown }
        return row.toDomain()
    }

    func remove(id: UUID) async throws {
        try await client.from("saved_payment_methods").delete().eq("id", value: id).execute()
    }

    func setDefault(id: UUID, userId: UUID) async throws {
        try await client.from("saved_payment_methods").update(["is_default": false])
            .eq("user_id", value: userId).execute()
        try await client.from("saved_payment_methods").update(["is_default": true])
            .eq("id", value: id).eq("user_id", value: userId).execute()
    }
}

final class SupabaseSupportRefundAuditRepository: SupportRefundAuditRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func issueSupportRefund(
        ticketId: UUID, visitId: UUID, issuedByUserId: UUID,
        kind: SupportRefundAudit.Kind, amountMinorUnits: Int, reason: String
    ) async throws -> SupportRefundAudit {
        // Money creation (refund) or wallet credit, plus its audit row, all
        // happen server-side — this never inserts into refunds,
        // wallet_ledger, or support_refund_audit directly (RLS forbids all
        // three for every client role); it only invokes the trusted
        // issue-support-refund Edge Function.
        struct Body: Encodable {
            let ticketId: UUID
            let visitId: UUID
            let kind: String
            let amountMinorUnits: Int
            let reason: String
            enum CodingKeys: String, CodingKey {
                case ticketId = "ticket_id", visitId = "visit_id", kind
                case amountMinorUnits = "amount_minor_units", reason
            }
        }
        let body = Body(ticketId: ticketId, visitId: visitId, kind: kind.rawValue, amountMinorUnits: amountMinorUnits, reason: reason)
        let row: SupabaseSupportRefundAuditRow = try await client.functions.invoke("issue-support-refund", options: .init(body: body))
        return row.toDomain()
    }

    func auditTrail(ticketId: UUID) async throws -> [SupportRefundAudit] {
        let rows: [SupabaseSupportRefundAuditRow] = try await client.from("support_refund_audit")
            .select().eq("ticket_id", value: ticketId).order("created_at", ascending: false).execute().value
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
    // A11: admin/trusted-function-set only (see 0026 migration) — decoded
    // read-only, never sent back on any client update to this row.
    let accountStatus: String?

    enum CodingKeys: String, CodingKey {
        case id, phone, name, email, createdAt = "created_at", pets
        case accountStatus = "account_status"
    }

    func toDomain() -> User {
        User(id: id, phone: phone, name: name, email: email, createdAt: createdAt,
             pets: (pets ?? []).map { $0.toDomain() },
             accountStatus: User.AccountStatus(rawValue: accountStatus ?? "active") ?? .active)
    }
}

private struct SupabasePetRow: Decodable {
    let id: UUID
    let ownerId: UUID
    let name: String
    let species: String
    let breed: String?
    let dob: Date?
    let sex: String?
    let isNeutered: Bool?
    let weightKg: Double?
    let microchipNumber: String?
    let allergies: String?
    let chronicConditions: String?
    let archivedAt: Date?
    let archiveReason: String?

    enum CodingKeys: String, CodingKey {
        case id, name, species, breed, dob, sex, allergies
        case ownerId = "owner_id", isNeutered = "is_neutered", weightKg = "weight_kg"
        case microchipNumber = "microchip_number", chronicConditions = "chronic_conditions"
        case archivedAt = "archived_at", archiveReason = "archive_reason"
    }

    func toDomain() -> Pet {
        Pet(id: id, ownerId: ownerId, name: name, species: Pet.Species(rawValue: species) ?? .other, breed: breed, dateOfBirth: dob,
            sex: sex.flatMap(Pet.Sex.init(rawValue:)), isNeutered: isNeutered, weightKg: weightKg,
            microchipNumber: microchipNumber, allergies: allergies, chronicConditions: chronicConditions,
            archivedAt: archivedAt, archiveReason: archiveReason.flatMap(Pet.ArchiveReason.init(rawValue:)))
    }
}

private struct SupabasePetInsert: Encodable {
    let ownerId: UUID
    let name: String
    let species: String
    let breed: String?
    let dob: Date?
    let sex: String?
    let isNeutered: Bool?
    let weightKg: Double?
    let microchipNumber: String?
    let allergies: String?
    let chronicConditions: String?
    let archivedAt: Date?
    let archiveReason: String?

    enum CodingKeys: String, CodingKey {
        case name, species, breed, dob, sex, allergies
        case ownerId = "owner_id", isNeutered = "is_neutered", weightKg = "weight_kg"
        case microchipNumber = "microchip_number", chronicConditions = "chronic_conditions"
        case archivedAt = "archived_at", archiveReason = "archive_reason"
    }

    init(pet: Pet) {
        ownerId = pet.ownerId
        name = pet.name
        species = pet.species.rawValue
        breed = pet.breed
        dob = pet.dateOfBirth
        sex = pet.sex?.rawValue
        isNeutered = pet.isNeutered
        weightKg = pet.weightKg
        microchipNumber = pet.microchipNumber
        allergies = pet.allergies
        chronicConditions = pet.chronicConditions
        archivedAt = pet.archivedAt
        archiveReason = pet.archiveReason?.rawValue
    }
}

private struct SupabasePetWeightRow: Decodable {
    let id: UUID
    let petId: UUID
    let weightKg: Double
    let recordedAt: Date

    enum CodingKeys: String, CodingKey { case id, petId = "pet_id", weightKg = "weight_kg", recordedAt = "recorded_at" }

    func toDomain() -> PetWeightEntry { PetWeightEntry(id: id, petId: petId, weightKg: weightKg, recordedAt: recordedAt) }
}

private struct SupabasePetWeightInsert: Encodable {
    let petId: UUID
    let weightKg: Double
    let recordedAt: Date

    enum CodingKeys: String, CodingKey { case petId = "pet_id", weightKg = "weight_kg", recordedAt = "recorded_at" }

    init(entry: PetWeightEntry) {
        petId = entry.petId
        weightKg = entry.weightKg
        recordedAt = entry.recordedAt
    }
}

private struct SupabaseVaccinationRow: Decodable {
    let id: UUID
    let petId: UUID
    let vaccineName: String
    let administeredAt: Date?
    let nextDueAt: Date
    let batchNumber: String?
    let visitId: UUID?

    enum CodingKeys: String, CodingKey {
        case id, batchNumber = "batch_number"
        case petId = "pet_id", vaccineName = "vaccine_name", administeredAt = "administered_at"
        case nextDueAt = "next_due_at", visitId = "visit_id"
    }

    func toDomain() -> Vaccination {
        Vaccination(id: id, petId: petId, vaccineName: vaccineName, givenAt: administeredAt,
                    nextDueAt: nextDueAt, batchNumber: batchNumber, visitId: visitId)
    }
}

private struct SupabaseVaccinationInsert: Encodable {
    let petId: UUID
    let vaccineName: String
    let administeredAt: Date?
    let nextDueAt: Date
    let batchNumber: String?
    let visitId: UUID?

    enum CodingKeys: String, CodingKey {
        case batchNumber = "batch_number"
        case petId = "pet_id", vaccineName = "vaccine_name", administeredAt = "administered_at"
        case nextDueAt = "next_due_at", visitId = "visit_id"
    }

    init(vaccination: Vaccination) {
        petId = vaccination.petId
        vaccineName = vaccination.vaccineName
        administeredAt = vaccination.givenAt
        nextDueAt = vaccination.nextDueAt
        batchNumber = vaccination.batchNumber
        visitId = vaccination.visitId
    }
}

private struct SupabasePrescriptionRow: Decodable {
    let id: UUID
    let visitId: UUID
    let petId: UUID
    let prescribedByVetId: UUID
    let medicationName: String
    let dosage: String
    let instructions: String?
    let issuedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, dosage, instructions
        case visitId = "visit_id", petId = "pet_id", prescribedByVetId = "prescribed_by_vet_id"
        case medicationName = "medication_name", issuedAt = "issued_at"
    }

    func toDomain() -> Prescription {
        Prescription(id: id, visitId: visitId, petId: petId, medicationName: medicationName, dosage: dosage,
                     instructions: instructions, prescribedByVetId: prescribedByVetId, issuedAt: issuedAt)
    }
}

/// B6: document vault. `filePath` is a `documents` Storage bucket object
/// path, not a public URL — the app synthesizes a `mock-storage://` URL
/// client-side until Storage SDK wiring lands (see `SupabasePetDocumentRepository`).
private struct SupabaseVetOnboardingRow: Decodable {
    let id: UUID
    let applicantUserId: UUID
    let degreeDocumentUrl: URL
    let vciCertificateUrl: URL
    let idDocumentUrl: URL
    let policeVerificationUrl: URL
    let photoUrl: URL
    let status: String
    let submittedAt: Date
    let reviewedAt: Date?
    let reviewNotes: String?

    enum CodingKeys: String, CodingKey {
        case id, status
        case applicantUserId = "applicant_user_id"
        case degreeDocumentUrl = "degree_document_url"
        case vciCertificateUrl = "vci_certificate_url"
        case idDocumentUrl = "id_document_url"
        case policeVerificationUrl = "police_verification_url"
        case photoUrl = "photo_url"
        case submittedAt = "submitted_at"
        case reviewedAt = "reviewed_at"
        case reviewNotes = "review_notes"
    }

    func toDomain() -> VetOnboardingApplication {
        VetOnboardingApplication(
            id: id, applicantUserId: applicantUserId, degreeDocumentURL: degreeDocumentUrl,
            vciCertificateURL: vciCertificateUrl, idDocumentURL: idDocumentUrl,
            policeVerificationURL: policeVerificationUrl, photoURL: photoUrl,
            status: VetOnboardingApplication.Status(rawValue: status) ?? .submitted,
            submittedAt: submittedAt, reviewedAt: reviewedAt, reviewNotes: reviewNotes
        )
    }
}

private struct SupabaseVetOnboardingInsert: Encodable {
    let id: UUID
    let applicantUserId: UUID
    let degreeDocumentUrl: URL
    let vciCertificateUrl: URL
    let idDocumentUrl: URL
    let policeVerificationUrl: URL
    let photoUrl: URL
    let status: String
    let submittedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, status
        case applicantUserId = "applicant_user_id"
        case degreeDocumentUrl = "degree_document_url"
        case vciCertificateUrl = "vci_certificate_url"
        case idDocumentUrl = "id_document_url"
        case policeVerificationUrl = "police_verification_url"
        case photoUrl = "photo_url"
        case submittedAt = "submitted_at"
    }

    init(application: VetOnboardingApplication) {
        id = application.id
        applicantUserId = application.applicantUserId
        degreeDocumentUrl = application.degreeDocumentURL
        vciCertificateUrl = application.vciCertificateURL
        idDocumentUrl = application.idDocumentURL
        policeVerificationUrl = application.policeVerificationURL
        photoUrl = application.photoURL
        status = application.status.rawValue
        submittedAt = application.submittedAt
    }
}

private struct SupabaseVetOnboardingUpdate: Encodable {
    let degreeDocumentUrl: URL
    let vciCertificateUrl: URL
    let idDocumentUrl: URL
    let policeVerificationUrl: URL
    let photoUrl: URL
    let status: String

    enum CodingKeys: String, CodingKey {
        case status
        case degreeDocumentUrl = "degree_document_url"
        case vciCertificateUrl = "vci_certificate_url"
        case idDocumentUrl = "id_document_url"
        case policeVerificationUrl = "police_verification_url"
        case photoUrl = "photo_url"
    }

    init(application: VetOnboardingApplication) {
        degreeDocumentUrl = application.degreeDocumentURL
        vciCertificateUrl = application.vciCertificateURL
        idDocumentUrl = application.idDocumentURL
        policeVerificationUrl = application.policeVerificationURL
        photoUrl = application.photoURL
        status = application.status.rawValue
    }
}

private struct SupabasePetDocumentRow: Decodable {
    let id: UUID
    let petId: UUID
    let uploaderId: UUID
    let title: String
    let filePath: String
    let uploadedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, title
        case petId = "pet_id", uploaderId = "uploader_id", filePath = "file_path", uploadedAt = "uploaded_at"
    }

    func toDomain() -> PetDocument {
        let url = URL(string: "mock-storage://\(filePath)") ?? URL(string: "mock-storage://documents/unknown")!
        return PetDocument(id: id, petId: petId, uploaderId: uploaderId, title: title, fileURL: url, uploadedAt: uploadedAt)
    }
}

private struct SupabasePetDocumentInsert: Encodable {
    let petId: UUID
    let uploaderId: UUID
    let title: String
    let filePath: String

    enum CodingKeys: String, CodingKey {
        case title
        case petId = "pet_id", uploaderId = "uploader_id", filePath = "file_path"
    }
}

private struct SupabaseVetBlackoutRow: Decodable {
    let id: UUID
    let vetId: UUID
    let startDate: Date
    let endDate: Date
    let reason: String?

    enum CodingKeys: String, CodingKey {
        case id, reason
        case vetId = "vet_id", startDate = "start_date", endDate = "end_date"
    }

    func toDomain() -> VetBlackout {
        VetBlackout(id: id, vetId: vetId, startDate: startDate, endDate: endDate, reason: reason)
    }
}

private struct SupabaseVetBlackoutInsert: Encodable {
    let vetId: UUID
    let startDate: Date
    let endDate: Date
    let reason: String?

    enum CodingKeys: String, CodingKey {
        case reason
        case vetId = "vet_id", startDate = "start_date", endDate = "end_date"
    }

    init(blackout: VetBlackout) {
        vetId = blackout.vetId
        startDate = blackout.startDate
        endDate = blackout.endDate
        reason = blackout.reason
    }
}

private struct SupabaseTimeOfDayDTO: Codable {
    let hour: Int
    let minute: Int

    func toDomain() -> TimeOfDay { TimeOfDay(hour: hour, minute: minute) }
    init(_ timeOfDay: TimeOfDay) { hour = timeOfDay.hour; minute = timeOfDay.minute }
}

private struct SupabaseMedicationReminderRow: Decodable {
    let id: UUID
    let petId: UUID
    let medicationName: String
    let dosage: String
    let times: [SupabaseTimeOfDayDTO]
    let startDate: Date
    let endDate: Date?
    let isActive: Bool

    enum CodingKeys: String, CodingKey {
        case id, times, dosage
        case petId = "pet_id", medicationName = "medication_name"
        case startDate = "start_date", endDate = "end_date", isActive = "is_active"
    }

    func toDomain() -> MedicationReminder {
        MedicationReminder(id: id, petId: petId, medicationName: medicationName, dosage: dosage,
                            times: times.map { $0.toDomain() }, startDate: startDate, endDate: endDate, isActive: isActive)
    }
}

private struct SupabaseMedicationReminderInsert: Encodable {
    let petId: UUID
    let medicationName: String
    let dosage: String
    let times: [SupabaseTimeOfDayDTO]
    let startDate: Date
    let endDate: Date?
    let isActive: Bool

    enum CodingKeys: String, CodingKey {
        case times, dosage
        case petId = "pet_id", medicationName = "medication_name"
        case startDate = "start_date", endDate = "end_date", isActive = "is_active"
    }

    init(reminder: MedicationReminder) {
        petId = reminder.petId
        medicationName = reminder.medicationName
        dosage = reminder.dosage
        times = reminder.times.map { SupabaseTimeOfDayDTO($0) }
        startDate = reminder.startDate
        endDate = reminder.endDate
        isActive = reminder.isActive
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

private struct SupabaseSubscriptionRow: Decodable {
    let id: UUID
    let userId: UUID
    let planType: String
    let status: String
    let renewalDate: Date
    let seatCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, status
        case userId = "user_id", planType = "plan_type", renewalDate = "renewal_date", seatCount = "seat_count"
    }

    func toDomain() -> Subscription {
        Subscription(id: id, userId: userId, planType: Subscription.PlanType(rawValue: planType) ?? .monthly,
                      status: Subscription.Status(rawValue: status) ?? .active, renewalDate: renewalDate,
                      seatCount: seatCount ?? 1)
    }
}

private struct SupabaseDunningRow: Decodable {
    let id: UUID
    let failedAttempts: Int
    let nextRetryAt: Date?
    let gracePeriodEndsAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, failedAttempts = "failed_attempts", nextRetryAt = "next_retry_at", gracePeriodEndsAt = "grace_period_ends_at"
    }

    func toDomain() -> DunningState {
        DunningState(subscriptionId: id, failedAttempts: failedAttempts, nextRetryAt: nextRetryAt, gracePeriodEndsAt: gracePeriodEndsAt)
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

private struct SupabasePaymentDisputeRow: Decodable {
    let id: UUID
    let paymentId: UUID
    let visitId: UUID
    let gatewayDisputeId: String
    let reason: String
    let amountMinorUnits: Int
    let status: String
    let openedAt: Date
    let resolvedAt: Date?
    let evidenceSubmittedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, reason, status
        case paymentId = "payment_id", visitId = "visit_id", gatewayDisputeId = "gateway_dispute_id"
        case amountMinorUnits = "amount_minor_units", openedAt = "opened_at"
        case resolvedAt = "resolved_at", evidenceSubmittedAt = "evidence_submitted_at"
    }

    func toDomain() -> PaymentDispute {
        PaymentDispute(id: id, paymentId: paymentId, visitId: visitId, gatewayDisputeId: gatewayDisputeId,
                        reason: reason, amountMinorUnits: amountMinorUnits,
                        status: PaymentDispute.Status(rawValue: status) ?? .open,
                        openedAt: openedAt, resolvedAt: resolvedAt, evidenceSubmittedAt: evidenceSubmittedAt)
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
    let faqs: [SupabaseFAQRow]?

    enum CodingKeys: String, CodingKey {
        case id, category, name, summary
        case whatToPrepare = "what_to_prepare", eligibleSpecies = "eligible_species"
        case requiresPrescriberVet = "requires_prescriber_vet", minPetAgeMonths = "min_pet_age_months"
        case serviceVariants = "service_variants", addons, faqs
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
            ),
            faqs: (faqs ?? []).map { $0.toDomain() }
        )
    }
}

private struct SupabaseFAQRow: Decodable {
    let id: UUID
    let question: String
    let answer: String

    func toDomain() -> FAQ { FAQ(id: id, question: question, answer: answer) }
}

private struct SupabasePackageRow: Decodable {
    let id: UUID
    let name: String
    let description: String
    let priceMinorUnits: Int
    let vertical: String
    let packageItems: [SupabasePackageItemRow]?

    enum CodingKeys: String, CodingKey {
        case id, name, description, priceMinorUnits = "price_minor_units", vertical
        case packageItems = "package_items"
    }

    func toDomain() -> Package {
        Package(id: id, name: name, packageDescription: description,
                items: (packageItems ?? []).map { $0.toDomain() },
                priceMinorUnits: priceMinorUnits, vertical: Vertical(rawValue: vertical) ?? .vet)
    }
}

private struct SupabasePackageItemRow: Decodable {
    let id: UUID
    let serviceId: UUID
    let quantity: Int

    enum CodingKeys: String, CodingKey { case id, serviceId = "service_id", quantity }

    func toDomain() -> PackageItem { PackageItem(id: id, serviceId: serviceId, quantity: quantity) }
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
    let bio: String?
    let yearsOfExperience: Int?
    let languages: [String]?
    let gender: String?
    let speciesHandled: [String]?

    enum CodingKeys: String, CodingKey {
        case id, name, licenseNumber = "license_number", verificationStatus = "verification_status"
        case rating, reviewCount = "review_count", bio, languages, gender
        case yearsOfExperience = "years_of_experience", speciesHandled = "species_handled"
    }

    func toDomain() -> Vet {
        Vet(id: id, name: name, licenseNumber: licenseNumber,
            verificationStatus: Vet.VerificationStatus(rawValue: verificationStatus) ?? .pending,
            rating: rating, reviewCount: reviewCount, photoURL: nil,
            bio: bio, yearsOfExperience: yearsOfExperience, languages: languages ?? [],
            gender: gender.flatMap(Vet.Gender.init(rawValue:)),
            speciesHandled: (speciesHandled ?? []).compactMap(Pet.Species.init(rawValue:)))
    }
}

/// C11: public-read emergency clinic directory.
final class SupabaseEmergencyClinicRepository: EmergencyClinicRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func listClinics() async throws -> [EmergencyClinic] {
        struct Row: Decodable {
            let id: UUID, name: String, address: String, phone: String
            let latitude: Double, longitude: Double, isOpen24x7: Bool
            enum CodingKeys: String, CodingKey {
                case id, name, address, phone, latitude, longitude
                case isOpen24x7 = "is_open_24x7"
            }
        }
        let rows: [Row] = try await client.from("emergency_clinics").select().execute().value
        return rows.map {
            EmergencyClinic(id: $0.id, name: $0.name, address: $0.address, phone: $0.phone,
                             latitude: $0.latitude, longitude: $0.longitude, isOpen24x7: $0.isOpen24x7)
        }
    }
}

/// C5: reviews for a vet's profile. Submission remains a stub here — the
/// review-submit flow's Supabase wiring predates this file and is a known
/// pre-existing gap, not something introduced by C5.
final class SupabaseReviewRepository: ReviewRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    private struct ReviewRow: Decodable {
        let id: UUID, visitId: UUID, vetId: UUID, userId: UUID, rating: Int, comment: String?, createdAt: Date
        let needsModeration: Bool?, moderationFlags: [String]?
        enum CodingKeys: String, CodingKey {
            case id, rating, comment
            case visitId = "visit_id", vetId = "vet_id", userId = "user_id", createdAt = "created_at"
            case needsModeration = "needs_moderation", moderationFlags = "moderation_flags"
        }
        func toDomain() -> Review {
            Review(id: id, visitId: visitId, vetId: vetId, userId: userId, rating: rating, comment: comment,
                   createdAt: createdAt, needsModeration: needsModeration ?? false, moderationFlags: moderationFlags ?? [])
        }
    }

    func submit(visitId: UUID, rating: Int, comment: String?, needsModeration: Bool, moderationFlags: [String]) async throws -> Review {
        struct Insert: Encodable {
            let visitId: UUID, rating: Int, comment: String?, needsModeration: Bool, moderationFlags: [String]
            enum CodingKeys: String, CodingKey {
                case visitId = "visit_id", rating, comment
                case needsModeration = "needs_moderation", moderationFlags = "moderation_flags"
            }
        }
        let rows: [ReviewRow] = try await client.from("reviews")
            .insert(Insert(visitId: visitId, rating: rating, comment: comment,
                           needsModeration: needsModeration, moderationFlags: moderationFlags))
            .select().execute().value
        guard let row = rows.first else { throw DomainError.unknown }
        return row.toDomain()
    }

    func reviews(vetId: UUID) async throws -> [Review] {
        let rows: [ReviewRow] = try await client.from("reviews").select().eq("vet_id", value: vetId)
            .order("created_at", ascending: false).execute().value
        return rows.map { $0.toDomain() }
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

final class SupabaseSubscriptionRepository: SubscriptionRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func currentSubscription(userId: UUID) async throws -> Subscription? {
        let rows: [SupabaseSubscriptionRow] = try await client.from("subscriptions")
            .select().eq("user_id", value: userId).order("created_at", ascending: false).limit(1).execute().value
        return rows.first?.toDomain()
    }

    func subscribe(userId: UUID, plan: Subscription.PlanType) async throws -> Subscription {
        struct Insert: Encodable {
            let userId: UUID, planType: String, renewalDate: String
            enum CodingKeys: String, CodingKey { case userId = "user_id", planType = "plan_type", renewalDate = "renewal_date" }
        }
        let renewal = Calendar.current.date(byAdding: .month, value: 1, to: .now) ?? .now
        let rows: [SupabaseSubscriptionRow] = try await client.from("subscriptions")
            .insert(Insert(userId: userId, planType: plan.rawValue, renewalDate: ISO8601DateFormatter().string(from: renewal)))
            .select().execute().value
        guard let row = rows.first else { throw DomainError.unknown }
        return row.toDomain()
    }

    func cancel(subscriptionId: UUID) async throws {
        try await client.from("subscriptions").update(["status": Subscription.Status.cancelled.rawValue])
            .eq("id", value: subscriptionId).execute()
    }

    // Manage (H3): the "subscriptions all own" RLS policy (0001_init.sql)
    // already lets the owner update their own row, so these are plain
    // updates — the validation that matters (upgrade/downgrade legality,
    // corporate seat floor) already ran in ManageSubscriptionUseCase.
    func changePlan(subscriptionId: UUID, to plan: Subscription.PlanType) async throws -> Subscription {
        let rows: [SupabaseSubscriptionRow] = try await client.from("subscriptions")
            .update(["plan_type": plan.rawValue]).eq("id", value: subscriptionId).select().execute().value
        guard let row = rows.first else { throw DomainError.notFound("Subscription") }
        return row.toDomain()
    }

    func pause(subscriptionId: UUID) async throws -> Subscription {
        let rows: [SupabaseSubscriptionRow] = try await client.from("subscriptions")
            .update(["status": Subscription.Status.paused.rawValue]).eq("id", value: subscriptionId).select().execute().value
        guard let row = rows.first else { throw DomainError.notFound("Subscription") }
        return row.toDomain()
    }

    func resume(subscriptionId: UUID) async throws -> Subscription {
        let rows: [SupabaseSubscriptionRow] = try await client.from("subscriptions")
            .update(["status": Subscription.Status.active.rawValue]).eq("id", value: subscriptionId).select().execute().value
        guard let row = rows.first else { throw DomainError.notFound("Subscription") }
        return row.toDomain()
    }

    // Dunning (H5): failed_attempts/next_retry_at/grace_period_ends_at live on
    // the subscriptions row itself (migration 0015) rather than a separate
    // table — there is exactly one live dunning cycle per subscription at a
    // time, unlike visit_events' append-only history of many transitions.
    func dunningState(subscriptionId: UUID) async throws -> DunningState? {
        let rows: [SupabaseDunningRow] = try await client.from("subscriptions")
            .select("id, failed_attempts, next_retry_at, grace_period_ends_at").eq("id", value: subscriptionId).execute().value
        guard let row = rows.first, row.failedAttempts > 0 else { return nil }
        return row.toDomain()
    }

    func recordDunningState(_ state: DunningState) async throws {
        struct Update: Encodable {
            let failedAttempts: Int
            let nextRetryAt: String?
            let gracePeriodEndsAt: String?
            enum CodingKeys: String, CodingKey {
                case failedAttempts = "failed_attempts", nextRetryAt = "next_retry_at", gracePeriodEndsAt = "grace_period_ends_at"
            }
        }
        let update = Update(
            failedAttempts: state.failedAttempts,
            nextRetryAt: state.nextRetryAt.map { ISO8601DateFormatter().string(from: $0) },
            gracePeriodEndsAt: state.gracePeriodEndsAt.map { ISO8601DateFormatter().string(from: $0) }
        )
        try await client.from("subscriptions").update(update).eq("id", value: state.subscriptionId).execute()
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
    /// K1: structured visit record (0046_visit_record_structured.sql).
    let diagnosisNotes: String?
    let proceduresPerformed: [String]?
    let medicationsGiven: [String]?

    enum CodingKeys: String, CodingKey {
        case id, userId = "user_id", petId = "pet_id", vetId = "vet_id", circuitId = "circuit_id"
        case status, scheduledAt = "scheduled_at", completedAt = "completed_at", notes, paymentId = "payment_id"
        case diagnosisNotes = "diagnosis_notes", proceduresPerformed = "procedures_performed", medicationsGiven = "medications_given"
    }

    func toDomain() -> Visit {
        Visit(id: id, userId: userId, petId: petId, vetId: vetId, circuitId: circuitId,
              status: Visit.VisitStatus(rawValue: status) ?? .requested,
              scheduledAt: scheduledAt, completedAt: completedAt, notes: notes, paymentId: paymentId,
              diagnosisNotes: diagnosisNotes, proceduresPerformed: proceduresPerformed ?? [], medicationsGiven: medicationsGiven ?? [])
    }
}

final class SupabaseNotificationPreferencesRepository: NotificationPreferencesRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func preferences(userId: UUID) async throws -> NotificationPreferences {
        let rows: [SupabaseNotificationPreferencesRow] = try await client
            .from("notification_preferences").select().eq("user_id", value: userId)
            .execute().value
        // No saved row yet = the all-on-except-promotions default, not an error.
        return rows.first?.toDomain() ?? NotificationPreferences(userId: userId)
    }

    func save(_ preferences: NotificationPreferences) async throws -> NotificationPreferences {
        let upsert = SupabaseNotificationPreferencesRow(preferences: preferences)
        let rows: [SupabaseNotificationPreferencesRow] = try await client
            .from("notification_preferences").upsert(upsert, onConflict: "user_id").select().execute().value
        guard let row = rows.first else { throw DomainError.unknown }
        return row.toDomain()
    }
}

// C8: server-side FTS override, per plan §3 C8's "Postgres FTS is enough" —
// `.textSearch` against the generated `search_vector` column added in
// 0022_search_fts.sql, using the SDK's `TextSearchType` the same way `.eq`/
// `.in` are used elsewhere in this file for other filtered queries.
extension SupabaseCircuitRepository {
    func searchCircuits(term: String, area: String?) async throws -> [Circuit] {
        let needle = term.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return try await listCircuits(area: area) }
        // Vet name isn't a column on `circuits` itself, so this searches the
        // joined vet's tsvector via `vet.search_vector` — falls back to a
        // client-side area/vet-name filter if the embedded-resource text
        // search syntax isn't supported by the SDK version in use.
        var query = client.from("circuits").select("*, vet:vets!inner(*), schedule:schedule_slots(*)")
        if let area { query = query.eq("cluster_area", value: area) }
        do {
            let rows: [SupabaseCircuitRow] = try await query
                .or("cluster_area.ilike.%\(needle)%,vets.search_vector.fts.\(needle)")
                .execute().value
            return rows.map { $0.toDomain() }
        } catch {
            // Same client-side fallback the default protocol extension uses —
            // keeps search available even if the embedded `.or` filter above
            // isn't accepted by a given PostgREST/SDK version.
            let circuits = try await listCircuits(area: area)
            return try await self.searchCircuitsFallback(circuits, term: needle)
        }
    }

    private func searchCircuitsFallback(_ circuits: [Circuit], term: String) async throws -> [Circuit] {
        let lower = term.lowercased()
        return circuits.filter {
            $0.clusterArea.lowercased().contains(lower) || ($0.vet?.name.lowercased().contains(lower) ?? false)
        }
    }
}

extension SupabaseCatalogRepository {
    func searchServices(term: String, vertical: Vertical?) async throws -> [Service] {
        let needle = term.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return try await listServices(vertical: vertical) }
        var query = client.from("services")
            .select("*, service_variants(*), addons(*)")
            .eq("is_active", value: true)
        if let vertical {
            let categories = ServiceCategory.allCases.filter { $0.vertical == vertical }.map(\.rawValue)
            query = query.in("category", values: categories)
        }
        let rows: [SupabaseServiceRow] = try await query
            .textSearch("search_vector", query: needle, config: "english")
            .execute().value
        return rows.map { $0.toDomain() }
    }
}

final class SupabaseAppConfigRepository: AppConfigRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    /// O7/O8: single public-read singleton row (see migration) — no auth
    /// header required, so this must work before sign-in too.
    func fetchConfig() async throws -> RemoteAppConfig {
        let rows: [SupabaseAppConfigRow] = try await client
            .from("app_config").select().eq("id", value: 1)
            .execute().value
        guard let row = rows.first else { throw DomainError.notFound("App config") }
        return row.toDomain()
    }
}

private struct SupabaseNotificationPreferencesRow: Codable {
    let userId: UUID
    let bookingUpdates: Bool
    let chatMessages: Bool
    let vaccinationReminders: Bool
    let promotions: Bool

    enum CodingKeys: String, CodingKey {
        case userId = "user_id", bookingUpdates = "booking_updates", chatMessages = "chat_messages"
        case vaccinationReminders = "vaccination_reminders", promotions
    }

    init(preferences: NotificationPreferences) {
        userId = preferences.userId
        bookingUpdates = preferences.bookingUpdates
        chatMessages = preferences.chatMessages
        vaccinationReminders = preferences.vaccinationReminders
        promotions = preferences.promotions
    }

    func toDomain() -> NotificationPreferences {
        NotificationPreferences(userId: userId, bookingUpdates: bookingUpdates, chatMessages: chatMessages,
                                 vaccinationReminders: vaccinationReminders, promotions: promotions)
    }
}

// MARK: - A9 household

final class SupabaseHouseholdRepository: HouseholdRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func myHousehold(userId: UUID) async throws -> Household? {
        let memberRows: [SupabaseHouseholdMemberRow] = try await client
            .from("household_members").select().eq("user_id", value: userId)
            .execute().value
        guard let membership = memberRows.first else { return nil }
        let rows: [SupabaseHouseholdRow] = try await client
            .from("households").select().eq("id", value: membership.householdId)
            .execute().value
        return rows.first?.toDomain()
    }

    func createHousehold(name: String, ownerId: UUID) async throws -> Household {
        struct Insert: Encodable {
            let name: String
            let ownerId: UUID
            enum CodingKeys: String, CodingKey { case name, ownerId = "owner_id" }
        }
        let rows: [SupabaseHouseholdRow] = try await client
            .from("households").insert(Insert(name: name, ownerId: ownerId)).select()
            .execute().value
        guard let row = rows.first else { throw DomainError.unknown }
        // The owner is a member of their own household too, so `myHousehold`
        // and `members` see them the same way any invited member would be.
        struct MemberInsert: Encodable {
            let householdId: UUID
            let userId: UUID
            let role: String
            enum CodingKeys: String, CodingKey { case householdId = "household_id", userId = "user_id", role }
        }
        try await client.from("household_members")
            .insert(MemberInsert(householdId: row.id, userId: ownerId, role: "owner"))
            .execute()
        return row.toDomain()
    }

    func members(householdId: UUID) async throws -> [HouseholdMember] {
        let rows: [SupabaseHouseholdMemberRow] = try await client
            .from("household_members").select().eq("household_id", value: householdId)
            .execute().value
        return rows.map { $0.toDomain() }
    }

    func invite(householdId: UUID, phone: String) async throws -> HouseholdMember {
        // The invitee's `user_id` isn't known yet — this inserts a
        // placeholder member row keyed by phone, matched to a real user_id
        // by a server-side trigger/Edge Function once that phone signs up
        // (mirrors the referral flow's pending-until-joined shape).
        struct Insert: Encodable {
            let householdId: UUID
            let invitedPhone: String
            let role: String
            enum CodingKeys: String, CodingKey { case householdId = "household_id", invitedPhone = "invited_phone", role }
        }
        let rows: [SupabaseHouseholdMemberRow] = try await client
            .from("household_members")
            .insert(Insert(householdId: householdId, invitedPhone: phone, role: "member")).select()
            .execute().value
        guard let row = rows.first else { throw DomainError.unknown }
        return row.toDomain()
    }

    func removeMember(householdId: UUID, memberId: UUID) async throws {
        try await client.from("household_members").delete().eq("id", value: memberId).execute()
    }
}

private struct SupabaseHouseholdRow: Decodable {
    let id: UUID
    let name: String
    let ownerId: UUID
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, ownerId = "owner_id", createdAt = "created_at"
    }

    func toDomain() -> Household {
        Household(id: id, name: name, ownerId: ownerId, createdAt: createdAt)
    }
}

private struct SupabaseHouseholdMemberRow: Decodable {
    let id: UUID
    let householdId: UUID
    let userId: UUID
    let role: String
    let invitedPhone: String?
    let joinedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, role
        case householdId = "household_id", userId = "user_id", invitedPhone = "invited_phone", joinedAt = "joined_at"
    }

    func toDomain() -> HouseholdMember {
        HouseholdMember(id: id, householdId: householdId, userId: userId,
                         role: HouseholdMember.Role(rawValue: role) ?? .member,
                         invitedPhone: invitedPhone, joinedAt: joinedAt)
    }
}

// MARK: - C10 waitlist

final class SupabaseWaitlistRepository: WaitlistRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func join(userId: UUID, addressId: UUID?, latitude: Double, longitude: Double, areaLabel: String?) async throws -> WaitlistEntry {
        struct Insert: Encodable {
            let userId: UUID
            let addressId: UUID?
            let latitude: Double
            let longitude: Double
            let areaLabel: String?
            enum CodingKeys: String, CodingKey {
                case userId = "user_id", addressId = "address_id", latitude, longitude, areaLabel = "area_label"
            }
        }
        // Upsert on the (user_id, address_id) unique constraint (0021_waitlist.sql)
        // so a repeat tap is a no-op, matching the mock's dedup behavior.
        let rows: [SupabaseWaitlistRow] = try await client
            .from("waitlist_entries")
            .upsert(Insert(userId: userId, addressId: addressId, latitude: latitude, longitude: longitude, areaLabel: areaLabel),
                    onConflict: "user_id,address_id")
            .select()
            .execute().value
        guard let row = rows.first else { throw DomainError.unknown }
        return row.toDomain()
    }

    func countNear(latitude: Double, longitude: Double, radiusKm: Double) async throws -> Int {
        let count: Int = try await client.rpc("waitlist_count_near", params: [
            "p_lat": latitude, "p_lng": longitude, "radius_km": radiusKm,
        ]).execute().value
        return count
    }

    func hasJoined(userId: UUID, addressId: UUID?) async throws -> Bool {
        var query = client.from("waitlist_entries").select("id").eq("user_id", value: userId)
        query = addressId.map { query.eq("address_id", value: $0) } ?? query.is("address_id", value: nil)
        let rows: [SupabaseWaitlistRow] = try await query.execute().value
        return !rows.isEmpty
    }
}

private struct SupabaseWaitlistRow: Decodable {
    let id: UUID
    let userId: UUID
    let addressId: UUID?
    let latitude: Double
    let longitude: Double
    let areaLabel: String?
    let joinedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, latitude, longitude
        case userId = "user_id", addressId = "address_id", areaLabel = "area_label", joinedAt = "joined_at"
    }

    func toDomain() -> WaitlistEntry {
        WaitlistEntry(id: id, userId: userId, addressId: addressId, latitude: latitude, longitude: longitude, areaLabel: areaLabel, joinedAt: joinedAt)
    }
}

private struct SupabaseAppConfigRow: Decodable {
    let minSupportedVersion: String
    let isMaintenanceMode: Bool
    let maintenanceMessage: String?

    enum CodingKeys: String, CodingKey {
        case minSupportedVersion = "min_supported_version", isMaintenanceMode = "is_maintenance_mode"
        case maintenanceMessage = "maintenance_message"
    }

    func toDomain() -> RemoteAppConfig {
        RemoteAppConfig(minSupportedVersion: minSupportedVersion, isMaintenanceMode: isMaintenanceMode, maintenanceMessage: maintenanceMessage)
    }
}

// MARK: - Help centre, support tickets & notification centre (plan §M, §J7)

final class SupabaseHelpRepository: HelpRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func listArticles() async throws -> [HelpArticle] {
        // Public-read (M1: "remote content, not app-updated") — anyone can
        // browse FAQs before signing in, mirroring the catalog tables.
        let rows: [SupabaseHelpArticleRow] = try await client.from("help_articles").select().execute().value
        return rows.map { $0.toDomain() }
    }
}

final class SupabaseSupportRepository: SupportRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func createTicket(userId: UUID, visitId: UUID?, subject: String, body: String) async throws -> SupportTicket {
        struct Insert: Encodable {
            let userId: UUID, visitId: UUID?, subject: String, body: String
            enum CodingKeys: String, CodingKey { case userId = "user_id", visitId = "visit_id", subject, body }
        }
        let rows: [SupabaseSupportTicketRow] = try await client.from("support_tickets")
            .insert(Insert(userId: userId, visitId: visitId, subject: subject, body: body)).select().execute().value
        guard let row = rows.first else { throw DomainError.unknown }
        return row.toDomain()
    }

    func myTickets(userId: UUID) async throws -> [SupportTicket] {
        let rows: [SupabaseSupportTicketRow] = try await client.from("support_tickets")
            .select().eq("user_id", value: userId).order("created_at", ascending: false).execute().value
        return rows.map { $0.toDomain() }
    }
}

final class SupabaseAppNotificationRepository: AppNotificationRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func notifications(userId: UUID) async throws -> [AppNotification] {
        let rows: [SupabaseAppNotificationRow] = try await client.from("notifications")
            .select().eq("user_id", value: userId).order("created_at", ascending: false).execute().value
        return rows.map { $0.toDomain() }
    }

    func markRead(id: UUID) async throws {
        try await client.from("notifications").update(["read_at": ISO8601DateFormatter().string(from: Date())])
            .eq("id", value: id).execute()
    }
}

private struct SupabaseHelpArticleRow: Decodable {
    let id: UUID
    let category: String
    let question: String
    let answer: String

    func toDomain() -> HelpArticle {
        HelpArticle(id: id, category: HelpArticle.Category(rawValue: category) ?? .account, question: question, answer: answer)
    }
}

private struct SupabaseSupportTicketRow: Decodable {
    let id: UUID
    let userId: UUID
    let visitId: UUID?
    let subject: String
    let body: String
    let status: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, subject, body, status
        case userId = "user_id", visitId = "visit_id", createdAt = "created_at"
    }

    func toDomain() -> SupportTicket {
        SupportTicket(id: id, userId: userId, visitId: visitId, subject: subject, body: body,
                       status: SupportTicket.Status(rawValue: status) ?? .open, createdAt: createdAt)
    }
}

private struct SupabaseAppNotificationRow: Decodable {
    let id: UUID
    let userId: UUID
    let category: String
    let title: String
    let body: String
    let sentAt: Date?
    let createdAt: Date
    let readAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, category, title, body
        case userId = "user_id", sentAt = "sent_at", createdAt = "created_at", readAt = "read_at"
    }

    func toDomain() -> AppNotification {
        AppNotification(id: id, userId: userId, category: AppNotification.Category(rawValue: category) ?? .promotion,
                         title: title, body: body, sentAt: sentAt, createdAt: createdAt, readAt: readAt)
    }
}

final class SupabaseSubscriptionEntitlementRepository: SubscriptionEntitlementRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func currentEntitlement(subscriptionId: UUID) async throws -> SubscriptionEntitlement? {
        let rows: [SupabaseEntitlementRow] = try await client.from("subscription_entitlements")
            .select().eq("subscription_id", value: subscriptionId).execute().value
        return rows.first?.toDomain()
    }

    /// Server-side function (0028_subscription_entitlements.sql) does the
    /// rollover + decrement atomically so two concurrent bookings can't both
    /// read "1 credit left" and both spend it.
    func consumeCredit(subscriptionId: UUID) async throws -> SubscriptionEntitlement {
        struct Params: Encodable { let p_subscription_id: UUID }
        let row: SupabaseEntitlementRow = try await client
            .rpc("consume_subscription_credit", params: Params(p_subscription_id: subscriptionId))
            .execute().value
        return row.toDomain()
    }
}

private struct SupabaseEntitlementRow: Decodable {
    let id: UUID
    let subscriptionId: UUID
    let creditsRemaining: Int
    let resetAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case subscriptionId = "subscription_id", creditsRemaining = "credits_remaining", resetAt = "reset_at"
    }

    func toDomain() -> SubscriptionEntitlement {
        SubscriptionEntitlement(id: id, subscriptionId: subscriptionId, creditsRemaining: creditsRemaining, resetAt: resetAt)
    }
}

final class SupabaseIncidentReportRepository: IncidentReportRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func fileReport(_ report: IncidentReport) async throws -> IncidentReport {
        struct Insert: Encodable {
            let id: UUID, visitId: UUID, reporterId: UUID, reporterRole: String, type: String, description: String
            enum CodingKeys: String, CodingKey {
                case id, description, type
                case visitId = "visit_id", reporterId = "reporter_id", reporterRole = "reporter_role"
            }
        }
        let insert = Insert(id: report.id, visitId: report.visitId, reporterId: report.reporterId,
                             reporterRole: report.reporterRole.rawValue, type: report.type.rawValue, description: report.description)
        let rows: [SupabaseIncidentReportRow] = try await client.from("incident_reports")
            .insert(insert).select().execute().value
        guard let row = rows.first else { throw DomainError.unknown }
        return row.toDomain()
    }

    func myReports(reporterId: UUID) async throws -> [IncidentReport] {
        let rows: [SupabaseIncidentReportRow] = try await client.from("incident_reports")
            .select().eq("reporter_id", value: reporterId).order("created_at", ascending: false).execute().value
        return rows.map { $0.toDomain() }
    }
}

private struct SupabaseIncidentReportRow: Decodable {
    let id: UUID
    let visitId: UUID
    let reporterId: UUID
    let reporterRole: String
    let type: String
    let description: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, description
        case visitId = "visit_id", reporterId = "reporter_id", reporterRole = "reporter_role"
        case type, createdAt = "created_at"
    }

    func toDomain() -> IncidentReport {
        IncidentReport(id: id, visitId: visitId, reporterId: reporterId,
                        reporterRole: IncidentReport.ReporterRole(rawValue: reporterRole) ?? .customer,
                        type: IncidentReport.IncidentType(rawValue: type) ?? .other,
                        description: description, createdAt: createdAt)
    }
}

final class SupabaseVetServiceOverrideRepository: VetServiceOverrideRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func overrides(vetId: UUID) async throws -> [VetServiceOverride] {
        let rows: [SupabaseVetServiceOverrideRow] = try await client
            .from("vet_service_overrides").select().eq("vet_id", value: vetId).execute().value
        return rows.map { $0.toDomain() }
    }

    func setOverride(_ override: VetServiceOverride) async throws -> VetServiceOverride {
        let insert = SupabaseVetServiceOverrideInsert(override: override)
        // Upsert on (vet_id, service_id, variant_id) — matches the migration's unique constraint.
        let rows: [SupabaseVetServiceOverrideRow] = try await client
            .from("vet_service_overrides").upsert(insert, onConflict: "vet_id,service_id,variant_id").select().execute().value
        guard let row = rows.first else { throw DomainError.unknown }
        return row.toDomain()
    }
}

private struct SupabaseVetServiceOverrideRow: Decodable {
    let id: UUID
    let vetId: UUID
    let serviceId: UUID
    let variantId: UUID?
    let priceOverrideMinorUnits: Int?
    let isOffered: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case vetId = "vet_id", serviceId = "service_id", variantId = "variant_id"
        case priceOverrideMinorUnits = "price_override_minor_units", isOffered = "is_offered"
    }

    func toDomain() -> VetServiceOverride {
        VetServiceOverride(id: id, vetId: vetId, serviceId: serviceId, variantId: variantId,
                            priceOverrideMinorUnits: priceOverrideMinorUnits, isOffered: isOffered)
    }
}

private struct SupabaseVetServiceOverrideInsert: Encodable {
    let id: UUID
    let vetId: UUID
    let serviceId: UUID
    let variantId: UUID?
    let priceOverrideMinorUnits: Int?
    let isOffered: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case vetId = "vet_id", serviceId = "service_id", variantId = "variant_id"
        case priceOverrideMinorUnits = "price_override_minor_units", isOffered = "is_offered"
    }

    init(override: VetServiceOverride) {
        id = override.id; vetId = override.vetId; serviceId = override.serviceId
        variantId = override.variantId; priceOverrideMinorUnits = override.priceOverrideMinorUnits
        isOffered = override.isOffered
    }
}

// MARK: - F5 recurring booking rules

final class SupabaseRecurringBookingRuleRepository: RecurringBookingRuleRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func rules(userId: UUID) async throws -> [RecurringBookingRule] {
        let rows: [SupabaseRecurringBookingRuleRow] = try await client
            .from("recurring_booking_rules").select().eq("user_id", value: userId)
            .order("next_occurrence_at", ascending: true).execute().value
        return rows.map { $0.toDomain() }
    }

    func create(_ rule: RecurringBookingRule) async throws -> RecurringBookingRule {
        let insert = SupabaseRecurringBookingRuleInsert(rule: rule)
        let rows: [SupabaseRecurringBookingRuleRow] = try await client
            .from("recurring_booking_rules").insert(insert).select().execute().value
        guard let row = rows.first else { throw DomainError.unknown }
        return row.toDomain()
    }

    func setActive(id: UUID, isActive: Bool) async throws -> RecurringBookingRule {
        let rows: [SupabaseRecurringBookingRuleRow] = try await client
            .from("recurring_booking_rules").update(["is_active": isActive]).eq("id", value: id).select().execute().value
        guard let row = rows.first else { throw DomainError.notFound("Recurring booking rule") }
        return row.toDomain()
    }

    func delete(id: UUID) async throws {
        try await client.from("recurring_booking_rules").delete().eq("id", value: id).execute()
    }
}

private struct SupabaseRecurringBookingRuleRow: Decodable {
    let id: UUID
    let userId: UUID
    let petId: UUID
    let serviceId: UUID
    let variantId: UUID
    let circuitId: UUID
    let cadence: String
    let nextOccurrenceAt: Date
    let isActive: Bool

    enum CodingKeys: String, CodingKey {
        case id, cadence
        case userId = "user_id", petId = "pet_id", serviceId = "service_id", variantId = "variant_id"
        case circuitId = "circuit_id", nextOccurrenceAt = "next_occurrence_at", isActive = "is_active"
    }

    func toDomain() -> RecurringBookingRule {
        RecurringBookingRule(id: id, userId: userId, petId: petId, serviceId: serviceId, variantId: variantId,
                              circuitId: circuitId, cadence: RecurringBookingRule.Cadence(rawValue: cadence) ?? .monthly,
                              nextOccurrenceAt: nextOccurrenceAt, isActive: isActive)
    }
}

private struct SupabaseRecurringBookingRuleInsert: Encodable {
    let id: UUID
    let userId: UUID
    let petId: UUID
    let serviceId: UUID
    let variantId: UUID
    let circuitId: UUID
    let cadence: String
    let nextOccurrenceAt: Date
    let isActive: Bool

    enum CodingKeys: String, CodingKey {
        case id, cadence
        case userId = "user_id", petId = "pet_id", serviceId = "service_id", variantId = "variant_id"
        case circuitId = "circuit_id", nextOccurrenceAt = "next_occurrence_at", isActive = "is_active"
    }

    init(rule: RecurringBookingRule) {
        id = rule.id; userId = rule.userId; petId = rule.petId; serviceId = rule.serviceId
        variantId = rule.variantId; circuitId = rule.circuitId; cadence = rule.cadence.rawValue
        nextOccurrenceAt = rule.nextOccurrenceAt; isActive = rule.isActive
    }
}

// MARK: - F6 vet-initiated reschedule proposals

final class SupabaseRescheduleProposalRepository: RescheduleProposalRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func pendingProposal(visitId: UUID) async throws -> RescheduleProposal? {
        let rows: [SupabaseRescheduleProposalRow] = try await client
            .from("reschedule_proposals").select().eq("visit_id", value: visitId).eq("status", value: "pending")
            .limit(1).execute().value
        return rows.first?.toDomain()
    }

    func create(_ proposal: RescheduleProposal) async throws -> RescheduleProposal {
        let insert = SupabaseRescheduleProposalInsert(proposal: proposal)
        let rows: [SupabaseRescheduleProposalRow] = try await client
            .from("reschedule_proposals").insert(insert).select().execute().value
        guard let row = rows.first else { throw DomainError.unknown }
        return row.toDomain()
    }

    func respond(id: UUID, accept: Bool) async throws -> RescheduleProposal {
        let rows: [SupabaseRescheduleProposalRow] = try await client
            .from("reschedule_proposals").update(["status": accept ? "accepted" : "declined"])
            .eq("id", value: id).select().execute().value
        guard let row = rows.first else { throw DomainError.notFound("Reschedule proposal") }
        return row.toDomain()
    }
}

private struct SupabaseRescheduleProposalRow: Decodable {
    let id: UUID
    let visitId: UUID
    let proposedByRole: String
    let proposedSlotId: UUID
    let status: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, status
        case visitId = "visit_id", proposedByRole = "proposed_by_role"
        case proposedSlotId = "proposed_slot_id", createdAt = "created_at"
    }

    func toDomain() -> RescheduleProposal {
        RescheduleProposal(id: id, visitId: visitId,
                            proposedByRole: RescheduleProposal.ProposerRole(rawValue: proposedByRole) ?? .vet,
                            proposedSlotId: proposedSlotId,
                            status: RescheduleProposal.Status(rawValue: status) ?? .pending,
                            createdAt: createdAt)
    }
}

private struct SupabaseRescheduleProposalInsert: Encodable {
    let id: UUID
    let visitId: UUID
    let proposedByRole: String
    let proposedSlotId: UUID
    let status: String

    enum CodingKeys: String, CodingKey {
        case id, status
        case visitId = "visit_id", proposedByRole = "proposed_by_role", proposedSlotId = "proposed_slot_id"
    }

    init(proposal: RescheduleProposal) {
        id = proposal.id; visitId = proposal.visitId; proposedByRole = proposal.proposedByRole.rawValue
        proposedSlotId = proposal.proposedSlotId; status = proposal.status.rawValue
    }
}

private struct SupabaseSavedPaymentMethodRow: Decodable {
    let id: UUID
    let userId: UUID
    let gatewayTokenId: String
    let displayLabel: String
    let isDefault: Bool
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id", gatewayTokenId = "gateway_token_id"
        case displayLabel = "display_label", isDefault = "is_default", createdAt = "created_at"
    }

    func toDomain() -> SavedPaymentMethod {
        SavedPaymentMethod(id: id, userId: userId, gatewayTokenId: gatewayTokenId,
                            displayLabel: displayLabel, isDefault: isDefault, createdAt: createdAt)
    }
}

private struct SupabaseSupportRefundAuditRow: Decodable {
    let id: UUID
    let ticketId: UUID
    let visitId: UUID
    let issuedByUserId: UUID
    let kind: String
    let amountMinorUnits: Int
    let reason: String
    let refundId: UUID?
    let walletLedgerEntryId: UUID?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, kind, reason
        case ticketId = "ticket_id", visitId = "visit_id", issuedByUserId = "issued_by_user_id"
        case amountMinorUnits = "amount_minor_units", refundId = "refund_id"
        case walletLedgerEntryId = "wallet_ledger_entry_id", createdAt = "created_at"
    }

    func toDomain() -> SupportRefundAudit {
        SupportRefundAudit(id: id, ticketId: ticketId, visitId: visitId, issuedByUserId: issuedByUserId,
                            kind: SupportRefundAudit.Kind(rawValue: kind) ?? .refund,
                            amountMinorUnits: amountMinorUnits, reason: reason,
                            refundId: refundId, walletLedgerEntryId: walletLedgerEntryId, createdAt: createdAt)
    }
}

// MARK: - J8: SMS/WhatsApp fallback when push fails.
//
// No real gateway (Twilio/MSG91/...) is wired into this codebase — this
// calls the `send-sms-fallback` Edge Function, whose body is a clearly
// marked stub that logs the intent server-side (append-only
// `sms_fallback_log`, service-role only) rather than placing a live call.
// See NotificationDeliveryPolicy/SendTransactionalNotificationUseCase for
// the decision this repository is invoked from.
final class SupabaseSMSFallbackRepository: SMSFallbackRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func sendFallback(
        userId: UUID, phone: String, category: TransactionalNotificationCategory,
        body: String, reason: NotificationDeliveryDecision.FallbackReason
    ) async throws -> SMSFallbackRecord {
        struct Body: Encodable {
            let userId: UUID
            let phone: String
            let category: String
            let body: String
            let reason: String
            enum CodingKeys: String, CodingKey {
                case userId = "user_id", phone, category, body, reason
            }
        }
        let requestBody = Body(userId: userId, phone: phone, category: category.rawValue, body: body, reason: reason.rawValue)
        let row: SupabaseSMSFallbackRow = try await client.functions.invoke("send-sms-fallback", options: .init(body: requestBody))
        return row.toDomain()
    }
}

private struct SupabaseSMSFallbackRow: Decodable {
    let id: UUID
    let userId: UUID
    let phone: String
    let category: String
    let body: String
    let reason: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, phone, category, body, reason
        case userId = "user_id", createdAt = "created_at"
    }

    func toDomain() -> SMSFallbackRecord {
        SMSFallbackRecord(
            id: id, userId: userId, phone: phone,
            category: TransactionalNotificationCategory(rawValue: category) ?? .visitConfirmed,
            body: body, reason: NotificationDeliveryDecision.FallbackReason(rawValue: reason) ?? .noPushToken,
            createdAt: createdAt
        )
    }
}

// MARK: - K6: lab test reports — select-only for the client; reports are
// uploaded ops-side (see 0041_lab_test_reports.sql's RLS: no insert policy).
final class SupabaseLabTestReportRepository: LabTestReportRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func reports(petId: UUID) async throws -> [LabTestReport] {
        let rows: [SupabaseLabTestReportRow] = try await client
            .from("lab_test_reports").select().eq("pet_id", value: petId).order("created_at", ascending: false).execute().value
        return rows.map { $0.toDomain() }
    }

    func reports(visitId: UUID) async throws -> [LabTestReport] {
        let rows: [SupabaseLabTestReportRow] = try await client
            .from("lab_test_reports").select().eq("visit_id", value: visitId).order("created_at", ascending: false).execute().value
        return rows.map { $0.toDomain() }
    }
}

private struct SupabaseLabTestReportRow: Decodable {
    let id: UUID
    let visitId: UUID
    let petId: UUID
    let testName: String
    let status: String
    let reportFilePath: String?
    let resultSummary: String?
    let availableAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, status
        case visitId = "visit_id", petId = "pet_id", testName = "test_name"
        case reportFilePath = "report_file_path", resultSummary = "result_summary"
        case availableAt = "available_at"
    }

    func toDomain() -> LabTestReport {
        LabTestReport(
            id: id, visitId: visitId, petId: petId, testName: testName,
            status: LabTestReport.Status(rawValue: status) ?? .pending,
            reportFileURL: reportFilePath.flatMap { URL(string: "mock-storage://\($0)") },
            resultSummary: resultSummary, availableAt: availableAt
        )
    }
}

#endif
