import Foundation
import Testing
@testable import MagnifeKit

@Suite("Formatting")
struct FormatTests {
    @Test("durations", arguments: [
        (0, "0 µs"), (400, "0 µs"), (850_000, "850 µs"), (999_400, "999 µs"), (999_600, "1.0 ms"),
        (1_000_000, "1.0 ms"), (4_560_000, "4.6 ms"), (9_960_000, "10 ms"), (12_000_000, "12 ms"),
        (240_400_000, "240 ms"), (999_600_000, "1.00 s"), (1_240_000_000, "1.24 s"),
        (9_996_000_000, "10.0 s"), (12_440_000_000, "12.4 s"), (59_960_000_000, "1 min"),
        (125_000_000_000, "2 min 5 s"), (3_599_600_000_000, "1 h"), (3_720_000_000_000, "1 h 2 min"),
        (-5, "0 µs"),
    ] as [(Int64, String)])
    func duration(ns: Int64, expected: String) {
        #expect(DurationFormat.string(nanoseconds: ns) == expected)
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test("relative time under an hour")
    func relative() {
        let now = Date(timeIntervalSince1970: 1_762_084_800) // 2025-11-02 12:00 UTC
        func text(_ secondsAgo: TimeInterval) -> String {
            RelativeTime.string(for: now.addingTimeInterval(-secondsAgo), now: now, calendar: utc,
                                locale: Locale(identifier: "en_US_POSIX"))
        }
        #expect(text(-30) == "Just now")
        #expect(text(0) == "Just now")
        #expect(text(4.9) == "Just now")
        #expect(text(12) == "12 s ago")
        #expect(text(60) == "1 min ago")
        #expect(text(150) == "2 min ago")
        #expect(text(3_599) == "59 min ago")
    }

    @Test("clock time after an hour, with the date when not today")
    func clock() {
        let now = Date(timeIntervalSince1970: 1_762_084_800) // 12:00 UTC
        let locale = Locale(identifier: "en_GB")
        let today = RelativeTime.string(for: now.addingTimeInterval(-3_600 - 5), now: now, calendar: utc, locale: locale)
        #expect(today == "10:59:55")
        let yesterday = RelativeTime.string(for: now.addingTimeInterval(-86_400), now: now, calendar: utc, locale: locale)
        #expect(yesterday == "1 Nov, 12:00")
        #expect(!yesterday.contains("ago"))
    }

    @Test("service color slots are stable and spread")
    func serviceColors() {
        // FNV-1a reference values, so the slot never changes between releases.
        #expect(ServiceColor.slot(for: "", slots: Int(UInt32.max)) == Int(0x811C_9DC5 % UInt32.max))
        #expect(ServiceColor.slot(for: "a", slots: Int(UInt32.max)) == Int(UInt32(0xE40C_292C) % UInt32.max))
        #expect(ServiceColor.slot(for: "checkout-api") == ServiceColor.slot(for: "checkout-api"))
        let fixture = ["checkout-api", "orders", "web"].map { ServiceColor.slot(for: $0) }
        #expect(Set(fixture).count == 3)
        let many = Set((0..<200).map { ServiceColor.slot(for: "service-\($0)") })
        #expect(many == Set(0..<ServiceColor.slotCount))
    }
}
