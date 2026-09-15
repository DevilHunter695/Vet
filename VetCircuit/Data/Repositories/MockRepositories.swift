import Foundation

// MARK: - In-memory mock repositories
// Used for SwiftUI previews, unit tests, and running the app without a
// configured backend. Swap for Supabase-backed implementations in
// App/DependencyContainer.swift once a project is configured.

actor MockAuthRepository: AuthRepository {
    private var user: User? = MockData.user

    func currentUser() async -> User? { user }

    func signInWithApple(identityToken: String, nonce: String) async throws -> User {
        user = MockData.user
        return MockData.user
    }

    func requestOTP(phone: String) async throws {}

    func verifyOTP(phone: String, code: String) async throws -> User {
        user = MockData.user
        return MockData.user
    }

    func signOut() async throws { user = nil }
}

actor MockCircuitRepository: CircuitRepository {
    /// L1/L3: a vet must be verified before "going live" — an unverified vet
    /// was previously visible and bookable here, which is the real gap plan
    /// §L1/§L3 call out, not just a missing badge on an already-safe list.
    func listCircuits(area: String?) async throws -> [Circuit] {
        let verifiedOnly = MockData.circuits.filter { $0.vet?.verificationStatus == .verified }
        guard let area else { return verifiedOnly }
        return verifiedOnly.filter { $0.clusterArea.localizedCaseInsensitiveContains(area) }
    }

    func circuit(id: UUID) async throws -> Circuit {
        guard let circuit = MockData.circuits.first(where: { $0.id == id }) else {
            throw DomainError.notFound("Circuit")
        }
        return circuit
    }
}

actor MockAccountRepository: AccountRepository {
    private var deletionRequests: [UUID: DeletionRequest] = [:]

    func requestDeletion(userId: UUID) async throws -> DeletionRequest {
        let request = DeletionRequest(
            id: UUID(), userId: userId, requestedAt: .now,
            scheduledPurgeAt: Calendar.current.date(byAdding: .day, value: DeletionRequest.softWindowDays, to: .now) ?? .now,
            status: .pending
        )
        deletionRequests[userId] = request
        return request
    }

    func cancelDeletionRequest(userId: UUID) async throws {
        deletionRequests[userId]?.status = .cancelled
    }

    func pendingDeletionRequest(userId: UUID) async throws -> DeletionRequest? {
        let request = deletionRequests[userId]
        return request?.status == .pending ? request : nil
    }

    func exportData(userId: UUID) async throws -> DataExport {
        DataExport(
            user: MockData.user, addresses: [MockData.address], visits: MockData.visits,
            consents: [], generatedAt: .now
        )
    }

    private var profiles: [UUID: User] = [:]

    func updateProfile(_ user: User) async throws -> User {
        profiles[user.id] = user
        return user
    }

    func updatePhoto(userId: UUID, data: Data) async throws -> User {
        var user = profiles[userId] ?? MockData.user
        user.photoURL = URL(string: "https://mock.vetcircuit.app/profile-photos/\(userId)/\(UUID().uuidString).jpg")
        profiles[userId] = user
        return user
    }
}

actor MockVisitOTPRepository: VisitOTPRepository {
    private var otps: [UUID: VisitOTP] = [:]

    func generateOTP(visitId: UUID) async throws -> VisitOTP {
        if let existing = otps[visitId], !existing.isExpired { return existing }
        let code = String(format: "%04d", Int.random(in: 0...9999))
        let otp = VisitOTP(visitId: visitId, code: code, expiresAt: Date().addingTimeInterval(3600), verifiedAt: nil)
        otps[visitId] = otp
        return otp
    }

    func verifyOTP(visitId: UUID, code: String) async throws -> Bool {
        guard var otp = otps[visitId], !otp.isExpired, otp.code == code else { return false }
        otp.verifiedAt = .now
        otps[visitId] = otp
        return true
    }
}

actor MockConsentRepository: ConsentRepository {
    private var consents: [ConsentRecord] = []

    func activeConsents(userId: UUID) async throws -> [ConsentRecord] {
        consents.filter { $0.userId == userId && $0.isActive }
    }

    func grant(userId: UUID, purpose: String, version: String) async throws -> ConsentRecord {
        let record = ConsentRecord(id: UUID(), userId: userId, purpose: purpose, version: version, grantedAt: .now, withdrawnAt: nil)
        consents.append(record)
        return record
    }

    func withdraw(userId: UUID, purpose: String) async throws {
        for index in consents.indices where consents[index].userId == userId && consents[index].purpose == purpose {
            consents[index].withdrawnAt = .now
        }
    }
}

actor MockCartRepository: CartRepository {
    private var carts: [UUID: Cart] = [:]

    func currentCart(userId: UUID) async throws -> Cart {
        carts[userId] ?? Cart(id: UUID(), userId: userId)
    }

    func save(_ cart: Cart) async throws -> Cart {
        carts[cart.userId] = cart
        return cart
    }

    func clear(userId: UUID) async throws {
        carts[userId] = nil
    }
}

actor MockQuoteRepository: QuoteRepository {
    private let couponRepository: CouponRepository
    private let walletRepository: WalletRepository

    init(couponRepository: CouponRepository, walletRepository: WalletRepository) {
        self.couponRepository = couponRepository
        self.walletRepository = walletRepository
    }

    func createQuote(for cart: Cart, catalog: [Service], overrides: [VetServiceOverride], useWalletBalance: Bool, applyEntitlementCredit: Bool) async throws -> Quote {
        // D5: a variant-specific override wins over a whole-service one, and
        // only an offered override counts as a price override at all — an
        // unoffered service shouldn't reach checkout in the first place, but
        // pricing here stays defensive regardless.
        func override(for item: CartItem) -> VetServiceOverride? {
            overrides.first { $0.isOffered && $0.serviceId == item.serviceId && $0.variantId == item.variantId }
                ?? overrides.first { $0.isOffered && $0.serviceId == item.serviceId && $0.variantId == nil }
        }

        // Pre-discount/pre-wallet subtotal, computed first because coupon
        // validation (min-spend) and the percentage discount both need it.
        //
        // This is deliberately the PRE-TAX base. It used to be
        // `PricingEngine.quote(input).totalMinorUnits`, which is GST
        // *inclusive* — so a 20% coupon was taking 20% of the taxed amount
        // and `PricingEngine` then subtracted that from the untaxed one. The
        // customer received 23.6% off, not 20%, and the business ate the
        // difference on every percentage coupon. Passing `gstRate: 0` gets
        // the taxable base out of the same engine rather than re-deriving it
        // here, so the two can never drift apart.
        var preTaxSubtotal = 0
        for (index, item) in cart.items.enumerated() {
            guard let service = catalog.first(where: { $0.id == item.serviceId }),
                  let variant = service.variants.first(where: { $0.id == item.variantId }) else {
                throw DomainError.notFound("Service variant")
            }
            let addons = service.addons.filter { item.addonIds.contains($0.id) }
            let input = PricingEngine.Input(
                variant: variant, addons: addons,
                additionalPetCount: max(0, item.petIds.count - 1),
                travelFeeMinorUnits: cart.circuitId != nil ? 0 : 4_500,
                // `gstRate` precedes `entitlementCreditApplied` in Input's
                // property order, and Swift requires memberwise arguments in
                // declaration order.
                gstRate: 0,
                // H6: a credit pays for one visit — applied to the first
                // line item only, never every line in a multi-item cart.
                entitlementCreditApplied: applyEntitlementCredit && index == 0,
                vetOverridePriceMinorUnits: override(for: item)?.priceOverrideMinorUnits,
                quantity: item.quantity
            )
            preTaxSubtotal += PricingEngine.quote(input).totalMinorUnits
        }

        var couponDiscount = 0
        if let code = cart.couponCode, !code.isEmpty,
           // Min-spend is measured on the same base the percentage applies
           // to; a coupon whose threshold and whose discount disagree about
           // what "the cart is worth" is a bug waiting to be argued about.
           let coupon = try await couponRepository.validate(code: code, userId: cart.userId, cartTotalMinorUnits: preTaxSubtotal) {
            couponDiscount = Self.discountMinorUnits(for: coupon, subtotal: preTaxSubtotal)
        }

        var walletBalance = 0
        if useWalletBalance {
            walletBalance = try await walletRepository.balanceMinorUnits(userId: cart.userId)
        }

        var lineItems: [PriceLineItem] = []
        var total = 0
        for (index, item) in cart.items.enumerated() {
            guard let service = catalog.first(where: { $0.id == item.serviceId }),
                  let variant = service.variants.first(where: { $0.id == item.variantId }) else {
                throw DomainError.notFound("Service variant")
            }
            let addons = service.addons.filter { item.addonIds.contains($0.id) }
            // Coupon/wallet/entitlement all apply once, against the *first*
            // line item's computation, so a multi-item cart doesn't
            // double-apply any of them — mirrors the single-total shape a
            // real server-side quote returns.
            let isFirst = index == 0
            let input = PricingEngine.Input(
                variant: variant, addons: addons,
                additionalPetCount: max(0, item.petIds.count - 1),
                travelFeeMinorUnits: cart.circuitId != nil ? 0 : 4_500,
                couponDiscountMinorUnits: isFirst ? couponDiscount : 0,
                walletBalanceMinorUnits: isFirst ? walletBalance : 0,
                entitlementCreditApplied: applyEntitlementCredit && isFirst,
                vetOverridePriceMinorUnits: override(for: item)?.priceOverrideMinorUnits,
                quantity: item.quantity
            )
            let breakdown = PricingEngine.quote(input)
            lineItems.append(contentsOf: breakdown.lineItems)
            total += breakdown.totalMinorUnits
        }
        let breakdown = PriceBreakdown(lineItems: lineItems, totalMinorUnits: total)
        // A real deployment HMAC-signs this with a server-held secret; the
        // mock stands in with a deterministic non-secret marker so the
        // client contract (a quote must carry *some* signature) is exercised.
        let signature = "mock-signed-\(cart.id.uuidString)-\(total)"
        return Quote(id: UUID(), cartId: cart.id, breakdown: breakdown, signature: signature,
                     expiresAt: Date().addingTimeInterval(Quote.ttl))
    }

    private static func discountMinorUnits(for coupon: Coupon, subtotal: Int) -> Int {
        let raw: Int
        switch coupon.discountType {
        case .percentageOff: raw = subtotal * coupon.discountValue / 100
        case .fixedAmountOff: raw = coupon.discountValue
        }
        if let cap = coupon.maxDiscountMinorUnits { return min(raw, cap) }
        return raw
    }
}

