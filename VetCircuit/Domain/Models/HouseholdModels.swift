import Foundation

// MARK: - Household sharing (plan §3 A9) — invite a spouse/family member to
// see and book for the same pets.
//
// Modeling decision: `Pet.ownerId` stays exactly as-is; a pet's identity and
// billing owner never change. Household membership grants *visibility* only,
// enforced by an additional Postgres RLS policy (see migration
// 0020_households.sql) that lets any member read pets owned by a fellow
// member — reassigning pet ownership to a household id would ripple through
// every existing owner_id check (visits, cart, addresses) for no real gain.

struct Household: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    var ownerId: UUID
    var createdAt: Date
}

struct HouseholdMember: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var householdId: UUID
    var userId: UUID
    var role: Role
    /// Set until the invitee's own user row exists / they open the app —
    /// mirrors how `Referral.invitedPhone` tracks a not-yet-joined invite.
    var invitedPhone: String?
    var joinedAt: Date

    enum Role: String, Codable {
        case owner, member
    }
}

// MARK: - H7: corporate/RWA seat assignment. `Subscription.seatCount` is
// just the billed quantity; this is *who* fills each seat — mirrors
// `HouseholdMember`'s "invite by phone, joins later" shape, since assigning
// a seat is conceptually the same "grant this phone number access" action.
struct CorporateSeatAssignment: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var subscriptionId: UUID
    /// Set until the assignee's own user row exists, exactly like
    /// `HouseholdMember.invitedPhone`.
    var assignedPhone: String
    var assignedUserId: UUID?
    var assignedAt: Date
}

// MARK: - Waitlist for uncovered clusters (plan §3 C10)

struct WaitlistEntry: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var userId: UUID
    var addressId: UUID?
    var latitude: Double
    var longitude: Double
    var areaLabel: String?
    var joinedAt: Date
}
