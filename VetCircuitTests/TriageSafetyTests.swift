import Testing
import Foundation
@testable import VetCircuit

// The symptom checker must never convert "we don't know" into "you're fine".
//
// It previously defaulted to .selfCare for anything its keyword lists did not
// recognise, so "dog not moving since 4 days" — which matched nothing — was
// answered with "This doesn't sound urgent. Keep an eye on your pet." That is
// the worst possible failure for this screen: a frightened owner is unusually
// likely to believe reassurance, and a dog that has not moved in four days
// needs a vet, not monitoring.

@Suite("Triage safety")
struct TriageSafetyTests {
    private func assess(_ symptoms: String) async throws -> TriageResult {
        try await MockTriageRepository().assess(species: .dog, symptoms: symptoms)
    }

    @Test("the reported case: a dog not moving for days is never called routine")
    func notMovingForDaysIsNotSelfCare() async throws {
        let result = try await assess("Dog not moving since 4 days")
        #expect(result.recommendation == .bookVisitUrgently)
        #expect(result.recommendation != .selfCare)
    }

    @Test("an unrecognised description defaults to being seen, not to reassurance")
    func unknownDefaultsToBookVisit() async throws {
        let result = try await assess("he keeps doing the thing with his paw again")
        #expect(result.recommendation != .selfCare, "unknown must not read as fine")
        #expect(result.recommendation == .bookVisit)
        #expect(
            result.message.lowercased().contains("couldn't judge"),
            "the message has to admit it could not tell"
        )
    }

    @Test("plain-language emergencies are caught, not just clinical words")
    func plainLanguageEmergencies() async throws {
        for phrase in [
            "my dog collapsed", "she won't get up", "he can't stand",
            "there is blood", "not breathing properly", "stomach looks bloated",
            "he ate chocolate", "hit by a car",
        ] {
            let result = try await assess(phrase)
            #expect(
                result.recommendation == .bookVisitUrgently,
                "\(phrase) should be urgent, got \(result.recommendation)"
            )
        }
    }

    @Test("something lasting days escalates even when the symptom alone is moderate")
    func durationEscalates() async throws {
        let short = try await assess("not eating")
        let long = try await assess("not eating for 5 days")
        #expect(short.recommendation == .bookVisit)
        #expect(long.recommendation == .bookVisitUrgently)
    }

    @Test("'today' and 'yesterday' are not long durations")
    func recentIsNotLong() {
        #expect(TriageDurationHeuristic.suggestsDaysOrLonger("started today") == false)
        #expect(TriageDurationHeuristic.suggestsDaysOrLonger("since yesterday") == false)
        #expect(TriageDurationHeuristic.suggestsDaysOrLonger("for 3 days"))
        #expect(TriageDurationHeuristic.suggestsDaysOrLonger("about a week now"))
    }

    @Test("genuinely routine requests stay routine")
    func routineStaysRoutine() async throws {
        let result = try await assess("just need a nail trim")
        #expect(result.recommendation == .selfCare)
    }

    @Test("an empty description is refused rather than guessed at")
    func emptyIsRefused() async {
        let useCase = RunTriageUseCase(triageRepository: MockTriageRepository())
        await #expect(throws: DomainError.self) {
            _ = try await useCase.execute(species: .dog, symptoms: "   ")
        }
    }
}
