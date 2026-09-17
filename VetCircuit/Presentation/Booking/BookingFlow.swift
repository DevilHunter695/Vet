import SwiftUI

// MARK: - What to ask, and when
//
// Booking used to be one screen that asked everything at once: which vet,
// which pet, which slot, whether to repeat it, how to pay, what it costs, and
// a liability waiver — stacked vertically, all visible before a single
// decision had been made. Every question was equally prominent, so none of
// them read as the next thing to do, and the price sat at "—" for most of the
// time the screen was open.
//
// The order here follows one rule: **ask the most constraining question
// first, and never ask a question whose answer you already have.**
//
//  1. **When.** The slot is the scarce, time-sensitive resource — it is what
//     the customer is really shopping for, and it is the thing that can be
//     taken by somebody else while they deliberate. Asking it first is also
//     what lets the hold (E7) start early instead of after three other
//     answers have been collected.
//  2. **Who for.** One tap, and frequently answerable without asking: an
//     account with a single pet has no question here, so the step is skipped
//     rather than shown with one option pre-selected. A question with one
//     possible answer is not a question.
//  3. **Confirm.** Price, payment method, recurrence and the waiver, together,
//     at the one moment the total is actually knowable. Showing a breakdown
//     before a slot exists means showing a placeholder.
//
// Recurrence deliberately lives in the last step rather than getting one of
// its own: it is an *option* on a booking, not a question that must be
// answered to make one.

enum BookingStep: Int, CaseIterable, Comparable {
    case slot
    case pet
    case confirm

    static func < (lhs: BookingStep, rhs: BookingStep) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .slot: return "When works for you?"
        case .pet: return "Who's this for?"
        case .confirm: return "Confirm your visit"
        }
    }

    var subtitle: String {
        switch self {
        case .slot: return "Pick a time and we'll hold it while you finish."
        case .pet: return "Their record goes to the vet before the visit."
        case .confirm: return "Nothing is charged until you tap confirm."
        }
    }

    var advanceTitle: String {
        switch self {
        case .slot, .pet: return "Continue"
        case .confirm: return "Confirm booking"
        }
    }
}

/// Where the flow can go from here, given what the customer has answered.
///
/// Kept as a pure function of the answers rather than as mutable state, so
/// "can I continue" and "what is the next step" can never disagree — the bug
/// that shape of state usually produces is a Continue button that is enabled
/// onto a step that then has nothing to show.
struct BookingFlowPlan {
    let hasMultiplePets: Bool

    func steps() -> [BookingStep] {
        hasMultiplePets ? BookingStep.allCases : [.slot, .confirm]
    }

    func next(after step: BookingStep) -> BookingStep? {
        let steps = steps()
        guard let index = steps.firstIndex(of: step), index + 1 < steps.count else { return nil }
        return steps[index + 1]
    }

    func previous(before step: BookingStep) -> BookingStep? {
        let steps = steps()
        guard let index = steps.firstIndex(of: step), index > 0 else { return nil }
        return steps[index - 1]
    }
}

/// A row of segments, one per step, filling as the customer advances.
///
/// Not a numeric "Step 2 of 3": the count is only meaningful if it is stable,
/// and this flow's length legitimately depends on how many pets the account
/// has. Segments show progress without ever claiming a total that changes.
struct BookingProgressBar: View {
    let steps: [BookingStep]
    let current: BookingStep

    var body: some View {
        HStack(spacing: 6) {
            ForEach(steps, id: \.self) { step in
                Capsule(style: .continuous)
                    .fill(step <= current ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.white.opacity(0.12)))
                    .frame(height: 3)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 1.0), value: current)
        .accessibilityElement()
        .accessibilityLabel("Step \((steps.firstIndex(of: current) ?? 0) + 1) of \(steps.count)")
    }
}

extension AnyTransition {
    /// Forward moves in from the trailing edge and leaves to the leading one;
    /// back is its mirror. Enter and exit along the same path, so the flow has
    /// a direction the customer can feel rather than just infer.
    static func bookingStep(isAdvancing: Bool) -> AnyTransition {
        .asymmetric(
            insertion: .move(edge: isAdvancing ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: isAdvancing ? .leading : .trailing).combined(with: .opacity)
        )
    }
}
