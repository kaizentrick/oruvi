import Foundation

struct NotchAgendaDates: Equatable {
    let upcoming: DateInterval
    let month: DateInterval

    init?(now: Date, monthOffset: Int, calendar: Calendar) {
        let today = calendar.startOfDay(for: now)
        guard let upcomingEnd = calendar.date(byAdding: .day, value: 31, to: today),
              let currentMonth = calendar.dateInterval(of: .month, for: today),
              let monthDate = calendar.date(byAdding: .month, value: monthOffset, to: currentMonth.start),
              let displayedMonth = calendar.dateInterval(of: .month, for: monthDate),
              displayedMonth.end > today else { return nil }
        upcoming = DateInterval(start: today, end: upcomingEnd)
        month = DateInterval(start: max(today, displayedMonth.start), end: displayedMonth.end)
    }

    var needsSeparateMonthQuery: Bool { month.end > upcoming.end }

    static func overlaps(start: Date, end: Date, range: DateInterval) -> Bool {
        start < range.end && end > range.start
    }
}
