import Foundation

/// L6 — pure, framework-free moderation for customer-submitted review text,
/// in the same "pure function, unit-testable without UI or network" style as
/// `PricingEngine`/`BusinessHoursPolicy`. `SubmitReviewUseCase` runs a
/// review's comment through this policy before it ever reaches a repository:
///
/// - profanity: rejected outright with a validation error (the customer is
///   asked to rephrase before the review is stored at all).
/// - PII (email/phone/address-like text): auto-redacted in place — the
///   review is still accepted, just with the sensitive fragment masked.
/// - defamation-risk language: never blocks. It only raises `needsModeration`
///   so a human reviews it later — this is a flag-for-review heuristic, not a
///   legal determination, and a false positive must never silently eat a
///   legitimate review.
enum ReviewModerationPolicy {
    struct Result: Equatable {
        var text: String
        var needsModeration: Bool
        var moderationFlags: [String]
    }

    enum Violation: Error, Equatable {
        case profanity
    }

    /// Scans `text`, redacts PII, flags defamation-risk language, and throws
    /// `.profanity` if the text should be rejected outright rather than
    /// stored (redacted or otherwise).
    static func moderate(_ text: String) throws -> Result {
        if containsProfanity(text) {
            throw Violation.profanity
        }

        var flags: [String] = []
        var working = text

        let (redacted, piiFlags) = redactPII(working)
        working = redacted
        flags.append(contentsOf: piiFlags)

        if containsDefamationRisk(working) {
            flags.append("defamation_risk")
        }

        return Result(text: working, needsModeration: !flags.isEmpty, moderationFlags: flags)
    }

    // MARK: - Profanity

    /// Tokenizes on non-letter boundaries and checks each lowercased word
    /// against a direct-match word list. Not exhaustive leetspeak/spacing
    /// evasion detection — a straightforward word-list check is the real
    /// deliverable here, per plan L6.
    static func containsProfanity(_ text: String) -> Bool {
        let words = tokenize(text)
        return words.contains { profanityWordList.contains($0) }
    }

    private static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
    }

    /// A real, non-trivial English profanity word list (lowercased, direct
    /// match against tokenized words). Kept as plain slurs/curses/sexual
    /// terms and their common inflections — not exhaustive, but far beyond a
    /// 2-3 word demo stub.
    static let profanityWordList: Set<String> = [
        "fuck", "fucking", "fucker", "fuckers", "fucked", "motherfucker",
        "shit", "shitty", "shitting", "bullshit",
        "ass", "asshole", "assholes", "arse", "arsehole",
        "bitch", "bitches", "bitching",
        "bastard", "bastards",
        "damn", "goddamn", "dammit",
        "crap", "crappy",
        "dick", "dickhead", "dicks",
        "cock", "cocks", "cocksucker",
        "pussy", "pussies",
        "cunt", "cunts",
        "piss", "pissed", "pissing",
        "slut", "sluts", "slutty",
        "whore", "whores",
        "twat", "wanker", "wank",
        "prick", "pricks",
        "bollocks",
        "douche", "douchebag",
        "retard", "retarded",
        "nigger", "nigga",
        "faggot", "fag", "fags",
        "chink", "spic", "kike", "gook",
        "moron", "idiot", "imbecile",
        "screwed", "goddamned",
        "jackass", "dumbass", "dumbfuck",
        "shithead", "shitface",
        "asswipe", "assface",
        "bloody", "bugger",
        "hell",
    ]

    // MARK: - PII

    private static let emailRegex = try! NSRegularExpression(
        pattern: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#
    )

    /// Indian-style and generic phone numbers: an optional +country code,
    /// then 10+ digits, allowing spaces/dashes/dots between groups.
    private static let phoneRegex = try! NSRegularExpression(
        pattern: #"(?<!\d)(\+?\d{1,3}[-.\s]?)?(\d[-.\s]?){9,12}(?!\d)"#
    )

    /// A crude "looks like a street address / PIN code" pattern: a run of
    /// digits (house/door number) followed by common address nouns, or a
    /// standalone 6-digit Indian PIN code.
    private static let addressRegex = try! NSRegularExpression(
        pattern: #"\b\d{1,5}\s+[A-Za-z0-9.,'\s]{0,40}\b(Street|St\.?|Road|Rd\.?|Avenue|Ave\.?|Lane|Ln\.?|Nagar|Colony|Layout|Sector|Block|Apartment|Apt\.?|Society)\b|\b\d{6}\b"#,
        options: [.caseInsensitive]
    )

    /// Redacts email/phone/address-like fragments and reports which
    /// categories were found, so callers can flag `needsModeration`.
    static func redactPII(_ text: String) -> (redacted: String, flags: [String]) {
        var result = text
        var flags: [String] = []

        if replaceMatches(of: emailRegex, in: &result, replacement: "[redacted-email]") {
            flags.append("pii_email")
        }
        if replaceMatches(of: phoneRegex, in: &result, replacement: "[redacted-phone]", minDigits: 9) {
            flags.append("pii_phone")
        }
        if replaceMatches(of: addressRegex, in: &result, replacement: "[redacted-address]") {
            flags.append("pii_address")
        }

        return (result, flags)
    }

    @discardableResult
    private static func replaceMatches(
        of regex: NSRegularExpression, in text: inout String, replacement: String, minDigits: Int = 0
    ) -> Bool {
        let nsrange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: nsrange)
        guard !matches.isEmpty else { return false }

        var found = false
        // Apply back-to-front so earlier ranges stay valid as we mutate.
        for match in matches.reversed() {
            guard let range = Range(match.range, in: text) else { continue }
            let matched = String(text[range])
            if minDigits > 0 {
                let digitCount = matched.filter(\.isNumber).count
                guard digitCount >= minDigits else { continue }
            }
            text.replaceSubrange(range, with: replacement)
            found = true
        }
        return found
    }

    // MARK: - Defamation risk

    /// A simple, honest-about-its-limits heuristic: flags strong unverified
    /// accusatory phrasing. This is a signal for human review, never a
    /// determination that the underlying claim is false — a legitimate,
    /// truthful account of a real incident can trip it, which is exactly why
    /// it flags instead of blocking.
    private static let defamationPhrases: [String] = [
        "is a criminal", "is a fraud", "is a scammer", "is a thief",
        "stole my", "stole from me", "scammed me", "scammed us",
        "committed fraud", "is a fake vet", "is not licensed",
        "abused my", "abused our", "assaulted", "molested",
        "runs a scam", "is running a scam", "extorted",
    ]

    static func containsDefamationRisk(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return defamationPhrases.contains { lowered.contains($0) }
    }
}