actor MockWalletRepository: WalletRepository {
    // A little starting credit so the CartView toggle has something to show
    // without needing a seeded backend.
    private var entriesByUser: [UUID: [WalletLedgerEntry]] = [:]
    private let seedAmount = 25_000 // ₹250

    private func seededEntries(userId: UUID) -> [WalletLedgerEntry] {
        if let existing = entriesByUser[userId] { return existing }
        let seed = [WalletLedgerEntry(id: UUID(), userId: userId, amountMinorUnits: seedAmount,
                                       reason: "Welcome credit", relatedVisitId: nil, relatedRefundId: nil, createdAt: .now)]
        entriesByUser[userId] = seed
        return seed
    }

    func balanceMinorUnits(userId: UUID) async throws -> Int {
        seededEntries(userId: userId).reduce(0) { $0 + $1.amountMinorUnits }
    }

    func entries(userId: UUID) async throws -> [WalletLedgerEntry] {
        seededEntries(userId: userId).sorted { $0.createdAt > $1.createdAt }
    }

    /// E5: not part of `WalletRepository` — called directly (concrete type,
    /// not the protocol) only by `MockLoyaltyRepository.redeemPoints`, so a
    /// local-dev redemption actually moves the mock wallet balance too,
    /// mirroring what the real `redeem_loyalty_points` Postgres function
    /// does atomically server-side.
    func creditFromLoyaltyRedemption(userId: UUID, amountMinorUnits: Int) {
        var entries = seededEntries(userId: userId)
        entries.append(WalletLedgerEntry(id: UUID(), userId: userId, amountMinorUnits: amountMinorUnits,
                                          reason: "Loyalty points redeemed", relatedVisitId: nil, relatedRefundId: nil, createdAt: .now))
        entriesByUser[userId] = entries
    }
}

actor MockCouponRepository: CouponRepository {
    // N2 example campaigns — mirrors what validate_coupon() would enforce.
    private let coupons: [Coupon] = [
        Coupon(id: UUID(), code: "FIRSTVISIT", discountType: .percentageOff, discountValue: 20,
               maxDiscountMinorUnits: 30_000, validFrom: .distantPast, validUntil: .distantFuture,
               usageLimit: nil, perUserLimit: 1, minSpendMinorUnits: nil, campaignName: "First-visit welcome"),
        Coupon(id: UUID(), code: "WINBACK100", discountType: .fixedAmountOff, discountValue: 10_000,
               maxDiscountMinorUnits: nil, validFrom: .distantPast, validUntil: .distantFuture,
               usageLimit: nil, perUserLimit: 1, minSpendMinorUnits: 20_000, campaignName: "Win-back"),
        // N2: the third named campaign type (first-visit, win-back, cluster-launch).
        Coupon(id: UUID(), code: "CLUSTERLAUNCH", discountType: .percentageOff, discountValue: 15,
               maxDiscountMinorUnits: 20_000, validFrom: .distantPast, validUntil: .distantFuture,
               usageLimit: 500, perUserLimit: nil, minSpendMinorUnits: nil, campaignName: "Cluster launch"),
        Coupon(id: UUID(), code: "EXPIRED10", discountType: .percentageOff, discountValue: 10,
               maxDiscountMinorUnits: nil, validFrom: .distantPast,
               validUntil: Date().addingTimeInterval(-86_400), usageLimit: nil, perUserLimit: nil,
               minSpendMinorUnits: nil, campaignName: "Expired example"),
    ]

    func validate(code: String, userId: UUID, cartTotalMinorUnits: Int) async throws -> Coupon? {
        guard let coupon = coupons.first(where: { $0.code.caseInsensitiveCompare(code) == .orderedSame }) else { return nil }
        let now = Date()
        guard coupon.validFrom <= now, now <= coupon.validUntil else { return nil }
        if let minSpend = coupon.minSpendMinorUnits, cartTotalMinorUnits < minSpend { return nil }
        return coupon
    }
}

actor MockSlotHoldRepository: SlotHoldRepository {
    private var holds: [SlotHold] = []

    func placeHold(slotId: UUID, userId: UUID) async throws -> SlotHold {
        holds.removeAll(where: \.isExpired)
        let hold = SlotHold(id: UUID(), slotId: slotId, userId: userId, expiresAt: Date().addingTimeInterval(SlotHold.holdDuration))
        holds.append(hold)
        return hold
    }

    func releaseHold(id: UUID) async throws {
        holds.removeAll { $0.id == id }
    }

    func activeHolds(slotId: UUID) async throws -> [SlotHold] {
        holds.removeAll(where: \.isExpired)
        return holds.filter { $0.slotId == slotId }
    }
}

actor MockAddressRepository: AddressRepository {
    private var addresses: [Address] = [MockData.address]

    /// Mirrors the served clusters in `MockData.circuits` — a coarse
    /// "within ~2km" check stands in for the real PostGIS polygon lookup.
    private let servedClusters: [(area: String, lat: Double, lng: Double)] = [
        ("Koramangala 5th Block", 12.9352, 77.6146),
        ("Indiranagar 100 Feet Road", 12.9719, 77.6412),
        ("HSR Layout Sector 2", 12.9121, 77.6446),
        ("Whitefield", 12.9698, 77.7500),
        ("JP Nagar Phase 6", 12.9010, 77.5850),
        ("Jayanagar 4th Block", 12.9250, 77.5938),
        ("Bellandur", 12.9260, 77.6762),
    ]

    func listAddresses(ownerId: UUID) async throws -> [Address] {
        addresses.filter { $0.ownerId == ownerId }
    }

    func addAddress(_ address: Address) async throws -> Address {
        var address = address
        if addresses.isEmpty || addresses.allSatisfy({ $0.ownerId != address.ownerId }) {
            address.isDefault = true
        }
        addresses.append(address)
        return address
    }

    func updateAddress(_ address: Address) async throws -> Address {
        guard let index = addresses.firstIndex(where: { $0.id == address.id }) else {
            throw DomainError.notFound("Address")
        }
        addresses[index] = address
        return address
    }

    func deleteAddress(id: UUID) async throws {
        addresses.removeAll { $0.id == id }
    }

    func setDefault(id: UUID, ownerId: UUID) async throws {
        for index in addresses.indices where addresses[index].ownerId == ownerId {
            addresses[index].isDefault = addresses[index].id == id
        }
    }

    func matchCluster(latitude: Double, longitude: Double) async throws -> String? {
        let thresholdDegrees = 0.03 // ~3km, generous for a mock geofence
        return servedClusters.first {
            abs($0.lat - latitude) < thresholdDegrees && abs($0.lng - longitude) < thresholdDegrees
        }?.area
    }

    /// C7: same list `matchCluster` checks against, ~3km (the mock's
    /// `thresholdDegrees`) converted to a radius for the map to draw.
    func listServedClusters() async throws -> [ServedCluster] {
        servedClusters.map { ServedCluster(area: $0.area, latitude: $0.lat, longitude: $0.lng, radiusKm: 3) }
    }
}

actor MockCatalogRepository: CatalogRepository {
    private var extraServices: [Service] = []

    /// Test-only hook to inject additional fixtures without mutating shared `MockData`.
    func seed(_ services: [Service]) { extraServices.append(contentsOf: services) }

    func listServices(vertical: Vertical?) async throws -> [Service] {
        let all = MockData.services + extraServices
        guard let vertical else { return all }
        return all.filter { $0.category.vertical == vertical }
    }

    func service(id: UUID) async throws -> Service {
        guard let service = (MockData.services + extraServices).first(where: { $0.id == id }) else {
            throw DomainError.notFound("Service")
        }
        return service
    }
}

actor MockPackageRepository: PackageRepository {
    private var redemptions: [PackageRedemption] = []

    func listPackages(vertical: Vertical?) async throws -> [Package] {
        guard let vertical else { return MockData.packages }
        return MockData.packages.filter { $0.vertical == vertical }
    }

    func package(id: UUID) async throws -> Package {
        guard let package = MockData.packages.first(where: { $0.id == id }) else {
            throw DomainError.notFound("Package")
        }
        return package
    }

    func createRedemption(userId: UUID, packageId: UUID, packageItemId: UUID, serviceId: UUID, totalCount: Int) async throws -> PackageRedemption {
        let redemption = PackageRedemption(
            id: UUID(), userId: userId, packageId: packageId, packageItemId: packageItemId,
            serviceId: serviceId, totalCount: totalCount, usedCount: 0, purchasedAt: .now
        )
        redemptions.append(redemption)
        return redemption
    }

    func redemptions(userId: UUID) async throws -> [PackageRedemption] {
        redemptions.filter { $0.userId == userId }
    }

    func redemption(id: UUID) async throws -> PackageRedemption {
        guard let redemption = redemptions.first(where: { $0.id == id }) else {
            throw DomainError.notFound("Package redemption")
        }
        return redemption
    }

    /// D4: called by `MockVisitRepository.createVisit` in the same spirit
    /// `book_visit()`'s SQL locks + bumps `used_count` in one transaction —
    /// this actor's own isolation is what serializes concurrent redeems here.
    fileprivate func redeem(id: UUID) throws -> PackageRedemption {
        guard let index = redemptions.firstIndex(where: { $0.id == id }) else {
            throw DomainError.notFound("Package redemption")
        }
        let updated = try PackageRedemptionPolicy.redeem(redemptions[index])
        redemptions[index] = updated
        return updated
    }
}

