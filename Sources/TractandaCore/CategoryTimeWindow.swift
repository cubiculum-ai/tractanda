import Foundation

public enum QueryCalendar {
    public static func make(timeZone: String = "UTC") throws -> Calendar {
        guard let zone = TimeZone(identifier: timeZone) else {
            throw TractandaError("invalidSelection", "Use a named IANA time zone.")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }
    public static var utc: Calendar { try! make() }
}

/// A portable selection extension, not additional Spotlight syntax. Intervals are [start, end).
public struct CategoryTimeWindow: Sendable {
    public let startProperty: String
    public let endProperty: String?
    public let period: String
    public let offset: Int

    public init(_ value: ItemValue) throws {
        guard let fields = value.map, let start = fields["startProperty"]?.string, !start.isEmpty,
            let period = fields["period"]?.string,
            ["day", "week", "month", "quarter", "year", "rollingMonths", "past"].contains(period),
            fields["offset"] == nil || fields["offset"]?.integerValue != nil,
            fields["endProperty"] == nil || fields["endProperty"]?.string?.isEmpty == false
        else { throw TractandaError("invalidSelection", "Invalid time window properties.") }
        let offset = fields["offset"]?.integerValue ?? 0
        guard (-1200...1200).contains(offset), period != "rollingMonths" || (1...120).contains(offset),
            period != "past" || offset == 0
        else { throw TractandaError("invalidSelection", "Invalid time window offset.") }
        startProperty = start
        endProperty = fields["endProperty"]?.string
        self.period = period
        self.offset = Int(offset)
    }

    public func bounds(at date: Date, calendar: Calendar) -> DateInterval? {
        if period == "past" { return nil }
        if period == "rollingMonths" {
            guard let end = calendar.date(byAdding: .month, value: offset, to: date) else { return nil }
            return DateInterval(start: date, end: end)
        }
        let component: Calendar.Component
        switch period {
        case "day": component = .day
        case "week": component = .weekOfYear
        case "month", "quarter": component = .month
        default: component = .year
        }
        var anchor = date
        if period == "quarter" {
            var parts = calendar.dateComponents([.year, .month], from: date)
            parts.month = ((parts.month! - 1) / 3) * 3 + 1
            guard let start = calendar.date(from: parts) else { return nil }
            anchor = start
        }
        let amount = period == "quarter" ? offset * 3 : offset
        guard let shifted = calendar.date(byAdding: component, value: amount, to: anchor),
            let base = calendar.dateInterval(of: component, for: shifted),
            let end = calendar.date(byAdding: component, value: period == "quarter" ? 3 : 1, to: base.start)
        else { return nil }
        return DateInterval(start: base.start, end: end)
    }

    /// Text YYYY-MM-DD is a local calendar date; timestamp values denote instants.
    private func instant(_ value: ItemValue?, calendar: Calendar) -> (date: Date, isDay: Bool)? {
        if case .date(let text) = value, let date = Timestamp.parse(text) { return (date, false) }
        guard let text = value?.string, text.count == 10 else { return nil }
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
            let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
            let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
            calendar.component(.year, from: date) == year,
            calendar.component(.month, from: date) == month, calendar.component(.day, from: date) == day
        else { return nil }
        return (date, true)
    }

    public func matches(_ item: Revision, at date: Date, calendar: Calendar) -> Bool {
        guard let start = instant(item.fields[startProperty], calendar: calendar) else { return false }
        if period == "past" {
            let deadline = start.isDay ? calendar.date(byAdding: .day, value: 1, to: start.date)! : start.date
            return deadline < date || (start.isDay && deadline == date)
        }
        guard let window = bounds(at: date, calendar: calendar) else { return false }
        if let endProperty, let endValue = item.fields[endProperty] {
            guard let end = instant(endValue, calendar: calendar), end.date >= start.date else {
                return false
            }
            if end.date > start.date { return start.date < window.end && end.date > window.start }
        }
        if start.isDay, endProperty != nil {
            let end = calendar.date(byAdding: .day, value: 1, to: start.date)!
            return start.date < window.end && end > window.start
        }
        return start.date >= window.start && start.date < window.end
    }
}
