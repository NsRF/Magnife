import Foundation
import GRDB
import Testing
@testable import MagnifeKit

/// "Slower than" (S-019): what the field and the `>` token accept.
@Suite("Slower than (S-019)", .serialized)
struct DurationInputTests {
    /// Every way to write 200 ms, and 1.5 s, is the same rule.
    static let same: [(String, Int64)] = [
        (">200ms", 200_000_000), ("200ms", 200_000_000), ("200", 200_000_000), ("200 ms", 200_000_000),
        ("> 200 ms", 200_000_000), (" 200 ", 200_000_000), ("200MS", 200_000_000), ("0.2s", 200_000_000),
        ("200000us", 200_000_000), ("200000µs", 200_000_000),
        (">1.5s", 1_500_000_000), ("1.5s", 1_500_000_000), ("1.5 s", 1_500_000_000), ("1500", 1_500_000_000),
        ("1500ms", 1_500_000_000), (">1500", 1_500_000_000), ("1.5S", 1_500_000_000),
        ("0.5", 500_000), ("850us", 850_000), ("2s", 2_000_000_000), ("12.25ms", 12_250_000), ("1000ns", 1_000),
    ]

    @Test("plain numbers are milliseconds; ms, s, us and µs are units", arguments: same)
    func parses(_ text: String, ns: Int64) {
        #expect(DurationInput.parse(text) == ns)
        #expect(TraceQuery(">" + text.replacingOccurrences(of: ">", with: "").replacingOccurrences(of: " ", with: "")).filter.slowerThanNs == ns)
    }

    static let rejected = ["", " ", ">", "abc", "-5", "+5", "1e3", "1.2.3", ".", "0", "0ms", "200 sec", "200m", "2min",
                           "1,5s", "inf", "nan", "ms", "s", "200 ms ago", "２００"]

    @Test("text that is no duration is rejected", arguments: rejected)
    func rejects(_ text: String) {
        #expect(DurationInput.parse(text) == nil)
    }

    static let normalized: [(Int64, String, String, String)] = [
        (200_000_000, "200 ms", ">200ms", "200 milliseconds"),
        (1_500_000_000, "1.5 s", ">1.5s", "1.5 seconds"),
        (1_000_000_000, "1 s", ">1s", "1 second"),
        (1_250_000_000, "1.25 s", ">1.25s", "1.25 seconds"),
        (850_000, "850 µs", ">850us", "850 microseconds"),
        (12_250_000, "12.25 ms", ">12.25ms", "12.25 milliseconds"),
        (60_000_000_000, "60 s", ">60s", "60 seconds"),
    ]

    @Test("a value reads normalized, and its token parses back", arguments: normalized)
    func normalizes(_ ns: Int64, text: String, token: String, spoken: String) {
        #expect(DurationInput.normalized(ns) == text)
        #expect(DurationInput.token(ns) == token)
        #expect(DurationInput.spoken(ns) == spoken)
        #expect(DurationInput.parse(text) == ns)
        #expect(TraceQuery(token).filter.slowerThanNs == ns)
    }

    @Test("Slower than keeps traces that took longer, not as long")
    func strictlySlower() async throws {
        let dir = try TempDir("slower-than")
        defer { dir.remove() }
        let writer = try makeWriter(at: dir.file("magnife.sqlite"))
        try await writer.write { db in
            for (n, ms) in [199, 200, 201, 1_500, 1_501].enumerated() {
                try insertTrace(db, id: traceID(n + 1), startNs: 1_730_000_000_000_000_000 + Int64(n),
                                durationNs: Int64(ms) * 1_000_000 + (n == 1 ? 0 : 0), seq: Int64(n + 1))
            }
        }
        let reader = try await TelemetryReader.open(at: dir.file("magnife.sqlite"))
        for (text, kept) in [(">200ms", 3), ("200", 3), ("1.5s", 1), (">1500", 1), ("100", 5)] {
            let page = try await reader.tracePage(filter: TraceFilter(slowerThanNs: DurationInput.parse(text)))
            #expect(page.traces.count == kept && page.traceCount == kept, "\(text)")
        }
    }

    @Test("the field's words")
    func words() {
        #expect(DurationInput.errorText == "Type a duration, like 200 ms or 1.5 s")
    }
}