actor MockVisitRepository: VisitRepository {
    private var visits: [Visit] = MockData.visits
    /// D4: threaded in so a redeeming booking can atomically bump the
    /// matching `PackageRedemption.usedCount` — set by `DependencyContainer`
    /// to the same `MockPackageRepository` instance the rest of the app uses.
    private let packageRepository: MockPackageRepository?

    init(packageRepository: MockPackageRepository? = nil) {
        self.packageRepository = packageRepository
    }
    /// Simulates the DB's `idempotency_keys` table (Appendix D): the same
    /// key always returns the same visit rather than creating a duplicate.
    private var visitsByIdempotencyKey: [String: UUID] = [:]
    /// Simulates `SELECT ... FOR UPDATE` + the capacity CHECK inside
    /// `book_visit()` — a slot can never be oversold even under concurrent
    /// calls, since actor isolation serializes access to this dictionary.
    private var bookedCountBySlot: [UUID: Int] = [:]
    // I2: mirrors 0046_visit_status_events.sql's trigger — every status this
    // repository ever set, timestamped, oldest first.
    private var statusEvents: [UUID: [VisitStatusEvent]] = [:]

    private func logStatusEvent(visitId: UUID, status: Visit.VisitStatus) {
        statusEvents[visitId, default: []].append(VisitStatusEvent(id: UUID(), visitId: visitId, status: status, occurredAt: .now))
    }

    func createVisit(petId: UUID, vetId: UUID, circuitId: UUID, slot: ScheduleSlot, idempotencyKey: String, serviceId: UUID?, variantId: UUID?, packageRedemptionId: UUID?) async throws -> Visit {
        if let existingVisitId = visitsByIdempotencyKey[idempotencyKey],
           let existing = visits.first(where: { $0.id == existingVisitId }) {
            return existing
        }
        let alreadyBooked = bookedCountBySlot[slot.id] ?? 0
        guard slot.bookedCount + alreadyBooked < slot.capacity else {
            throw DomainError.slotUnavailable
        }
        // D4: redeem the package entitlement (if any) *before* inserting the
        // visit — mirrors book_visit()'s ordering, so a bug/race that would
        // over-redeem an exhausted entitlement fails the whole booking
        // instead of leaving a visit on record that never actually decremented it.
        if let packageRedemptionId {
            _ = try await packageRepository?.redeem(id: packageRedemptionId)
        }
        let visit = Visit(
            id: UUID(), userId: MockData.user.id, petId: petId, vetId: vetId, circuitId: circuitId,
            status: .requested, scheduledAt: slot.startTime, completedAt: nil, notes: nil, paymentId: nil,
            serviceId: serviceId, variantId: variantId, packageRedemptionId: packageRedemptionId
        )
        visits.append(visit)
        visitsByIdempotencyKey[idempotencyKey] = visit.id
        bookedCountBySlot[slot.id] = alreadyBooked + 1
        logStatusEvent(visitId: visit.id, status: .requested)
        return visit
    }

    func listVisits(userId: UUID) async throws -> [Visit] {
        visits.filter { $0.userId == userId }
    }

    func visit(id: UUID) async throws -> Visit {
        guard let visit = visits.first(where: { $0.id == id }) else { throw DomainError.notFound("Visit") }
        return visit
    }

    func updateStatus(visitId: UUID, status: Visit.VisitStatus) async throws -> Visit {
        guard let index = visits.firstIndex(where: { $0.id == visitId }) else { throw DomainError.notFound("Visit") }
        visits[index].status = status
        logStatusEvent(visitId: visitId, status: status)
        return visits[index]
    }

    func attachPayment(visitId: UUID, paymentId: UUID) async throws -> Visit {
        guard let index = visits.firstIndex(where: { $0.id == visitId }) else { throw DomainError.notFound("Visit") }
        visits[index].paymentId = paymentId
        visits[index].status = .confirmed
        logStatusEvent(visitId: visitId, status: .confirmed)
        return visits[index]
    }

    func cancelVisit(visitId: UUID) async throws {
        guard let index = visits.firstIndex(where: { $0.id == visitId }) else { throw DomainError.notFound("Visit") }
        visits[index].status = .cancelledByUser
        logStatusEvent(visitId: visitId, status: .cancelledByUser)
    }

    func statusHistory(visitId: UUID) async throws -> [VisitStatusEvent] {
        if let recorded = statusEvents[visitId], !recorded.isEmpty {
            return recorded.sorted { $0.occurredAt < $1.occurredAt }
        }
        // Defensive fallback for any visit this actor didn't itself create
        // (MockData.visits is empty today, but a future seed or a Supabase-
        // backed preview isn't guaranteed to have gone through createVisit/
        // updateStatus) — synthesize a plausible timeline leading up to the
        // visit's current status rather than returning an empty list.
        guard let visit = visits.first(where: { $0.id == visitId }) else { return [] }
        let order: [Visit.VisitStatus] = [.requested, .confirmed, .assigned, .enRoute, .arrived, .inProgress, .completed]
        guard let currentIndex = order.firstIndex(of: visit.status) else {
            return [VisitStatusEvent(id: UUID(), visitId: visitId, status: visit.status, occurredAt: visit.scheduledAt)]
        }
        let anchor = visit.completedAt ?? visit.scheduledAt
        return order[...currentIndex].enumerated().map { offset, status in
            let stepsFromEnd = currentIndex - offset
            let timestamp = Calendar.current.date(byAdding: .minute, value: -15 * stepsFromEnd, to: anchor) ?? anchor
            return VisitStatusEvent(id: UUID(), visitId: visitId, status: status, occurredAt: timestamp)
        }
    }

    func rescheduleVisit(visitId: UUID, newSlot: ScheduleSlot) async throws -> Visit {
        guard let index = visits.firstIndex(where: { $0.id == visitId }) else { throw DomainError.notFound("Visit") }
        visits[index].scheduledAt = newSlot.startTime
        return visits[index]
    }

    func paidAmountMinorUnits(visitId: UUID) async throws -> Int {
        // Mock visits don't carry a real payment row; stand in with a
        // representative consult price so the policy math has something to work with.
        59_900
    }
}

actor MockRefundRepository: RefundRepository {
    private var refunds: [Refund] = []

    func issueRefund(visitId: UUID, paymentId: UUID, amountMinorUnits: Int, reason: String, initiatedByOpsUserId: UUID?) async throws -> Refund {
        let refund = Refund(id: UUID(), visitId: visitId, paymentId: paymentId, amountMinorUnits: amountMinorUnits,
                             reason: reason, status: .processed, createdAt: .now, initiatedByOpsUserId: initiatedByOpsUserId)
        refunds.append(refund)
        return refund
    }

    func refunds(visitId: UUID) async throws -> [Refund] {
        refunds.filter { $0.visitId == visitId }
    }
}

actor MockPaymentDisputeRepository: PaymentDisputeRepository {
    // No mock visit has a real gateway dispute against it — mirrors
    // MockInvoiceRepository's "nothing yet" stance.
    private var seededDisputes: [PaymentDispute] = []

    /// The comment here used to say "a future test can seed this array
    /// directly", which wasn't actually possible: the property is
    /// actor-isolated, so no test could mutate it from outside. This is that
    /// seam, made real.
    func seed(_ disputes: [PaymentDispute]) { seededDisputes = disputes }

    func disputes(visitId: UUID) async throws -> [PaymentDispute] {
        seededDisputes.filter { $0.visitId == visitId }
    }
}

// G5: generates a stand-in GST invoice for any visit so InvoiceView has
// something real to render in mock mode — the Supabase conformer instead
// reads an already-issued row (invoice numbering/GST math is server-side).
/// H7: corporate/RWA seat assignment roster.
actor MockCorporateSeatAssignmentRepository: CorporateSeatAssignmentRepository {
    private var assignments: [CorporateSeatAssignment] = []

    func assignments(subscriptionId: UUID) async throws -> [CorporateSeatAssignment] {
        assignments.filter { $0.subscriptionId == subscriptionId }
    }

    func assignSeat(subscriptionId: UUID, phone: String, seatCount: Int) async throws -> CorporateSeatAssignment {
        let current = assignments.filter { $0.subscriptionId == subscriptionId }
        guard current.count < seatCount else {
            throw DomainError.validation("All \(seatCount) seats are already assigned — remove one first.")
        }
        let assignment = CorporateSeatAssignment(id: UUID(), subscriptionId: subscriptionId, assignedPhone: phone, assignedUserId: nil, assignedAt: .now)
        assignments.append(assignment)
        return assignment
    }

    func unassignSeat(id: UUID) async throws {
        assignments.removeAll { $0.id == id }
    }
}

/// I8: device-local dedupe for the post-visit summary push — see the honest
/// gap noted on `PostVisitSummaryRepository`. Used regardless of Mock/
/// Supabase backend, since there's no server-side equivalent to call.
actor LocalPostVisitSummaryRepository: PostVisitSummaryRepository {
    private let defaultsKey = "postVisitSummarySentVisitIds"

    func hasSent(visitId: UUID) async throws -> Bool {
        sentIds().contains(visitId)
    }

    func markSent(visitId: UUID) async throws {
        var ids = sentIds()
        ids.insert(visitId)
        UserDefaults.standard.set(ids.map(\.uuidString), forKey: defaultsKey)
    }

    private func sentIds() -> Set<UUID> {
        let raw = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        return Set(raw.compactMap(UUID.init))
    }
}

/// F4: device-local dedupe for `FlagVisitNoShowUseCase` — see the honest gap
/// noted on `NoShowDetectionRepository`. Used regardless of Mock/Supabase
/// backend, since there's no server-side equivalent to call, mirroring
/// `LocalPostVisitSummaryRepository` exactly.
actor LocalNoShowDetectionRepository: NoShowDetectionRepository {
    private let defaultsKey = "noShowFlaggedVisitIds"

    func hasFlagged(visitId: UUID) async throws -> Bool {
        flaggedIds().contains(visitId)
    }

    func markFlagged(visitId: UUID) async throws {
        var ids = flaggedIds()
        ids.insert(visitId)
        UserDefaults.standard.set(ids.map(\.uuidString), forKey: defaultsKey)
    }

    private func flaggedIds() -> Set<UUID> {
        let raw = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        return Set(raw.compactMap(UUID.init))
    }
}

/// H4: device-local dedupe for `RenewalReminderUseCase` — see the honest gap
/// noted on `RenewalReminderDedupeRepository`. Keyed by subscription + stage
/// + calendar day (an ISO date string), not just subscription id, since the
/// same stage recurs every renewal cycle and each occurrence needs its own
/// reminder.
actor LocalRenewalReminderDedupeRepository: RenewalReminderDedupeRepository {
    private let defaultsKey = "renewalReminderSentKeys"

    func hasSent(subscriptionId: UUID, stage: RenewalReminderPolicy.Stage, day: Date) async throws -> Bool {
        sentKeys().contains(key(subscriptionId: subscriptionId, stage: stage, day: day))
    }

    func markSent(subscriptionId: UUID, stage: RenewalReminderPolicy.Stage, day: Date) async throws {
        var keys = sentKeys()
        keys.insert(key(subscriptionId: subscriptionId, stage: stage, day: day))
        UserDefaults.standard.set(Array(keys), forKey: defaultsKey)
    }

    private func key(subscriptionId: UUID, stage: RenewalReminderPolicy.Stage, day: Date) -> String {
        let dayString = ISO8601DateFormatter().string(from: Calendar.current.startOfDay(for: day))
        return "\(subscriptionId.uuidString)|\(stage)|\(dayString)"
    }

    private func sentKeys() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
    }
}

// I7: fabricates a representative completed checklist, mirroring
// MockLabTestReportRepository/MockInvoiceRepository's "nothing to read
// server-side, so stand in with something real" stance.
actor MockVisitChecklistRepository: VisitChecklistRepository {
    func items(visitId: UUID) async throws -> [VisitChecklistItem] {
        let labels = ["Temperature & vitals check", "Weight recorded", "Physical examination", "Vaccination reviewed", "Owner questions answered"]
        return labels.enumerated().map { index, label in
            VisitChecklistItem(id: UUID(), visitId: visitId, label: label, isCompleted: true, note: nil,
                                completedAt: Calendar.current.date(byAdding: .minute, value: index * 5, to: .now), sortOrder: index)
        }
    }
}

