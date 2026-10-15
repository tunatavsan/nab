import Foundation
import Testing

@testable import NabCore

@Suite("Chat stamp")
struct ChatStampTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private let locale = Locale(identifier: "en_GB")
    /// Thursday 15 Oct 2026, 15:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_792_076_400)

    private func stamp(_ date: Date) -> String {
        ChatStamp.string(for: date, now: now, calendar: calendar, locale: locale)
    }

    @Test func todayAndYesterdayUseWords() {
        #expect(stamp(now.addingTimeInterval(-3600)) == "Today 14:00")
        #expect(stamp(now.addingTimeInterval(-20 * 3600)) == "Yesterday 19:00")
    }

    @Test func olderDatesShowTheDay() {
        let text = stamp(now.addingTimeInterval(-5 * 86400))
        #expect(text.contains("10"))
        #expect(text.contains("Oct"))
        #expect(text.contains("15:00"))
    }
}
