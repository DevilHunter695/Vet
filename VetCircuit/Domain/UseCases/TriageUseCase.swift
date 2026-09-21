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
    /// Signs that need a vet now. Deliberately includes the plain words
    /// people actually type at midnight ("not moving", "won't get up")
    /// rather than clinical terms they don't.
    private let urgentKeywords = [
        "bleeding", "blood", "seizure", "fitting", "unconscious", "unresponsive",
        "can't breathe", "cannot breathe", "not breathing", "struggling to breathe",
        "collapsed", "collapse", "poison", "poisoned", "ate chocolate", "ate rat",
        "not moving", "won't move", "cannot move", "can't move", "won't get up",
        "can't stand", "cannot stand", "won't stand", "paralysed", "paralyzed",
        "bloated", "swollen stomach", "straining", "choking", "hit by",
        "broken", "fracture", "not urinating", "can't urinate"
    ]

    private let moderateKeywords = [
        "vomiting", "vomit", "diarrhea", "diarrhoea", "limping", "not eating",
        "won't eat", "lethargic", "tired", "fever", "itching", "scratching",
        "coughing", "sneezing", "discharge", "lump", "rash", "ear infection"
    ]

    /// Routine, non-clinical reasons to see a vet.
    private let mildKeywords = [
        "nail", "claws", "grooming", "bath", "vaccination", "vaccine",
        "deworming", "checkup", "check up", "routine", "booster"
    ]

    /// Mild same-day observations.
    ///
    /// Checked *after* the urgent and duration branches, which is what makes
    /// this safe: "a little sleepy today" lands here, while "sleepy for four
    /// days" has already been escalated by the duration rule and "sleepy and
    /// there is blood" by the urgent one. Order is the safety property, not
    /// the word list.
    private let mildObservationKeywords = [
        "sleepy", "slept", "quiet", "a little off", "bit off", "not himself",
        "not herself", "clingy", "grumpy"
    ]

    func assess(species: Pet.Species, symptoms: String) async throws -> TriageResult {
        let lowered = symptoms.lowercased()

        if urgentKeywords.contains(where: lowered.contains) {
            return TriageResult(
                recommendation: .bookVisitUrgently,
                message: "These symptoms need a vet's attention right away. Book the earliest slot, or contact an emergency clinic if none is available soon."
            )
        }

        // Something that has gone on for days is not mild, whatever it is.
        // "Not eating" for an afternoon and "not eating for four days" are
        // different animals, and the second one was previously scored the
        // same as the first.
        if TriageDurationHeuristic.suggestsDaysOrLonger(lowered) {
            return TriageResult(
                recommendation: .bookVisitUrgently,
                message: "Something that has lasted this long needs looking at rather than waiting out. Book the earliest slot you can."
            )
        }

        if moderateKeywords.contains(where: lowered.contains) {
            return TriageResult(
                recommendation: .bookVisit,
                message: "This is worth having a vet look at. We suggest booking a visit in the next day or two."
            )
        }

        if mildKeywords.contains(where: lowered.contains) {
            return TriageResult(
                recommendation: .selfCare,
                message: "That sounds routine rather than urgent. Book whenever suits you — there's no rush."
            )
        }

        if mildObservationKeywords.contains(where: lowered.contains) {
            return TriageResult(
                recommendation: .selfCare,
                message: "That doesn't sound urgent on its own. Keep an eye on them, and book a visit if it carries on or anything else changes."
            )
        }

        // The default is NOT "probably fine".
        //
        // It used to be: anything this rule set did not recognise returned
        // "This doesn't sound urgent", so "dog not moving since 4 days"
        // - which matched no keyword - was answered with reassurance. A
        // checker that reassures by default is worse than no checker,
        // because it converts "we don't know" into "you're fine" on the one
        // screen a frightened owner is most likely to believe.
        //
        // Unrecognised means unknown, and unknown errs toward being seen.
        return TriageResult(
            recommendation: .bookVisit,
            message: "We couldn't judge this one from the description — that isn't the same as it being fine. Book a visit and let a vet look, or call us if your pet seems to be getting worse."
        )
    }
}

/// Does the description say this has been going on for days or longer?
///
/// Split out so it can be tested directly, and so the rule is stated once
/// rather than re-derived inside the matcher.
enum TriageDurationHeuristic {
    static func suggestsDaysOrLonger(_ lowered: String) -> Bool {
        let markers = ["days", "day", "week", "weeks", "month", "months"]
        guard markers.contains(where: lowered.contains) else { return false }
        // "today" and "yesterday" contain "day" but describe something
        // recent, so they must not trip the long-duration branch.
        let recent = ["today", "yesterday", "this morning", "tonight", "just now", "a day"]
        if recent.contains(where: lowered.contains),
           !["days", "week", "month"].contains(where: lowered.contains) {
            return false
        }
        return true
    }
}
