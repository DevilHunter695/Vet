import SwiftUI

// MARK: - Date grouping
//
// Luma's list does one thing this app's did not: it puts the *date* in the
// structure instead of inside every row. A column of rows each repeating
// "Thu 18 Sep, 2:00 PM" makes the reader parse the same string twenty times to
// answer "what's happening this week"; a day header answers it once and lets
// every row below it carry only what differs.
//
// The relative labels matter more than they look. "Today" and "Tomorrow" are
// how people actually hold near-future dates in their heads — a visit that is
// tomorrow should say so, not make somebody work out that the 18th is
// tomorrow. Past that horizon, absolute dates are clearer than "in 4 days".

struct VisitDayGroup: Identifiable {
    let id: Date
    let visits: [Visit]

    var date: Date { id }
}

enum VisitGrouping {
    /// Groups by calendar day, newest-first or oldest-first depending on
    /// whether these are upcoming or past visits — upcoming reads forward
    /// from now, history reads backward from now, and in both cases the row
    /// nearest the present is the one people want first.
    static func byDay(_ visits: [Visit], ascending: Bool, calendar: Calendar = .current) -> [VisitDayGroup] {
        let grouped = Dictionary(grouping: visits) { calendar.startOfDay(for: $0.scheduledAt) }
        return grouped
            .map { VisitDayGroup(id: $0.key, visits: $0.value.sorted { ascending ? $0.scheduledAt < $1.scheduledAt : $0.scheduledAt > $1.scheduledAt }) }
            .sorted { ascending ? $0.date < $1.date : $0.date > $1.date }
    }

    /// The big label: "Today", "Tomorrow", "Thu 18 Sep".
    static func dayLabel(for date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return date.formatted(sameYear
            ? .dateTime.weekday(.abbreviated).day().month(.abbreviated)
            : .dateTime.day().month(.abbreviated).year())
    }

    /// The quieter second half: "Thursday" next to "Today", so the weekday is
    /// still available without the headline having to spell it out.
    static func daySublabel(for date: Date, calendar: Calendar = .current) -> String? {
        guard calendar.isDateInToday(date) || calendar.isDateInTomorrow(date) || calendar.isDateInYesterday(date) else { return nil }
        return date.formatted(.dateTime.weekday(.wide))
    }
}

/// The day header itself — a date, a weekday, and a hairline that runs to the
/// edge of the content so the group reads as a band rather than a floating
/// caption.
struct VisitDayHeader: View {
    let date: Date

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(VisitGrouping.dayLabel(for: date))
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .tracking(-0.1)
                .foregroundStyle(Theme.textPrimary)

            if let sublabel = VisitGrouping.daySublabel(for: date) {
                Text(sublabel)
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(Theme.textTertiary)
            }

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
                .frame(maxWidth: .infinity)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
        }
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
    }
}
