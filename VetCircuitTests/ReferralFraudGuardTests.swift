import Testing
import Foundation
@testable import VetCircuit

// N1: pure fraud-guard policy tests.

@Suite("ReferralFraudGuard")
struct ReferralFraudGuardTests {
    @Test("a clean invite passes")
    func cleanInvitePasses() throws {
        try ReferralFraudGuard.validate(invitePhone: "9876543210", referrerPhone: "9123456780", existingReferrals: [])
    }

    @Test("inviting your own number is blocked")
    func selfReferralBlocked() {
        #expect(throws: ReferralFraudGuard.Violation.selfReferral) {
            try ReferralFraudGuard.validate(invitePhone: "+91 98765 43210", referrerPhone: "9876543210", existingReferrals: [])
        }
    }

    @Test("re-inviting an already-invited number is blocked")
    func duplicateInviteBlocked() {
        let existing = Referral(id: UUID(), referrerId: UUID(), code: "ABC123", invitedPhone: "9876543210", status: .pending, rewardApplied: false, createdAt: .now)
        #expect(throws: ReferralFraudGuard.Violation.alreadyInvited) {
            try ReferralFraudGuard.validate(invitePhone: "9876543210", referrerPhone: nil, existingReferrals: [existing])
        }
    }

    @Test("daily invite cap is enforced")
    func dailyCapEnforced() {
        let today = Date.now
        let existing = (0..<ReferralFraudGuard.maxInvitesPerDay).map { i in
            Referral(id: UUID(), referrerId: UUID(), code: "C\(i)", invitedPhone: "800000000\(i)", status: .pending, rewardApplied: false, createdAt: today)
        }
        #expect(throws: ReferralFraudGuard.Violation.dailyLimitExceeded) {
            try ReferralFraudGuard.validate(invitePhone: "7000000000", referrerPhone: nil, existingReferrals: existing, now: today)
        }
    }
}
