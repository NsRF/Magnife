import Foundation
import GRDB
import Testing
@testable import MagnifeKit

/// Trace Logs (S-012): the open trace's logs, those without a span id
/// included, and what each row's Span column says.
@Suite("Trace Logs (S-012)")
struct TraceLogsTests {
    static let trace = "4bf92f3577b34da6a3ce929d0e0e4736"

    @Test("logs matching the trace id show in time order, even when the span id is missing")
    func traceLogs() throws {
        let logs = TraceLogs(traceID: Self.trace, records: try [
            logRecord(id: 4, timeNs: 4_000, body: "no span", span: nil),
            logRecord(id: 1, timeNs: 1_000, body: "on a span"),
            logRecord(id: 9, timeNs: 2_000, body: "another trace", trace: "4bf92f3577b34da6a3ce929d0e0e0000"),
            logRecord(id: 3, timeNs: 3_000, body: "span not received", span: "0000000000000099"),
            logRecord(id: 2, timeNs: 3_000, body: "same time, lower id", span: nil),
        ])
        #expect(logs.lines.map(\.record.body) == ["on a span", "same time, lower id", "span not received", "no span"])
        #expect(logs.stamp == LogStamp(count: 4, lastID: 4))
        #expect(TraceLogs().isEmpty && TraceLogs().stamp == LogStamp(count: 0, lastID: 0))
    }

    @Test("new logs merge in time order: late ones in their place, others' and shown ones left out (S-030)")
    func adding() throws {
        let shown = TraceLogs(traceID: Self.trace, records: try [
            logRecord(id: 1, timeNs: 1_000, body: "a"),
            logRecord(id: 2, timeNs: 3_000, body: "c"),
        ])
        let more = shown.adding(try [
            logRecord(id: 5, timeNs: 4_000, body: "d"),
            logRecord(id: 4, timeNs: 2_000, body: "b, sent late"),
            logRecord(id: 2, timeNs: 3_000, body: "c again"),
            logRecord(id: 6, timeNs: 0, body: "other trace", trace: "4bf92f3577b34da6a3ce929d0e0e0000"),
        ])
        #expect(more.lines.map(\.record.body) == ["a", "b, sent late", "c", "d"])
        #expect(more.stamp == LogStamp(count: 4, lastID: 5))
        #expect(more == TraceLogs(traceID: Self.trace, records: try [
            logRecord(id: 1, timeNs: 1_000, body: "a"), logRecord(id: 2, timeNs: 3_000, body: "c"),
            logRecord(id: 5, timeNs: 4_000, body: "d"), logRecord(id: 4, timeNs: 2_000, body: "b, sent late"),
        ]))
        #expect(shown.adding([]) == shown)
    }

    @Test("the reader reads only logs after the shown ones, and everything again after a prune")
    func readerAfter() async throws {
        let dir = try TempDir("trace-logs-after")
        defer { dir.remove() }
        let url = dir.file("magnife.sqlite")
        let writer = try makeWriter(at: url)
        try await writer.write { db in
            for n in 0..<3 { try insertLog(db, timeNs: Int64(1_000 + n), severity: 9, service: "web", body: "log \(n)", trace: Self.trace) }
        }
        let reader = try await TelemetryReader.open(at: url)
        let first = try await reader.traceLogs(traceID: Self.trace)
        #expect(first.lines.count == 3)
        try await writer.write { db in
            try insertLog(db, timeNs: 500, severity: 9, service: "web", body: "late", trace: Self.trace)
            try insertLog(db, timeNs: 2_000, severity: 9, service: "web", body: "new", trace: Self.trace)
        }
        let second = try await reader.traceLogs(after: first)
        #expect(second.lines.map(\.record.body) == ["late", "log 0", "log 1", "log 2", "new"])
        #expect(second == (try await reader.traceLogs(traceID: Self.trace)))
        // Retention deleted one shown log: the counts do not add up, so all are read again.
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM logs WHERE body = 'log 0'")
            try insertLog(db, timeNs: 3_000, severity: 9, service: "web", body: "newer", trace: Self.trace)
        }
        let third = try await reader.traceLogs(after: second)
        #expect(third.lines.map(\.record.body) == ["late", "log 1", "log 2", "new", "newer"])
    }

    @Test("the Span column: the span's name, — without a span id, Span not received")
    func spanColumn() {
        let waterfall = Waterfall(spans: WaterfallTests.orders)
        #expect(TraceLogSpan(spanID: "charge", in: waterfall) == .span(id: "charge", name: "op-charge"))
        #expect(TraceLogSpan(spanID: "charge", in: waterfall).spanID == "charge")
        #expect(TraceLogSpan(spanID: nil, in: waterfall) == .none)
        #expect(TraceLogSpan(spanID: nil, in: waterfall).text == "—" && TraceLogSpan.none.spanID == nil)
        #expect(TraceLogSpan(spanID: "gone", in: waterfall) == .notReceived)
        #expect(TraceLogSpan.notReceived.text == "Span not received" && TraceLogSpan.notReceived.spanID == nil)
        // Before the waterfall is built every span reads as not received, never as a crash.
        #expect(TraceLogSpan(spanID: "charge", in: Waterfall()) == .notReceived)
    }

    @Test("a span's ancestors, parent first, so selecting its log opens them")
    func ancestors() {
        let waterfall = Waterfall(spans: WaterfallTests.orders)
        #expect(waterfall.ancestors(of: "stripe") == ["charge", "root"])
        #expect(waterfall.ancestors(of: "root").isEmpty)
        #expect(waterfall.ancestors(of: "missing").isEmpty)
        // An orphan shows at the root: nothing above it to open.
        let orphan = Waterfall(spans: WaterfallTests.orders + [WaterfallTests.span("lost", parent: "never", start: 5, duration: 1)])
        #expect(orphan.ancestors(of: "lost").isEmpty)
    }

    @Test("the pane header counts the logs")
    func countTitle() {
        #expect(TraceLogs.countTitle(1) == "1 log")
        #expect(TraceLogs.countTitle(24) == "24 logs")
        #expect(TraceLogs.countTitle(0) == "0 logs")
    }

    @Test("VoiceOver reads time, level, service, span and body")
    func accessibility() throws {
        let line = try LogLine(logRecord(timeNs: LogLineTests.afternoon, body: "Payment declined\nmore"),
                               timeZone: LogLineTests.utc)
        #expect(line.accessibilityLabel(span: .span(id: "x", name: "charge-card"))
            == "14:02:31, ERROR, checkout-api, span charge-card, Payment declined")
        #expect(line.accessibilityLabel(span: .none) == "14:02:31, ERROR, checkout-api, no span, Payment declined")
        #expect(line.accessibilityLabel(span: .notReceived).contains("span not received"))
    }
}