actor MockInvoiceRepository: InvoiceRepository {
    /// G5: a tax invoice has to agree with itself. The previous version
    /// declared `gstMinorUnits` but put no GST line in the breakdown and set
    /// `totalMinorUnits` to the *pre-tax* subtotal — so the document showed a
    /// ₹599 total while separately claiming ₹107.82 of tax on it, and the tax
    /// it claimed appeared nowhere in the itemisation. Both are things a
    /// customer (or an auditor) would notice.
    func invoice(visitId: UUID) async throws -> Invoice? {
        let subtotal = 59_900
        let gstRate = 0.18
        let gst = Int((Double(subtotal) * gstRate).rounded())
        return Invoice(
            id: UUID(), visitId: visitId,
            invoiceNumber: Self.invoiceNumber(for: visitId),
            breakdown: PriceBreakdown(
                lineItems: [
                    PriceLineItem(label: "Home visit consultation", amountMinorUnits: subtotal),
                    // Itemised at the same rate and with the same label shape
                    // `PricingEngine` uses, so the invoice and the quote the
                    // customer approved describe the same charge.
                    PriceLineItem(label: "GST (\(Int(gstRate * 100))%)", amountMinorUnits: gst)
                ],
                totalMinorUnits: subtotal + gst
            ),
            gstMinorUnits: gst, issuedAt: .now
        )
    }

    /// Stable for the life of the visit, not just the life of the process.
    /// This used to be `abs(visitId.uuidString.hashValue % 999_999)`, and
    /// Swift seeds `String.hashValue` per process — so the same visit's
    /// invoice number changed every time the app was relaunched, which is
    /// exactly what an invoice number must never do. Derived from the UUID's
    /// own bytes instead. (Real GST numbering is sequential and server-issued;
    /// this is a deterministic stand-in, not a compliance implementation.)
    private static func invoiceNumber(for visitId: UUID) -> String {
        let bytes = withUnsafeBytes(of: visitId.uuid) { Array($0) }
        let value = bytes.reduce(UInt64(0)) { ($0 &* 31) &+ UInt64($1) }
        return "VC-\(String(format: "%06d", value % 1_000_000))"
    }
}

actor MockSubscriptionRepository: SubscriptionRepository {
    private var subscription: Subscription?
    private var dunning: DunningState?

    func currentSubscription(userId: UUID) async throws -> Subscription? { subscription }

    func subscribe(userId: UUID, plan: Subscription.PlanType) async throws -> Subscription {
        let sub = Subscription(id: UUID(), userId: userId, planType: plan, status: .active,
                                renewalDate: Calendar.current.date(byAdding: .month, value: 1, to: .now) ?? .now)
        subscription = sub
        return sub
    }

    func cancel(subscriptionId: UUID) async throws {
        if subscription?.id == subscriptionId { subscription?.status = .cancelled }
    }

    func changePlan(subscriptionId: UUID, to plan: Subscription.PlanType) async throws -> Subscription {
        guard var sub = subscription, sub.id == subscriptionId else { throw DomainError.notFound("Subscription") }
        sub.planType = plan
        subscription = sub
        return sub
    }

    func pause(subscriptionId: UUID) async throws -> Subscription {
        guard var sub = subscription, sub.id == subscriptionId else { throw DomainError.notFound("Subscription") }
        sub.status = .paused
        subscription = sub
        return sub
    }

    func resume(subscriptionId: UUID) async throws -> Subscription {
        guard var sub = subscription, sub.id == subscriptionId else { throw DomainError.notFound("Subscription") }
        sub.status = .active
        subscription = sub
        return sub
    }

    func dunningState(subscriptionId: UUID) async throws -> DunningState? {
        dunning?.subscriptionId == subscriptionId ? dunning : nil
    }

    func recordDunningState(_ state: DunningState) async throws {
        dunning = state
    }
}

actor MockPaymentRepository: PaymentRepository {
    // G6/E8: mirrors the `payments` table well enough for the booking
    // pipeline to poll a real id/status pair rather than a hardcoded
    // "always succeeded" — the id `createCheckout` implicitly creates is
    // recorded here so `latestPaymentId(forVisit:)` can hand it back.
    private var paymentIdsByVisit: [UUID: UUID] = [:]
    /// E8: pay-after-visit payments need a real, tracked status (starting
    /// `.payAfterVisit`, not the hardcoded "always succeeded" the rest of
    /// this mock uses to stand in for a webhook) so `paymentStatus`,
    /// `BookingCheckoutPolicy`, and `MarkPayAfterVisitCollectedUseCase` all
    /// see the same truth. Prepaid payments keep the old always-`.succeeded`
    /// simulated-webhook behavior when they're not in this dictionary.
    private var statusesByPaymentId: [UUID: Payment.Status] = [:]

    func createCheckout(forVisit visitId: UUID, quoteId: UUID, amountMinorUnits: Int) async throws -> URL {
        paymentIdsByVisit[visitId] = UUID()
        return URL(string: "https://checkout.example.com/visit/\(visitId)?quote=\(quoteId)&amount=\(amountMinorUnits)")!
    }

    func createCheckout(forVisit visitId: UUID, retryingPaymentId: UUID, amountMinorUnits: Int) async throws -> URL {
        URL(string: "https://checkout.example.com/visit/\(visitId)?retry=\(retryingPaymentId)&amount=\(amountMinorUnits)")!
    }

    func createCheckout(forSubscription plan: Subscription.PlanType, seatCount: Int) async throws -> URL {
        URL(string: "https://checkout.example.com/subscription/\(plan.rawValue)?seats=\(seatCount)")!
    }

    func paymentStatus(paymentId: UUID) async throws -> Payment.Status { statusesByPaymentId[paymentId] ?? .succeeded }

    func latestPaymentId(forVisit visitId: UUID) async throws -> UUID? { paymentIdsByVisit[visitId] }

    func createTipCheckout(forVisit visitId: UUID, amountMinorUnits: Int) async throws -> URL {
        URL(string: "https://checkout.example.com/tip/\(visitId)?amount=\(amountMinorUnits)")!
    }

    func bookPayAfterVisit(forVisit visitId: UUID, quoteId: UUID, amountMinorUnits: Int) async throws -> UUID {
        let paymentId = UUID()
        paymentIdsByVisit[visitId] = paymentId
        statusesByPaymentId[paymentId] = .payAfterVisit
        return paymentId
    }

    func markPayAfterVisitCollected(paymentId: UUID) async throws -> Payment.Status {
        guard statusesByPaymentId[paymentId] == .payAfterVisit else {
            throw DomainError.validation("This payment isn't a pay-after-visit payment awaiting collection.")
        }
        statusesByPaymentId[paymentId] = .succeeded
        return .succeeded
    }
}

actor MockSavedPaymentMethodRepository: SavedPaymentMethodRepository {
    private var methods: [SavedPaymentMethod] = [
        SavedPaymentMethod(id: UUID(), userId: MockData.user.id, gatewayTokenId: "tok_mock_visa4242",
                            displayLabel: "Visa •••• 4242", isDefault: true, createdAt: .now.addingTimeInterval(-86400 * 30)),
    ]

    func list(userId: UUID) async throws -> [SavedPaymentMethod] {
        methods.filter { $0.userId == userId }.sorted { $0.createdAt > $1.createdAt }
    }

    func save(userId: UUID, gatewayTokenId: String, displayLabel: String, makeDefault: Bool) async throws -> SavedPaymentMethod {
        if makeDefault {
            for i in methods.indices where methods[i].userId == userId { methods[i].isDefault = false }
        }
        let isFirst = !methods.contains { $0.userId == userId }
        let method = SavedPaymentMethod(id: UUID(), userId: userId, gatewayTokenId: gatewayTokenId,
                                         displayLabel: displayLabel, isDefault: makeDefault || isFirst, createdAt: .now)
        methods.append(method)
        return method
    }

    func remove(id: UUID) async throws {
        methods.removeAll { $0.id == id }
    }

    func setDefault(id: UUID, userId: UUID) async throws {
        for i in methods.indices where methods[i].userId == userId {
            methods[i].isDefault = (methods[i].id == id)
        }
    }
}

actor MockSupportRefundAuditRepository: SupportRefundAuditRepository {
    private var audits: [SupportRefundAudit] = []
    private let refundRepository: RefundRepository

    init(refundRepository: RefundRepository) {
        self.refundRepository = refundRepository
    }

    func issueSupportRefund(
        ticketId: UUID, visitId: UUID, issuedByUserId: UUID,
        kind: SupportRefundAudit.Kind, amountMinorUnits: Int, reason: String
    ) async throws -> SupportRefundAudit {
        var refundId: UUID?
        var walletLedgerEntryId: UUID?
        switch kind {
        case .refund:
            // Mirrors the real flow: even in the mock world this goes
            // through the same refund-issuing path a cancellation refund
            // would use, never a bespoke direct write.
            let refund = try await refundRepository.issueRefund(
                visitId: visitId, paymentId: UUID(), amountMinorUnits: amountMinorUnits,
                reason: reason, initiatedByOpsUserId: issuedByUserId
            )
            refundId = refund.id
        case .walletCredit:
            walletLedgerEntryId = UUID()
        }
        let audit = SupportRefundAudit(
            id: UUID(), ticketId: ticketId, visitId: visitId, issuedByUserId: issuedByUserId,
            kind: kind, amountMinorUnits: amountMinorUnits, reason: reason,
            refundId: refundId, walletLedgerEntryId: walletLedgerEntryId, createdAt: .now
        )
        audits.append(audit)
        return audit
    }

    func auditTrail(ticketId: UUID) async throws -> [SupportRefundAudit] {
        audits.filter { $0.ticketId == ticketId }.sorted { $0.createdAt > $1.createdAt }
    }
}

