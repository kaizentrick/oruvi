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
        if start == end { return start >= range.start && start < range.end }
        return start < end && start < range.end && end > range.start
    }

    static func coveredDays(start: Date, end: Date, in range: DateInterval, calendar: Calendar) -> [Date] {
        guard overlaps(start: start, end: end, range: range) else { return [] }
        if start == end { return [calendar.startOfDay(for: start)] }
        let limit = min(end, range.end)
        var day = calendar.startOfDay(for: max(start, range.start))
        var result: [Date] = []
        while day < limit {
            result.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            let nextDay = calendar.startOfDay(for: next)
            guard nextDay > day else { break }
            day = nextDay
        }
        return result
    }
}
