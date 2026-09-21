import SwiftUI

/// What the customer has already told us, waiting for the booking screen to
/// pick it up.
///
/// The symptom check (`TriageView`) asks "what's going on?", gets a paragraph
/// describing a sick animal, tells the person to book — and then threw that
/// paragraph away. They arrived at the booking screen and were asked the same
/// question again, which is both rude and a good way to get a shorter, worse
/// answer the second time.
///
/// This is deliberately a one-shot handoff rather than persisted state:
/// `consumeReason()` clears it, so the text applies to the next booking
/// started and no later one. It lives at app level because triage and booking
/// are in different navigation stacks and neither owns the other.
@MainActor
@Observable
final class BookingDraft {
    private(set) var reason: String?

    func setReason(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        reason = trimmed.isEmpty ? nil : trimmed
    }

    func consumeReason() -> String? {
        defer { reason = nil }
        return reason
    }

    func clear() { reason = nil }
}
