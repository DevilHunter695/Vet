import Foundation

extension Pet {
    /// How an owner would say the pet's age out loud.
    ///
    /// Months up to two years, then years — because "18 mo" is meaningful to
    /// someone with a puppy and "1 yr" is not, while "84 mo" is meaningless to
    /// everyone. `nil` when there is no date of birth, so callers can leave
    /// the age out rather than print a placeholder.
    var ageText: String? {
        guard let dateOfBirth else { return nil }
        let months = Calendar.current.dateComponents([.month], from: dateOfBirth, to: .now).month ?? 0
        if months < 24 { return "\(max(0, months)) mo" }
        return "\(months / 12) yr"
    }
}
