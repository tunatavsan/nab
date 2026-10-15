import Foundation

/// "Today 17:52", the line under a chat's title.
public enum ChatStamp {
    public static func string(
        for date: Date, now: Date = .now, calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        let day = dayTitle(calendar.startOfDay(for: date), now: now, calendar: calendar, locale: locale)
        let time = date.formatted(
            Date.FormatStyle(
                date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
        return day + " " + time
    }

    private static func dayTitle(_ day: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let today = calendar.startOfDay(for: now)
        if day == today { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), day == yesterday { return "Yesterday" }
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        style = style.weekday(.abbreviated).day().month(.abbreviated)
        return day.formatted(style)
    }
}
