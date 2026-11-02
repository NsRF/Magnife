import Foundation

/// When something happened, for the trace list's Time column: relative under
/// an hour ("Just now", "12 s ago", "2 min ago"), then clock time ("14:05:12"),
/// with the date when it was not today ("Nov 1, 14:05" or "1 Nov, 14:05").
public enum RelativeTime {
    public static func string(for date: Date, now: Date, calendar: Calendar = .current,
                              locale: Locale = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        // A clock a little ahead of ours still reads as now.
        if seconds < 5 { return "Just now" }
        if seconds < 60 { return "\(Int(seconds)) s ago" }
        if seconds < 3_600 { return "\(Int(seconds / 60)) min ago" }
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(style.hour().minute().second())
        }
        // "1 Nov, 22:32": the joined style would add "at" and not fit the column.
        return date.formatted(style.month(.abbreviated).day()) + ", " + date.formatted(style.hour().minute())
    }
}
