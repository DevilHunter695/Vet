import Testing
import Foundation
@testable import VetCircuit

// L6: pure-domain moderation policy tests — no UI or network spun up,
// mirroring the PricingEngine/BusinessHoursPolicy test style.

@Suite("ReviewModerationPolicy")
struct ReviewModerationPolicyTests {
    @Test("clean text passes through untouched")
    func cleanTextPasses() throws {
        let result = try ReviewModerationPolicy.moderate("The vet was punctual, gentle with my dog, and explained everything clearly.")
        #expect(result.text == "The vet was punctual, gentle with my dog, and explained everything clearly.")
        #expect(result.needsModeration == false)
        #expect(result.moderationFlags.isEmpty)
    }

    @Test("profanity throws and blocks submission")
    func profanityBlocks() {
        #expect(throws: ReviewModerationPolicy.Violation.profanity) {
            _ = try ReviewModerationPolicy.moderate("This vet is a fucking joke, avoid at all costs.")
        }
    }

    @Test("profanity check is case-insensitive and token-based")
    func profanityCaseInsensitive() {
        #expect(throws: ReviewModerationPolicy.Violation.profanity) {
            _ = try ReviewModerationPolicy.moderate("Total BULLSHIT service, never again.")
        }
        // Not a false positive on a substring that merely contains a word-list entry.
        #expect(throws: Never.self) {
            _ = try ReviewModerationPolicy.moderate("The assistant was helpful.") // contains "ass" as substring only
        }
    }

    @Test("email is redacted and flags PII")
    func emailRedacted() throws {
        let result = try ReviewModerationPolicy.moderate("Great visit! Reach the vet directly at drpatel@example.com for follow-ups.")
        #expect(!result.text.contains("drpatel@example.com"))
        #expect(result.text.contains("[redacted-email]"))
        #expect(result.needsModeration == true)
        #expect(result.moderationFlags.contains("pii_email"))
    }

    @Test("phone number is redacted and flags PII")
    func phoneRedacted() throws {
        let result = try ReviewModerationPolicy.moderate("Call the vet on 9876543210 if you need a repeat visit.")
        #expect(!result.text.contains("9876543210"))
        #expect(result.text.contains("[redacted-phone]"))
        #expect(result.needsModeration == true)
        #expect(result.moderationFlags.contains("pii_phone"))
    }

    @Test("address-like text is redacted and flags PII")
    func addressRedacted() throws {
        let result = try ReviewModerationPolicy.moderate("The vet operates out of 42 MG Road, and the clinic pin code is 560001.")
        #expect(result.needsModeration == true)
        #expect(result.moderationFlags.contains("pii_address"))
        #expect(!result.text.contains("560001") || result.text.contains("[redacted-address]"))
    }

    @Test("defamation-risk language is flagged but not blocked")
    func defamationFlaggedNotBlocked() throws {
        let result = try ReviewModerationPolicy.moderate("Dr. Sharma scammed me and stole my money for a service never rendered.")
        #expect(result.needsModeration == true)
        #expect(result.moderationFlags.contains("defamation_risk"))
        // Crucially: the text itself is preserved, not blocked/thrown.
        #expect(result.text.contains("scammed me"))
    }

    @Test("legitimate negative review without defamation phrasing is not flagged")
    func honestNegativeReviewNotFlagged() throws {
        let result = try ReviewModerationPolicy.moderate("Disappointed — the vet arrived an hour late and seemed rushed.")
        #expect(result.needsModeration == false)
        #expect(result.moderationFlags.isEmpty)
    }
}

@Suite("SubmitReviewUseCase moderation integration")
struct SubmitReviewUseCaseModerationTests {
    @Test("profanity in the comment rejects the submission with a validation error")
    func profanityRejected() async {
        let repo = MockReviewRepository()
        let useCase = SubmitReviewUseCase(reviewRepository: repo)
        await #expect(throws: DomainError.self) {
            _ = try await useCase.execute(visitId: UUID(), rating: 1, comment: "Absolute shit service.")
        }
    }

    @Test("PII in the comment is redacted before it reaches the repository")
    func piiRedactedBeforePersist() async throws {
        let repo = MockReviewRepository()
        let useCase = SubmitReviewUseCase(reviewRepository: repo)
        let review = try await useCase.execute(visitId: UUID(), rating: 5, comment: "Loved it, email me at owner@example.com")
        #expect(review.comment?.contains("owner@example.com") == false)
        #expect(review.needsModeration == true)
    }

    @Test("clean comment passes through with no moderation flags")
    func cleanCommentPasses() async throws {
        let repo = MockReviewRepository()
        let useCase = SubmitReviewUseCase(reviewRepository: repo)
        let review = try await useCase.execute(visitId: UUID(), rating: 5, comment: "Wonderful, caring vet.")
        #expect(review.needsModeration == false)
        #expect(review.moderationFlags.isEmpty)
    }
}