actor MockChatRepository: ChatRepository {
    private var messages: [UUID: [ChatMessage]] = [:]

    func history(visitId: UUID) async throws -> [ChatMessage] { messages[visitId] ?? [] }

    func send(visitId: UUID, body: String) async throws -> ChatMessage {
        let message = ChatMessage(id: UUID(), visitId: visitId, senderId: MockData.user.id, body: body, sentAt: .now, readAt: nil, attachmentURL: nil)
        messages[visitId, default: []].append(message)
        return message
    }

    func sendPhoto(visitId: UUID, imageData: Data) async throws -> ChatMessage {
        // No real storage bucket in mock mode — write to a local temp file so
        // the UI still has a real, loadable URL to render.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        try imageData.write(to: url)
        let message = ChatMessage(id: UUID(), visitId: visitId, senderId: MockData.user.id, body: "📷 Photo", sentAt: .now, readAt: nil, attachmentURL: url)
        messages[visitId, default: []].append(message)
        return message
    }

    nonisolated func subscribe(visitId: UUID, onMessage: @escaping @Sendable (ChatMessage) -> Void) -> AnyObject {
        NSObject() // no-op token; mock has no realtime transport
    }

    /// J3: flips `readAt` on every message not sent by `readerId`.
    func markRead(visitId: UUID, readerId: UUID) async throws {
        guard var thread = messages[visitId] else { return }
        let now = Date.now
        for index in thread.indices where thread[index].senderId != readerId && thread[index].readAt == nil {
            thread[index].readAt = now
        }
        messages[visitId] = thread
    }

    nonisolated func sendTypingIndicator(visitId: UUID, senderId: UUID) async {
        // No realtime transport in mock mode — nothing to broadcast to.
    }

    nonisolated func subscribeToTyping(visitId: UUID, onTyping: @escaping @Sendable (UUID) -> Void) -> AnyObject {
        NSObject() // no-op token; mock has no realtime transport
    }
}

actor MockReviewRepository: ReviewRepository {
    private var submitted: [Review] = []

    func submit(visitId: UUID, rating: Int, comment: String?, needsModeration: Bool, moderationFlags: [String]) async throws -> Review {
        let review = Review(id: UUID(), visitId: visitId, vetId: MockData.circuits[0].vetId, userId: MockData.user.id,
                             rating: rating, comment: comment, createdAt: .now,
                             needsModeration: needsModeration, moderationFlags: moderationFlags)
        submitted.append(review)
        return review
    }

    func reviews(vetId: UUID) async throws -> [Review] {
        (MockData.reviews[vetId] ?? []) + submitted.filter { $0.vetId == vetId }
    }
}

/// C11: mock 24x7 emergency clinic list — a handful of real Bangalore-area
/// examples so the emergency path has something plausible to route to.
actor MockEmergencyClinicRepository: EmergencyClinicRepository {
    func listClinics() async throws -> [EmergencyClinic] {
        MockData.emergencyClinics
    }
}

actor MockPetRepository: PetRepository {
    private var pets: [Pet] = MockData.user.pets

    func listPets(ownerId: UUID) async throws -> [Pet] { pets.filter { $0.ownerId == ownerId } }

    func addPet(_ pet: Pet) async throws -> Pet {
        pets.append(pet)
        return pet
    }

    func updatePet(_ pet: Pet) async throws -> Pet {
        guard let index = pets.firstIndex(where: { $0.id == pet.id }) else { throw DomainError.notFound("Pet") }
        pets[index] = pet
        return pet
    }

    func deletePet(id: UUID) async throws {
        pets.removeAll { $0.id == id }
    }

    func updatePhoto(petId: UUID, data: Data) async throws -> Pet {
        guard let index = pets.firstIndex(where: { $0.id == petId }) else { throw DomainError.notFound("Pet") }
        pets[index].photoURL = URL(string: "https://mock.local/pet-photos/\(petId)/\(UUID().uuidString).jpg")
        return pets[index]
    }
}

actor MockPetWeightRepository: PetWeightRepository {
    private var entries: [PetWeightEntry] = []

    func history(petId: UUID) async throws -> [PetWeightEntry] {
        entries.filter { $0.petId == petId }
    }

    func addEntry(_ entry: PetWeightEntry) async throws -> PetWeightEntry {
        entries.append(entry)
        return entry
    }
}

actor MockVaccinationRepository: VaccinationRepository {
    // Seeded so PetDetailView has something to render before anyone logs one.
    private var vaccinations: [Vaccination] = [
        Vaccination(id: UUID(), petId: MockData.user.pets.first?.id ?? UUID(), vaccineName: "Rabies",
                    givenAt: Calendar.current.date(byAdding: .month, value: -11, to: .now),
                    nextDueAt: Calendar.current.date(byAdding: .month, value: 1, to: .now) ?? .now,
                    batchNumber: "RB-2291"),
    ]

    func history(petId: UUID) async throws -> [Vaccination] {
        vaccinations.filter { $0.petId == petId }
    }

    func record(_ vaccination: Vaccination) async throws -> Vaccination {
        vaccinations.append(vaccination)
        return vaccination
    }
}

/// B6: document vault — no real storage backend wired up yet, so "upload"
/// just fabricates a placeholder `mock-storage://` URL from a UUID-based
/// filename and keeps the row in memory.
/// K6: reports are uploaded ops-side (out of this app's scope), so this mock
/// starts pre-seeded with a couple of demo rows for `MockData.user`'s pet
/// rather than exposing any way to add one from the client, mirroring the
/// real repository's read-only contract.
actor MockLabTestReportRepository: LabTestReportRepository {
    private var reportsById: [UUID: LabTestReport]

    init(seed: [LabTestReport] = MockData.labTestReports) {
        reportsById = Dictionary(uniqueKeysWithValues: seed.map { ($0.id, $0) })
    }

    func reports(petId: UUID) async throws -> [LabTestReport] {
        reportsById.values.filter { $0.petId == petId }
    }

    func reports(visitId: UUID) async throws -> [LabTestReport] {
        reportsById.values.filter { $0.visitId == visitId }
    }
}

actor MockVetOnboardingRepository: VetOnboardingRepository {
    private var applicationsById: [UUID: VetOnboardingApplication] = [:]

    func submit(_ application: VetOnboardingApplication) async throws -> VetOnboardingApplication {
        applicationsById[application.id] = application
        return application
    }

    func myApplications(applicantUserId: UUID) async throws -> [VetOnboardingApplication] {
        applicationsById.values.filter { $0.applicantUserId == applicantUserId }
    }

    func update(_ application: VetOnboardingApplication) async throws -> VetOnboardingApplication {
        guard let existing = applicationsById[application.id] else {
            throw DomainError.notFound("Vet onboarding application")
        }
        // Mirrors the RLS rule: the applicant may only update the row while
        // it is still `submitted`.
        guard existing.status == .submitted else {
            throw DomainError.validation("This application is already under review and can no longer be edited.")
        }
        applicationsById[application.id] = application
        return application
    }
}

actor MockPetDocumentRepository: PetDocumentRepository {
    private var documents: [PetDocument] = []

    func list(petId: UUID) async throws -> [PetDocument] {
        documents.filter { $0.petId == petId }
    }

    func upload(petId: UUID, uploaderId: UUID, title: String, data: Data) async throws -> PetDocument {
        // Simulate an upload: a real backend would push `data` to a Storage
        // bucket and store its path; here we just mint a UUID filename.
        let filename = "\(UUID().uuidString).pdf"
        let placeholderURL = URL(string: "mock-storage://documents/\(petId)/\(filename)")!
        let document = PetDocument(id: UUID(), petId: petId, uploaderId: uploaderId, title: title,
                                    fileURL: placeholderURL, uploadedAt: .now)
        documents.append(document)
        return document
    }

    func delete(id: UUID) async throws {
        documents.removeAll { $0.id == id }
    }
}

actor MockPrescriptionRepository: PrescriptionRepository {
    private var prescriptions: [Prescription] = []

    /// Without a seeding hook this mock was permanently empty, so
    /// `ManagePrescriptionsUseCase.history` had no reachable data path and
    /// B5 could not be tested at all.
    func seed(_ prescriptions: [Prescription]) { self.prescriptions = prescriptions }

    func history(petId: UUID) async throws -> [Prescription] {
        // Newest first: a stale prescription at the top of a medication list
        // is a dosing hazard, so the ordering is part of the contract.
        prescriptions
            .filter { $0.petId == petId }
            .sorted { $0.issuedAt > $1.issuedAt }
    }
}

actor MockPushTokenRepository: PushTokenRepository {
    private var tokensByUser: [UUID: String] = [:]

    func registerDeviceToken(_ token: String, userId: UUID) async throws {
        tokensByUser[userId] = token
    }

    func hasDeviceToken(userId: UUID) async throws -> Bool {
        tokensByUser[userId] != nil
    }
}

/// J8: no real SMS/WhatsApp gateway is wired in — this mock just records
/// what would have been sent, for previews and tests to inspect.
actor MockSMSFallbackRepository: SMSFallbackRepository {
    private(set) var sentRecords: [SMSFallbackRecord] = []

    func sendFallback(
        userId: UUID, phone: String, category: TransactionalNotificationCategory,
        body: String, reason: NotificationDeliveryDecision.FallbackReason
    ) async throws -> SMSFallbackRecord {
        let record = SMSFallbackRecord(
            id: UUID(), userId: userId, phone: phone, category: category,
            body: body, reason: reason, createdAt: .now
        )
        sentRecords.append(record)
        return record
    }
}

/// F9: no vet is on leave by default in the mock — seed a blackout in tests
/// or via `add`/`create` to exercise the filtering effect.
actor MockVetBlackoutRepository: VetBlackoutRepository {
    private var blackoutsById: [UUID: VetBlackout] = [:]

    func blackouts(vetId: UUID) async throws -> [VetBlackout] {
        blackoutsById.values.filter { $0.vetId == vetId }
    }

    func blackouts(vetIds: [UUID]) async throws -> [VetBlackout] {
        let set = Set(vetIds)
        return blackoutsById.values.filter { set.contains($0.vetId) }
    }

    func create(_ blackout: VetBlackout) async throws -> VetBlackout {
        blackoutsById[blackout.id] = blackout
        return blackout
    }

    func delete(id: UUID) async throws {
        blackoutsById.removeValue(forKey: id)
    }
}

/// K3: medication reminders, keyed by pet.
actor MockMedicationReminderRepository: MedicationReminderRepository {
    private var remindersById: [UUID: MedicationReminder] = [:]

    func reminders(petId: UUID) async throws -> [MedicationReminder] {
        remindersById.values.filter { $0.petId == petId }
    }

    func create(_ reminder: MedicationReminder) async throws -> MedicationReminder {
        remindersById[reminder.id] = reminder
        return reminder
    }

    func update(_ reminder: MedicationReminder) async throws -> MedicationReminder {
        guard remindersById[reminder.id] != nil else { throw DomainError.notFound("Medication reminder") }
        remindersById[reminder.id] = reminder
        return reminder
    }

    func delete(id: UUID) async throws {
        remindersById.removeValue(forKey: id)
    }
}

