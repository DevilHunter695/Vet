import Foundation

// MARK: - V3: AI-assisted symptom pre-triage
//
// Routes a free-text description of a pet's symptoms to either a suggested
// booking (a vet should see this) or self-care guidance, before the user
// commits to scheduling a visit. Kept behind a protocol so the on-device
// rule-based fallback can be swapped for a real LLM-backed backend endpoint
// without touching the Presentation layer.

struct TriageResult: Equatable {
    enum Recommendation: Equatable {
        case bookVisitUrgently
        case bookVisit
        case selfCare
    }

    let recommendation: Recommendation
    let message: String
}

protocol TriageRepository: Sendable {
    func assess(species: Pet.Species, symptoms: String) async throws -> TriageResult
}

struct RunTriageUseCase {
    let triageRepository: TriageRepository

    func execute(species: Pet.Species, symptoms: String) async throws -> TriageResult {
        let trimmed = symptoms.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DomainError.validation("Describe what you're noticing so we can help.")
        }
        return try await triageRepository.assess(species: species, symptoms: trimmed)
    }
}

/// Rule-based fallback so pre-triage works with zero backend dependency.
/// Swap for a repository that calls a hosted LLM endpoint (never embed an
/// API key client-side — proxy it through a backend function) once V3 is
/// ready to go live.
actor MockTriageRepository: TriageRepository {
    private let urgentKeywords = ["bleeding", "seizure", "unconscious", "can't breathe", "cannot breathe", "collapsed", "poison"]
    private let moderateKeywords = ["vomiting", "diarrhea", "limping", "not eating", "lethargic", "fever"]

    func assess(species: Pet.Species, symptoms: String) async throws -> TriageResult {
        let lowered = symptoms.lowercased()

        if urgentKeywords.contains(where: lowered.contains) {
            return TriageResult(
                recommendation: .bookVisitUrgently,
                message: "These symptoms need a vet's attention right away. We recommend booking the earliest available slot, or contacting an emergency clinic if one isn't available soon."
            )
        }
        if moderateKeywords.contains(where: lowered.contains) {
            return TriageResult(
                recommendation: .bookVisit,
                message: "This is worth having a vet take a look at. We suggest booking a visit in the next day or two."
            )
        }
        return TriageResult(
            recommendation: .selfCare,
            message: "This doesn't sound urgent. Keep an eye on your pet, and book a visit if things don't improve in a couple of days."
        )
    }
}
