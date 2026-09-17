import Foundation

// Two small policies that were previously inlined next to the system call they
// guard — `LAContext` for A10, `SKStoreReviewController` for N5. Neither system
// call can run in CI, and because the decision about *whether* to make it lived
// in the same function, both features were marked "built, nothing tests it".
//
// The system call still needs a device. The decision does not, and the decision
// is where the behaviour that matters lives: one of these must fail open or it
// locks people out of the app, the other must not nag.

/// A10: whether the biometric gate should stand between the customer and the
/// app right now.
enum BiometricLockPolicy {
    enum Decision: Equatable {
        /// Let them in without prompting.
        case unlock
        /// Prompt for Face ID / Touch ID.
        case challenge
        /// The device cannot satisfy the lock — let them in and say why,
        /// rather than stranding them behind a gate nothing can open.
        case unlockUnavailable(note: String)
    }

    static let unavailableNote = "Face ID isn't set up on this device — app lock is off until it is."

    /// `isAvailable` is the result of `LAContext.canEvaluatePolicy`, passed in
    /// rather than called here so this stays pure and testable. The ordering
    /// matters: the setting is checked *first*, so a device with no enrolled
    /// biometrics and the lock switched off is simply unlocked, with no
    /// misleading note about Face ID the customer never asked for.
    static func decide(isEnabled: Bool, isAvailable: Bool) -> Decision {
        guard isEnabled else { return .unlock }
        guard isAvailable else { return .unlockUnavailable(note: unavailableNote) }
        return .challenge
    }
}

/// N5: when to ask for an App Store rating.
enum AppStoreReviewPromptPolicy {
    /// Only after a 5★ review, and at most once per app version.
    ///
    /// StoreKit does its own throttling, but it will not stop this app
    /// prompting after every single 5★ visit — and a customer who rates three
    /// visits five stars in a month should be thanked, not asked three times.
    /// The version gate is ours, deliberately.
    static func shouldPrompt(rating: Int, currentVersion: String, lastPromptedVersion: String?) -> Bool {
        guard rating == 5 else { return false }
        guard !currentVersion.isEmpty else { return false }
        return lastPromptedVersion != currentVersion
    }
}