actor MockLiveTrackingRepository: LiveTrackingRepository {
    func currentLocation(visitId: UUID) async throws -> VetLocation? {
        // Bengaluru-ish coordinate, jittered slightly so the map shows movement.
        VetLocation(visitId: visitId, latitude: 12.9352 + Double.random(in: -0.002...0.002),
                    longitude: 77.6146 + Double.random(in: -0.002...0.002), updatedAt: .now, etaMinutes: Int.random(in: 3...20))
    }

    nonisolated func subscribeToLocation(visitId: UUID, onUpdate: @escaping @Sendable (VetLocation) -> Void) -> AnyObject {
        let timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { _ in
            let location = VetLocation(visitId: visitId, latitude: 12.9352 + Double.random(in: -0.003...0.003),
                                        longitude: 77.6146 + Double.random(in: -0.003...0.003), updatedAt: .now,
                                        etaMinutes: Int.random(in: 1...15))
            onUpdate(location)
        }
        return timer
    }
}

actor MockCallRepository: CallRepository {
    func startCall(visitId: UUID) async throws -> CallSession {
        // A real deployment gets this proxy number from Exotel/Twilio,
        // provisioned per-call; the mock uses a fixed demo number so the
        // "tap to call" flow is exercisable without a live gateway.
        CallSession(id: UUID(), visitId: visitId, proxyNumber: "+911800123456", expiresAt: .now.addingTimeInterval(3600))
    }
}

actor MockLoyaltyRepository: LoyaltyRepository {
    private var accounts: [UUID: LoyaltyAccount] = [:]
    // E5: concrete type, not the protocol — see `creditFromLoyaltyRedemption`'s
    // doc comment for why redemption needs the extra non-protocol method.
    private let walletRepository: MockWalletRepository?

    init(walletRepository: MockWalletRepository? = nil) {
        self.walletRepository = walletRepository
    }

    func account(userId: UUID) async throws -> LoyaltyAccount {
        accounts[userId] ?? LoyaltyAccount(userId: userId, points: 0, tier: .bronze)
    }

    func awardPoints(userId: UUID, points: Int) async throws -> LoyaltyAccount {
        var current = try await account(userId: userId)
        current.points += points
        current.tier = .forPoints(current.points)
        accounts[userId] = current
        return current
    }

    func redeemPoints(userId: UUID, points: Int) async throws -> LoyaltyAccount {
        var current = try await account(userId: userId)
        guard LoyaltyRedemptionPolicy.validate(points: points, availablePoints: current.points) == nil else {
            throw DomainError.validation("Not enough points to redeem.")
        }
        current.points -= points
        current.tier = .forPoints(current.points)
        accounts[userId] = current
        await walletRepository?.creditFromLoyaltyRedemption(userId: userId, amountMinorUnits: LoyaltyRedemptionPolicy.minorUnits(forPoints: points))
        return current
    }
}

actor MockReferralRepository: ReferralRepository {
    private var referrals: [Referral] = []

    func myReferralCode(userId: UUID) async throws -> String {
        "VC-" + userId.uuidString.prefix(6).uppercased()
    }

    func sendInvite(userId: UUID, phone: String) async throws -> Referral {
        let referral = Referral(id: UUID(), referrerId: userId, code: try await myReferralCode(userId: userId),
                                 invitedPhone: phone, status: .pending, rewardApplied: false, createdAt: .now)
        referrals.append(referral)
        return referral
    }

    func listReferrals(userId: UUID) async throws -> [Referral] {
        referrals.filter { $0.referrerId == userId }
    }
}

// MARK: - Shared fixture data

enum MockData {
    static let user = User(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        phone: "+919999999999", name: "Aanya Sharma", email: nil, createdAt: .now,
        pets: [Pet(id: UUID(), ownerId: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                   name: "Bruno", species: .dog, breed: "Labrador", dateOfBirth: nil)]
    )

    static let vet = vets[0]

    static let address = Address(
        id: UUID(), ownerId: user.id, label: "Home",
        line1: "14, 5th Cross, Koramangala 5th Block", line2: nil,
        landmark: "Near Forum Mall", accessNotes: "Ring the bell, dog-friendly building",
        latitude: 12.9352, longitude: 77.6146, clusterArea: "Koramangala 5th Block", isDefault: true
    )

    /// A varied roster of vets so the list, ratings, and verification badge
    /// all have something realistic to show while testing.
    static let vets: [Vet] = [
        Vet(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            name: "Dr. Rohan Mehta", licenseNumber: "VCI-2024-11234",
            verificationStatus: .verified, rating: 4.8, reviewCount: 132, photoURL: nil,
            bio: "Small-animal vet with a focus on gentle, at-home care for anxious pets.",
            yearsOfExperience: 9, languages: ["English", "Hindi"], gender: .male,
            speciesHandled: [.dog, .cat]),
        Vet(id: UUID(), name: "Dr. Priya Nair", licenseNumber: "VCI-2023-88213",
            verificationStatus: .verified, rating: 4.9, reviewCount: 211, photoURL: nil,
            bio: "12 years treating dogs and cats across Bangalore, with a special interest in dermatology.",
            yearsOfExperience: 12, languages: ["English", "Hindi", "Kannada"], gender: .female,
            speciesHandled: [.dog, .cat, .bird]),
        Vet(id: UUID(), name: "Dr. Arjun Kapoor", licenseNumber: "VCI-2022-55021",
            verificationStatus: .verified, rating: 4.6, reviewCount: 87, photoURL: nil,
            bio: "General practitioner focused on preventive care and vaccinations.",
            yearsOfExperience: 6, languages: ["English", "Hindi"], gender: .male,
            speciesHandled: [.dog, .cat, .other]),
        Vet(id: UUID(), name: "Dr. Sneha Reddy", licenseNumber: "VCI-2024-90344",
            verificationStatus: .verified, rating: 4.7, reviewCount: 156, photoURL: nil,
            bio: "Passionate about grooming and dental care for dogs of all breeds.",
            yearsOfExperience: 7, languages: ["English", "Telugu", "Kannada"], gender: .female,
            speciesHandled: [.dog]),
        Vet(id: UUID(), name: "Dr. Vikram Singh", licenseNumber: "VCI-2021-67789",
            verificationStatus: .pending, rating: 4.3, reviewCount: 29, photoURL: nil,
            bio: "Newly onboarded — verification in progress.",
            yearsOfExperience: 4, languages: ["English", "Hindi"], gender: .male,
            speciesHandled: [.dog, .cat]),
        Vet(id: UUID(), name: "Dr. Meera Iyer", licenseNumber: "VCI-2023-40012",
            verificationStatus: .verified, rating: 5.0, reviewCount: 64, photoURL: nil,
            bio: "Diagnostics specialist — comfortable with everything from blood panels to X-rays at home.",
            yearsOfExperience: 10, languages: ["English", "Tamil"], gender: .female,
            speciesHandled: [.dog, .cat, .bird, .other]),
        Vet(id: UUID(), name: "Dr. Karthik Rao", licenseNumber: "VCI-2020-33456",
            verificationStatus: .verified, rating: 4.5, reviewCount: 198, photoURL: nil,
            bio: "14 years of practice, with a soft spot for senior pet wellness.",
            yearsOfExperience: 14, languages: ["English", "Kannada"], gender: .male,
            speciesHandled: [.dog, .cat]),
    ]

    private static let areas = [
        "Koramangala 5th Block", "Indiranagar 100 Feet Road", "HSR Layout Sector 2",
        "Whitefield", "JP Nagar Phase 6", "Jayanagar 4th Block", "Bellandur",
    ]

    static let circuits: [Circuit] = vets.enumerated().map { index, vet in
        Circuit(
            id: UUID(), vetId: vet.id, vet: vet, clusterArea: areas[index % areas.count],
            schedule: (0..<3).map { offset in
                ScheduleSlot(
                    id: UUID(), dayOfWeek: (offset % 7) + 1,
                    startTime: Calendar.current.date(byAdding: .day, value: offset + index, to: .now) ?? .now,
                    endTime: Calendar.current.date(byAdding: .hour, value: offset + 1, to: .now) ?? .now,
                    capacity: 5, bookedCount: offset == 2 ? 5 : offset
                )
            }
        )
    }

    static let visits: [Visit] = []

    /// K6: a demo visit id a seeded `LabTestReport` attaches to — `visits` is
    /// empty in the mock, so there's no real booked visit to key off; a
    /// preview only needs *a* stable UUID to demonstrate the report flow.
    static let demoLabTestVisitId = UUID(uuidString: "00000000-0000-0000-0000-0000000000aa")!

    static let labTestReports: [LabTestReport] = [
        LabTestReport(
            id: UUID(), visitId: demoLabTestVisitId, petId: user.pets[0].id,
            testName: "Complete blood panel", status: .ready,
            reportFileURL: URL(string: "mock-storage://lab_test_reports/\(demoLabTestVisitId)/cbc.pdf"),
            resultSummary: "All values within normal range.",
            availableAt: Calendar.current.date(byAdding: .day, value: -1, to: .now)
        ),
        LabTestReport(
            id: UUID(), visitId: demoLabTestVisitId, petId: user.pets[0].id,
            testName: "Urinalysis", status: .pending,
            reportFileURL: nil, resultSummary: nil, availableAt: nil
        ),
    ]

