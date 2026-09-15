import SwiftUI

// MARK: - Presentation-side display names for domain enums.
//
// A `rawValue` is a wire format, not copy. Printing it straight into the UI is
// how "Enroute" and "Cancelledbyuser" reached the screen. The domain models
// stay untouched; the words the user reads live here, next to the views that
// read them.

extension Pet.Species {
    var displayName: String {
        switch self {
        case .dog: return "Dog"
        case .cat: return "Cat"
        case .bird: return "Bird"
        case .other: return "Other"
        }
    }

    var symbolName: String {
        switch self {
        case .dog: return "dog.fill"
        case .cat: return "cat.fill"
        case .bird: return "bird.fill"
        case .other: return "pawprint.fill"
        }
    }
}

extension Pet.Sex {
    var displayName: String {
        switch self {
        case .male: return "Male"
        case .female: return "Female"
        case .unknown: return "Not recorded"
        }
    }
}

extension Subscription.Status {
    var displayName: String {
        switch self {
        case .active: return "Active"
        case .cancelled: return "Cancelled"
        case .expired: return "Expired"
        case .pastDue: return "Payment overdue"
        case .paused: return "Paused"
        }
    }

    var tint: Color {
        switch self {
        case .active: return Theme.success
        case .paused: return Theme.warning
        case .pastDue: return Theme.danger
        case .cancelled, .expired: return Theme.neutral
        }
    }

    var symbolName: String {
        switch self {
        case .active: return "checkmark.seal.fill"
        case .paused: return "pause.circle.fill"
        case .pastDue: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle.fill"
        case .expired: return "clock.badge.xmark.fill"
        }
    }
}

extension Referral.Status {
    /// Said from the inviter's point of view — "Pending" tells them nothing
    /// about what they're waiting for.
    var displayName: String {
        switch self {
        case .pending: return "Invite sent"
        case .joined: return "Friend joined"
        case .rewarded: return "Reward applied"
        }
    }

    var detail: String {
        switch self {
        case .pending: return "Waiting for them to sign up"
        case .joined: return "Your reward lands after their first visit"
        case .rewarded: return "Discount added to your account"
        }
    }

    var tint: Color {
        switch self {
        case .pending: return Theme.neutral
        case .joined: return Theme.primary
        case .rewarded: return Theme.success
        }
    }

    var symbolName: String {
        switch self {
        case .pending: return "paperplane.fill"
        case .joined: return "person.fill.checkmark"
        case .rewarded: return "gift.fill"
        }
    }
}
