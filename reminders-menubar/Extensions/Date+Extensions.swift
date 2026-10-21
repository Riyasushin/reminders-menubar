import Foundation

extension Date {
    var isPast: Bool {
        return self.timeIntervalSinceNow < 0
    }
    
    var isToday: Bool {
        return Calendar.current.isDateInToday(self)
    }
    
    var isYesterday: Bool {
        return Calendar.current.isDateInYesterday(self)
    }
    
    var isDayBeforeYesterday: Bool {
        let dayBeforeYesterday = Calendar.current.date(byAdding: .day, value: -2, to: Date()) ?? self
        return self.isSameDay(as: dayBeforeYesterday)
    }
                                                                   
    var isThisYear: Bool {
        return Calendar.current.isDate(self, equalTo: Date(), toGranularity: .year)
    }
    
    var elapsedTimeInterval: TimeInterval {
        return Date().timeIntervalSince(self)
    }
    
    static func nextExactHour(of date: Date = Date(), allowDayChange: Bool = false) -> Date {
        let today = Date()
        let todayNextHour = Calendar.current.date(byAdding: .hour, value: 1, to: today)!
        let isNextHourChangingDay = !todayNextHour.isToday
        
        var hourComponent = Calendar.current.dateComponents([.hour], from: today)
        if allowDayChange || !isNextHourChangingDay {
            hourComponent.hour! += 1
        }
        
        let dateWithoutTime = Calendar.current.date(bySettingHour: 0, minute: 0, second: 0, of: date)!
        return Calendar.current.date(byAdding: hourComponent, to: dateWithoutTime)!
    }
    
    static func nextYear(of date: Date = Date()) -> Date {
        return Calendar.current.date(byAdding: .year, value: 1, to: date) ?? date
    }
    
    func isSameDay(as otherDate: Date) -> Bool {
        return Calendar.current.isDate(self, inSameDayAs: otherDate)
    }

    func withTime(from timeSource: Date) -> Date {
        let calendar = Calendar.current
        let timeComponents = calendar.dateComponents([.hour, .minute, .second], from: timeSource)
        return calendar.date(
            bySettingHour: timeComponents.hour ?? 0,
            minute: timeComponents.minute ?? 0,
            second: timeComponents.second ?? 0,
            of: self
        ) ?? self
    }
    
    func relativeDateDescription(withTime showTimeDescription: Bool) -> String {
        return dateDescription(withTime: showTimeDescription, relativeFormatting: true)
    }

    func absoluteDateDescription(withTime showTimeDescription: Bool) -> String {
        return dateDescription(withTime: showTimeDescription, relativeFormatting: false)
    }

    private func dateDescription(withTime showTimeDescription: Bool, relativeFormatting: Bool) -> String {
        DateDescriptionCache.string(
            from: self,
            showTime: showTimeDescription,
            relativeFormatting: relativeFormatting,
            locale: rmbTimeFormattedLocale()
        )
    }
    
    func dateComponents(withTime: Bool) -> DateComponents {
        var components: Set<Calendar.Component> = [.calendar, .era, .year, .month, .day]
        if withTime {
            components.formUnion([.timeZone, .hour, .minute, .second])
        }
        return Calendar.current.dateComponents(components, from: self)
    }
}

// DateFormatter is expensive to create and to configure from a locale template.
// Reminder rows call this on every SwiftUI body pass, so formatters are reused.
private enum DateDescriptionCache {
    private struct Key: Hashable {
        let localeIdentifier: String
        let timeZoneIdentifier: String
        let calendarIdentifier: String
        let relativeFormatting: Bool
        let includesTime: Bool
    }

    private struct CachedTimeFormat {
        let format: String?
    }

    private static let lock = NSLock()
    private static var formatters: [Key: DateFormatter] = [:]
    private static var hourMinuteFormats: [String: CachedTimeFormat] = [:]

    static func string(
        from date: Date,
        showTime: Bool,
        relativeFormatting: Bool,
        locale: Locale
    ) -> String {
        let timeZone = TimeZone.current
        let calendar = Calendar.current
        let dateString = lockedString(
            from: date,
            locale: locale,
            timeZone: timeZone,
            calendar: calendar,
            relativeFormatting: relativeFormatting,
            includesTime: false
        )

        guard showTime else {
            return dateString
        }

        let timeString = lockedString(
            from: date,
            locale: locale,
            timeZone: timeZone,
            calendar: calendar,
            relativeFormatting: false,
            includesTime: true
        )
        return "\(dateString), \(timeString)"
    }

    private static func lockedString(
        from date: Date,
        locale: Locale,
        timeZone: TimeZone,
        calendar: Calendar,
        relativeFormatting: Bool,
        includesTime: Bool
    ) -> String {
        lock.lock()
        defer { lock.unlock() }

        let key = Key(
            localeIdentifier: locale.identifier,
            timeZoneIdentifier: timeZone.identifier,
            calendarIdentifier: String(describing: calendar.identifier),
            relativeFormatting: relativeFormatting,
            includesTime: includesTime
        )
        let formatter = formatter(for: key, locale: locale, timeZone: timeZone, calendar: calendar)
        return formatter.string(from: date)
    }

    private static func formatter(
        for key: Key,
        locale: Locale,
        timeZone: TimeZone,
        calendar: Calendar
    ) -> DateFormatter {
        if let formatter = formatters[key] {
            return formatter
        }

        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.calendar = calendar

        if key.includesTime {
            formatter.dateStyle = .none
            formatter.timeStyle = .none
            formatter.doesRelativeDateFormatting = false
            // NOTE: "jm" adapts hour format (12h/24h) to the locale's hour cycle preference.
            formatter.dateFormat = hourMinuteFormat(for: locale)
        } else {
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            formatter.doesRelativeDateFormatting = key.relativeFormatting
        }

        formatters[key] = formatter
        return formatter
    }

    private static func hourMinuteFormat(for locale: Locale) -> String? {
        if let cached = hourMinuteFormats[locale.identifier] {
            return cached.format
        }

        let format = DateFormatter.dateFormat(fromTemplate: "jm", options: 0, locale: locale)
        hourMinuteFormats[locale.identifier] = CachedTimeFormat(format: format)
        return format
    }
}