    /// The full catalog (plan §D): categories, variants, and add-ons with real
    /// prices — the "multiple options for each thing" the v1 model had no
    /// concept of at all.
    static let services: [Service] = [
        Service(
            id: UUID(), category: .consult, name: "Home consultation",
            summary: "A vet examines your pet at home for any general health concern.",
            whatToPrepare: "Keep any prior reports or medication handy.",
            variants: [
                ServiceVariant(id: UUID(), serviceId: UUID(), name: "Standard 20 min", durationMinutes: 20, priceMinorUnits: 59_900, additionalPetPriceMinorUnits: 29_900),
                ServiceVariant(id: UUID(), serviceId: UUID(), name: "Extended 40 min", durationMinutes: 40, priceMinorUnits: 89_900, additionalPetPriceMinorUnits: 44_900),
                ServiceVariant(id: UUID(), serviceId: UUID(), name: "Follow-up (within 14 days)", durationMinutes: 15, priceMinorUnits: 0, isFollowUp: true),
            ],
            addons: [
                Addon(id: UUID(), name: "Nail trim", priceMinorUnits: 14_900),
                Addon(id: UUID(), name: "Deworming", priceMinorUnits: 24_900),
                Addon(id: UUID(), name: "Blood sample pickup", priceMinorUnits: 39_900),
            ],
            faqs: [
                FAQ(id: UUID(), question: "Do I need to be present for the whole visit?",
                    answer: "Yes — an adult needs to be home to let the vet in and stay with the pet."),
                FAQ(id: UUID(), question: "What if my pet needs a follow-up?",
                    answer: "Follow-ups within 14 days of this visit are free — just book the \"Follow-up\" variant."),
                FAQ(id: UUID(), question: "Can I reschedule after booking?",
                    answer: "Yes, up to 4 hours before the slot without any fee."),
            ]
        ),
        Service(
            id: UUID(), category: .vaccination, name: "Vaccination",
            summary: "Core and non-core vaccines administered at home, with a certificate and next-due reminder.",
            whatToPrepare: "Bring the previous vaccination card if this isn't the first dose.",
            variants: [
                ServiceVariant(id: UUID(), serviceId: UUID(), name: "Single vaccine", durationMinutes: 15, priceMinorUnits: 49_900),
                ServiceVariant(id: UUID(), serviceId: UUID(), name: "Vaccine + wellness check", durationMinutes: 25, priceMinorUnits: 69_900),
            ],
            eligibility: ServiceEligibility(requiresPrescriberVet: true)
        ),
        Service(
            id: UUID(), category: .grooming, name: "Grooming",
            summary: "Bath, brush-out, nail trim and ear cleaning at home.",
            whatToPrepare: "A space with water access makes this faster.",
            variants: [
                ServiceVariant(id: UUID(), serviceId: UUID(), name: "Basic groom", durationMinutes: 45, priceMinorUnits: 79_900, additionalPetPriceMinorUnits: 49_900),
                ServiceVariant(id: UUID(), serviceId: UUID(), name: "Full groom + haircut", durationMinutes: 75, priceMinorUnits: 129_900, additionalPetPriceMinorUnits: 79_900),
            ]
        ),
        Service(
            id: UUID(), category: .diagnostics, name: "Sample pickup & diagnostics",
            summary: "Blood, urine, or stool sample collected at home and sent to a partner lab.",
            whatToPrepare: "Fasting may be required — you'll get instructions after booking.",
            variants: [
                ServiceVariant(id: UUID(), serviceId: UUID(), name: "Basic panel", durationMinutes: 15, priceMinorUnits: 99_900),
                ServiceVariant(id: UUID(), serviceId: UUID(), name: "Comprehensive panel", durationMinutes: 20, priceMinorUnits: 189_900),
            ]
        ),
        Service(
            id: UUID(), category: .deworming, name: "Deworming",
            summary: "Routine deworming dose appropriate to your pet's weight and age.",
            whatToPrepare: nil,
            variants: [
                ServiceVariant(id: UUID(), serviceId: UUID(), name: "Single dose", durationMinutes: 10, priceMinorUnits: 34_900),
            ]
        ),
        Service(
            id: UUID(), category: .dental, name: "Dental check & clean",
            summary: "Oral exam and scale-and-polish for tartar buildup.",
            whatToPrepare: "Sedation-free — your pet stays awake throughout.",
            variants: [
                ServiceVariant(id: UUID(), serviceId: UUID(), name: "Dental check", durationMinutes: 20, priceMinorUnits: 59_900),
                ServiceVariant(id: UUID(), serviceId: UUID(), name: "Scale & polish", durationMinutes: 40, priceMinorUnits: 149_900),
            ],
            eligibility: ServiceEligibility(requiresPrescriberVet: true)
        ),
        // K6: standalone/add-on bookable lab tests, reusing the same
        // catalog/cart/checkout flow as every other service — the resulting
        // visit is what a `LabTestReport` later attaches to.
        Service(
            id: UUID(), category: .labTest, name: "Lab tests",
            summary: "Blood panel or urinalysis, sample collected at home and processed by a partner lab.",
            whatToPrepare: "Fasting may be required for a blood panel — you'll get instructions after booking.",
            variants: [
                ServiceVariant(id: UUID(), serviceId: UUID(), name: "Complete blood panel", durationMinutes: 15, priceMinorUnits: 149_900),
                ServiceVariant(id: UUID(), serviceId: UUID(), name: "Urinalysis", durationMinutes: 10, priceMinorUnits: 79_900),
            ],
            faqs: [
                FAQ(id: UUID(), question: "When will my report be ready?",
                    answer: "Most reports are ready within 24-48 hours; you'll be able to view and share it from the visit's detail page."),
            ]
        ),
        Service(
            id: UUID(), category: .elderCareVisit, name: "Elder care check-in",
            summary: "A nursing/physio check-in visit for elderly family members.",
            whatToPrepare: nil,
            variants: [
                ServiceVariant(id: UUID(), serviceId: UUID(), name: "Standard check-in", durationMinutes: 30, priceMinorUnits: 69_900),
            ]
        ),
        Service(
            id: UUID(), category: .physioSession, name: "Physio session",
            summary: "A rehab/physiotherapy session at home.",
            whatToPrepare: "Wear comfortable clothing.",
            variants: [
                ServiceVariant(id: UUID(), serviceId: UUID(), name: "Single session", durationMinutes: 45, priceMinorUnits: 89_900),
            ]
        ),
    ]

    /// D4: example packages/bundles, priced below buying the included
    /// services separately — `discountMinorUnits(catalog:)` computes and
    /// shows that saving rather than just asserting it.
    static let packages: [Package] = [
        Package(
            id: UUID(), name: "Puppy first-year",
            packageDescription: "4 home consultations + 3 core vaccines through your puppy's first year.",
            items: [
                PackageItem(id: UUID(), serviceId: services[0].id, quantity: 4), // Home consultation
                PackageItem(id: UUID(), serviceId: services[1].id, quantity: 3), // Vaccination
            ],
            priceMinorUnits: 349_900
        ),
        Package(
            id: UUID(), name: "Senior wellness quarterly",
            packageDescription: "Quarterly consultation + diagnostics panel for pets 7 years and older.",
            items: [
                PackageItem(id: UUID(), serviceId: services[0].id, quantity: 1),
                PackageItem(id: UUID(), serviceId: services[3].id, quantity: 1), // Sample pickup & diagnostics
            ],
            priceMinorUnits: 129_900
        ),
        Package(
            id: UUID(), name: "Grooming & deworming combo",
            packageDescription: "A full groom plus a routine deworming dose in one visit.",
            items: [
                PackageItem(id: UUID(), serviceId: services[2].id, quantity: 1), // Grooming
                PackageItem(id: UUID(), serviceId: services[4].id, quantity: 1), // Deworming
            ],
            priceMinorUnits: 99_900
        ),
    ]

    /// C5: sample reviews per vet, used to build the ratings histogram and
    /// review list on the vet detail screen.
    static let reviews: [UUID: [Review]] = {
        var result: [UUID: [Review]] = [:]
        for vet in vets where vet.reviewCount > 0 {
            let ratings = [5, 5, 4, 5, 3, 4, 5, 2, 5, 4]
            result[vet.id] = ratings.enumerated().map { index, rating in
                Review(id: UUID(), visitId: UUID(), vetId: vet.id, userId: UUID(), rating: rating,
                       comment: index % 3 == 0 ? "Very gentle with my dog, on time too." : nil,
                       createdAt: Calendar.current.date(byAdding: .day, value: -index * 3, to: .now) ?? .now)
            }
        }
        return result
    }()

    /// C11: a handful of real, well-known Bangalore 24x7 emergency clinics —
    /// illustrative examples for the mock, not a claim of a live partnership.
    static let emergencyClinics: [EmergencyClinic] = [
        EmergencyClinic(id: UUID(), name: "CARE Veterinary Emergency & Referral Hospital",
                         address: "80 Feet Road, Indiranagar, Bangalore", phone: "+918041234567",
                         latitude: 12.9719, longitude: 77.6412, isOpen24x7: true),
        EmergencyClinic(id: UUID(), name: "Cessna Lifeline Veterinary Hospital",
                         address: "Sarjapur Road, Bellandur, Bangalore", phone: "+918049876543",
                         latitude: 12.9260, longitude: 77.6762, isOpen24x7: true),
        EmergencyClinic(id: UUID(), name: "Vet Care Corner 24x7 Clinic",
                         address: "Koramangala 5th Block, Bangalore", phone: "+918022334455",
                         latitude: 12.9352, longitude: 77.6146, isOpen24x7: true),
    ]
}

actor MockNotificationPreferencesRepository: NotificationPreferencesRepository {
    private var stored: [UUID: NotificationPreferences] = [:]

    func preferences(userId: UUID) async throws -> NotificationPreferences {
        stored[userId] ?? NotificationPreferences(userId: userId)
    }

    func save(_ preferences: NotificationPreferences) async throws -> NotificationPreferences {
        stored[preferences.userId] = preferences
        return preferences
    }
}

actor MockAppConfigRepository: AppConfigRepository {
    var config = RemoteAppConfig(minSupportedVersion: "1.0", isMaintenanceMode: false, maintenanceMessage: nil)

    func fetchConfig() async throws -> RemoteAppConfig { config }
}

// MARK: - Help centre, support & notification centre (plan §M, §J7)

actor MockHelpRepository: HelpRepository {
    /// ~8-10 realistic entries covering booking/cancellation/payment/pets —
    /// enough to make search and category grouping in `HelpCenterView`
    /// meaningful without a backend.
    private let articles: [HelpArticle] = [
        HelpArticle(id: UUID(), category: .booking, question: "How do I book a visit?",
                    answer: "Pick your address, choose a service and pet, then a slot from your circuit vet's schedule. You'll see the full price before you pay."),
        HelpArticle(id: UUID(), category: .booking, question: "Can I book for more than one pet in the same visit?",
                    answer: "Yes — add each pet on the service screen. The second pet onward is priced at a reduced additional-pet fee, shown in the breakdown."),
        HelpArticle(id: UUID(), category: .cancellation, question: "What's the cancellation policy?",
                    answer: "Cancel more than 4 hours before your slot for a full refund. Inside 4 hours, 50% is refunded. A no-show is charged in full — the vet has already blocked that slot for you."),
        HelpArticle(id: UUID(), category: .cancellation, question: "How do I reschedule instead of cancelling?",
                    answer: "Open the visit from the Visits tab and tap \"Reschedule this visit\" — you keep the same booking and chat history, just a new slot."),
        HelpArticle(id: UUID(), category: .payment, question: "How long do refunds take?",
                    answer: "Refunds are issued to your original payment method and typically reflect in 5-7 business days, depending on your bank/UPI app."),
        HelpArticle(id: UUID(), category: .payment, question: "Can I pay the vet in cash or UPI at the visit?",
                    answer: "Where available for your circuit, yes — choose \"Pay after visit\" at checkout instead of paying online."),
        HelpArticle(id: UUID(), category: .payment, question: "Where can I find my invoice?",
                    answer: "Every completed visit has a GST invoice attached in Visits → Visit detail."),
        HelpArticle(id: UUID(), category: .pets, question: "How do I add or edit a pet's details?",
                    answer: "Go to Profile → Pets to add a pet, or tap a pet to edit its details. Removing a pet keeps its past visit history intact."),
        HelpArticle(id: UUID(), category: .pets, question: "Will I get reminders when a vaccination is due?",
                    answer: "Yes, once your vet logs a vaccination during a visit, we schedule a reminder ahead of its next-due date."),
        HelpArticle(id: UUID(), category: .visits, question: "What is the code my vet asks me to read out?",
                    answer: "That's your start-of-visit OTP — reading it to the vet confirms the visit actually started. It's shown only to you, once, when the vet arrives."),
        HelpArticle(id: UUID(), category: .account, question: "How do I delete my account and data?",
                    answer: "Profile → Privacy & consent → Delete account. There's a 30-day window to change your mind before it's permanently purged (financial records are retained as required by law)."),
    ]

    func listArticles() async throws -> [HelpArticle] { articles }
}

actor MockSupportRepository: SupportRepository {
    private var tickets: [SupportTicket] = []

    func createTicket(userId: UUID, visitId: UUID?, subject: String, body: String) async throws -> SupportTicket {
        let ticket = SupportTicket(id: UUID(), userId: userId, visitId: visitId, subject: subject, body: body, status: .open, createdAt: .now)
        tickets.append(ticket)
        return ticket
    }

    func myTickets(userId: UUID) async throws -> [SupportTicket] {
        tickets.filter { $0.userId == userId }.sorted { $0.createdAt > $1.createdAt }
    }
}

actor MockAppNotificationRepository: AppNotificationRepository {
    private var stored: [AppNotification] = []
    private var seeded = false

    private func seedIfNeeded(userId: UUID) {
        guard !seeded else { return }
        seeded = true
        stored = [
            AppNotification(id: UUID(), userId: userId, category: .bookingUpdate, title: "Visit confirmed",
                             body: "Your vet visit is confirmed for this week.", sentAt: .now.addingTimeInterval(-3600 * 26), createdAt: .now.addingTimeInterval(-3600 * 26), readAt: .now.addingTimeInterval(-3600 * 25)),
            AppNotification(id: UUID(), userId: userId, category: .vaccinationDue, title: "Vaccination due soon",
                             body: "Bruno's next vaccination is due in 7 days — book a slot to stay on schedule.", sentAt: .now.addingTimeInterval(-3600 * 3), createdAt: .now.addingTimeInterval(-3600 * 3), readAt: nil),
        ]
    }

    func notifications(userId: UUID) async throws -> [AppNotification] {
        seedIfNeeded(userId: userId)
        return stored.filter { $0.userId == userId }.sorted { $0.createdAt > $1.createdAt }
    }

    func markRead(id: UUID) async throws {
        guard let index = stored.firstIndex(where: { $0.id == id }) else { return }
        stored[index].readAt = .now
    }

    /// N3: the seeded vaccination-due row above has `sentAt` already set, so
    /// nothing drains by default — set a row's `sentAt` to nil in a test to
    /// exercise `DrainLifecycleNotificationQueueUseCase`.
    func unsentNotifications(userId: UUID) async throws -> [AppNotification] {
        seedIfNeeded(userId: userId)
        return stored.filter { $0.userId == userId && $0.sentAt == nil }.sorted { $0.createdAt < $1.createdAt }
    }

    func markSent(id: UUID) async throws {
        guard let index = stored.firstIndex(where: { $0.id == id }) else { return }
        stored[index].sentAt = .now
    }
}

// MARK: - A9 household

actor MockHouseholdRepository: HouseholdRepository {
    private var households: [Household] = []
    private var membersByHousehold: [UUID: [HouseholdMember]] = [:]

    func myHousehold(userId: UUID) async throws -> Household? {
        households.first { household in
            (membersByHousehold[household.id] ?? []).contains { $0.userId == userId }
        }
    }

    func createHousehold(name: String, ownerId: UUID) async throws -> Household {
        let household = Household(id: UUID(), name: name, ownerId: ownerId, createdAt: .now)
        households.append(household)
        membersByHousehold[household.id] = [
            HouseholdMember(id: UUID(), householdId: household.id, userId: ownerId, role: .owner, invitedPhone: nil, joinedAt: .now)
        ]
        return household
    }

    func members(householdId: UUID) async throws -> [HouseholdMember] {
        membersByHousehold[householdId] ?? []
    }

    func invite(householdId: UUID, phone: String) async throws -> HouseholdMember {
        // Mock stand-in for "not yet a user" — a real invite resolves to a
        // user row once the invitee signs up with this phone number.
        let member = HouseholdMember(id: UUID(), householdId: householdId, userId: UUID(), role: .member, invitedPhone: phone, joinedAt: .now)
        membersByHousehold[householdId, default: []].append(member)
        return member
    }

    func removeMember(householdId: UUID, memberId: UUID) async throws {
        membersByHousehold[householdId]?.removeAll { $0.id == memberId }
    }
}

// MARK: - C10 waitlist

actor MockWaitlistRepository: WaitlistRepository {
    private var entries: [WaitlistEntry] = []

    func join(userId: UUID, addressId: UUID?, latitude: Double, longitude: Double, areaLabel: String?) async throws -> WaitlistEntry {
        // Dedup by (user, address) — matches the DB's unique constraint
        // (0021_waitlist.sql) so tapping "join" twice is a no-op, not two rows.
        if let existing = entries.first(where: { $0.userId == userId && $0.addressId == addressId }) {
            return existing
        }
        let entry = WaitlistEntry(id: UUID(), userId: userId, addressId: addressId, latitude: latitude, longitude: longitude, areaLabel: areaLabel, joinedAt: .now)
        entries.append(entry)
        return entry
    }

    func countNear(latitude: Double, longitude: Double, radiusKm: Double) async throws -> Int {
        let thresholdDegrees = radiusKm / 111.0 // ~111km per degree of latitude, coarse like matchCluster's mock
        return entries.filter {
            abs($0.latitude - latitude) < thresholdDegrees && abs($0.longitude - longitude) < thresholdDegrees
        }.count
    }

    func hasJoined(userId: UUID, addressId: UUID?) async throws -> Bool {
        entries.contains { $0.userId == userId && $0.addressId == addressId }
    }
}

actor MockSubscriptionEntitlementRepository: SubscriptionEntitlementRepository {
    private var entitlements: [UUID: SubscriptionEntitlement] = [:]

    /// Mock stands in for what a real deployment seeds at subscribe time
    /// (a signup edge function creating the row with the plan's monthly
    /// grant) — lazily seeded here on first read so `GetQuoteUseCase` sees a
    /// real credit balance without every test having to call `consumeCredit`
    /// first just to make one exist.
    func currentEntitlement(subscriptionId: UUID) async throws -> SubscriptionEntitlement? {
        seededEntitlement(for: subscriptionId)
    }

    /// Decrements, checking eligibility the same way
    /// `EntitlementPolicy.canApplyCredit` does — the mock is not exempt from
    /// the "server enforces, client only hints" rule its own protocol doc
    /// comment states.
    func consumeCredit(subscriptionId: UUID) async throws -> SubscriptionEntitlement {
        var entitlement = seededEntitlement(for: subscriptionId)
        if EntitlementPolicy.needsReset(entitlement: entitlement, now: .now) {
            entitlement = EntitlementPolicy.rolledForward(entitlement: entitlement, plan: .monthly, seatCount: 1, now: .now)
        }
        guard entitlement.creditsRemaining > 0 else { throw DomainError.validation("No subscription credits remaining this period.") }
        entitlement.creditsRemaining -= 1
        entitlements[subscriptionId] = entitlement
        return entitlement
    }

    private func seededEntitlement(for subscriptionId: UUID) -> SubscriptionEntitlement {
        if let existing = entitlements[subscriptionId] { return existing }
        let fresh = SubscriptionEntitlement(
            id: UUID(), subscriptionId: subscriptionId, creditsRemaining: 1,
            resetAt: Calendar.current.date(byAdding: .month, value: 1, to: .now) ?? .now.addingTimeInterval(30 * 86_400)
        )
        entitlements[subscriptionId] = fresh
        return fresh
    }
}

actor MockIncidentReportRepository: IncidentReportRepository {
    private var reports: [IncidentReport] = []

    func fileReport(_ report: IncidentReport) async throws -> IncidentReport {
        reports.append(report)
        return report
    }

    func myReports(reporterId: UUID) async throws -> [IncidentReport] {
        reports.filter { $0.reporterId == reporterId }
    }
}

// MARK: - D5 per-vet service overrides

actor MockVetServiceOverrideRepository: VetServiceOverrideRepository {
    private var overridesByVet: [UUID: [VetServiceOverride]] = [:]

    func overrides(vetId: UUID) async throws -> [VetServiceOverride] {
        overridesByVet[vetId] ?? []
    }

    func setOverride(_ override: VetServiceOverride) async throws -> VetServiceOverride {
        var list = overridesByVet[override.vetId] ?? []
        if let idx = list.firstIndex(where: { $0.serviceId == override.serviceId && $0.variantId == override.variantId }) {
            list[idx] = override
        } else {
            list.append(override)
        }
        overridesByVet[override.vetId] = list
        return override
    }
}

// MARK: - F5 recurring booking rules

actor MockRecurringBookingRuleRepository: RecurringBookingRuleRepository {
    private var rulesById: [UUID: RecurringBookingRule] = [:]

    func rules(userId: UUID) async throws -> [RecurringBookingRule] {
        rulesById.values.filter { $0.userId == userId }.sorted { $0.nextOccurrenceAt < $1.nextOccurrenceAt }
    }

    func create(_ rule: RecurringBookingRule) async throws -> RecurringBookingRule {
        rulesById[rule.id] = rule
        return rule
    }

    func setActive(id: UUID, isActive: Bool) async throws -> RecurringBookingRule {
        guard var rule = rulesById[id] else { throw DomainError.notFound("Recurring booking rule") }
        rule.isActive = isActive
        rulesById[id] = rule
        return rule
    }

    func delete(id: UUID) async throws {
        rulesById[id] = nil
    }
}

// MARK: - F6 vet-initiated reschedule proposals

actor MockRescheduleProposalRepository: RescheduleProposalRepository {
    private var proposalsById: [UUID: RescheduleProposal] = [:]

    func pendingProposal(visitId: UUID) async throws -> RescheduleProposal? {
        proposalsById.values.first { $0.visitId == visitId && $0.status == .pending }
    }

    func create(_ proposal: RescheduleProposal) async throws -> RescheduleProposal {
        proposalsById[proposal.id] = proposal
        return proposal
    }

    func respond(id: UUID, accept: Bool) async throws -> RescheduleProposal {
        guard var proposal = proposalsById[id] else { throw DomainError.notFound("Reschedule proposal") }
        proposal.status = accept ? .accepted : .declined
        proposalsById[id] = proposal
        return proposal
    }
}
