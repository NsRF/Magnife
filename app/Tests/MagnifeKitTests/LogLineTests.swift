import Foundation
import GRDB
import Testing
@testable import MagnifeKit

/// A log row as the helper stores it.
func logRecord(id: Int64 = 1, timeNs: Int64 = 1_000_000_000, severity: Int = 17, body: String = "Payment declined",
               trace: String? = "4bf92f3577b34da6a3ce929d0e0e4736", span: String? = "00f067aa0ba902b7",
               attributes: String = "{}") throws -> LogRecord {
    try LogRecord(row: Row([
        "id": id, "time_ns": timeNs, "observed_ns": timeNs, "severity_number": severity, "severity_text": "",
        "service_name": "checkout-api", "resource_id": 7, "scope_name": "", "body": body, "attributes": attributes,
        "trace_id": trace, "span_id": span, "event_name": "", "received_ns": timeNs,
    ]))
}

@Suite("Log lines")
struct LogLineTests {
    static let utc = TimeZone(identifier: "UTC")!
    /// 2026-11-02 14:02:31.204 UTC.
    static let afternoon: Int64 = 1_793_628_151_204_000_000

    @Test("times read 14:02:31.204 in the Mac's time zone, 14:02:31 spoken")
    func times() {
        #expect(LogTime.string(nanoseconds: Self.afternoon, timeZone: Self.utc) == "14:02:31.204")
        #expect(LogTime.string(nanoseconds: Self.afternoon + 999_999, timeZone: Self.utc) == "14:02:31.204")
        #expect(LogTime.string(nanoseconds: Self.afternoon, timeZone: Self.utc, milliseconds: false) == "14:02:31")
        #expect(LogTime.string(nanoseconds: Self.afternoon, timeZone: TimeZone(secondsFromGMT: -3 * 3_600)!) == "11:02:31.204")
        #expect(LogTime.string(nanoseconds: Self.afternoon, timeZone: TimeZone(secondsFromGMT: 11 * 3_600)!) == "01:02:31.204")
        #expect(LogTime.string(nanoseconds: 0, timeZone: Self.utc) == "00:00:00.000")
        // Before 1970: still a time of day, not a negative one.
        #expect(LogTime.string(nanoseconds: -1_000_000, timeZone: Self.utc) == "23:59:59.999")
    }

    @Test("levels read in capitals; no level reads —")
    func levels() throws {
        #expect(try LogLine(logRecord(severity: 17)).levelWord == "ERROR")
        #expect(try LogLine(logRecord(severity: 19)).levelWord == "ERROR")
        #expect(try LogLine(logRecord(severity: 9)).levelWord == "INFO")
        #expect(try LogLine(logRecord(severity: 13)).levelWord == "WARN")
        #expect(try LogLine(logRecord(severity: 24)).levelWord == "FATAL")
        #expect(try LogLine(logRecord(severity: 0)).levelWord == "—")
        #expect(SeverityLevel.allCases.map(\.title) == ["TRACE", "DEBUG", "INFO", "WARN", "ERROR", "FATAL"])
    }

    @Test("VoiceOver reads time, level and the body's first line")
    func accessibility() throws {
        let line = try LogLine(logRecord(timeNs: Self.afternoon, body: "Payment declined for order 1182\nat Checkout"),
                               timeZone: Self.utc)
        #expect(line.accessibilityLabel == "14:02:31, ERROR, Payment declined for order 1182")
        #expect(try LogLine(logRecord(timeNs: Self.afternoon, severity: 0, body: "x"), timeZone: Self.utc)
            .accessibilityLabel == "14:02:31, no level, x")
    }

    @Test("attributes by key; a string body shows as sent")
    func attributesAndBody() throws {
        let line = try LogLine(logRecord(body: "  plain text  ", attributes: #"{"z":1,"a":"x","m":true}"#))
        #expect(line.attributes.map(\.key) == ["a", "m", "z"])
        #expect(line.body == "  plain text  " && !line.isStructured)
    }

    @Test("a JSON object body is pretty-printed, keys and numbers as sent")
    func prettyObject() throws {
        let line = try LogLine(logRecord(body: #"{"msg":"payment request failed","order_id":1042,"amount":12.50,"err":{"type":"HTTPError","codes":[500,502]},"tags":[],"meta":{}}"#))
        #expect(line.isStructured)
        #expect(line.body == """
            {
              "msg": "payment request failed",
              "order_id": 1042,
              "amount": 12.50,
              "err": {
                "type": "HTTPError",
                "codes": [
                  500,
                  502
                ]
              },
              "tags": [],
              "meta": {}
            }
            """)
    }

    @Test("strings inside JSON keep their braces, commas, colons and escapes")
    func prettyStrings() {
        #expect(LogBody.pretty(#"{"a":"x, {y}: [z]","b":"say \"hi\", ok","c":"back\\"}"#) == #"""
            {
              "a": "x, {y}: [z]",
              "b": "say \"hi\", ok",
              "c": "back\\"
            }
            """#)
        #expect(LogBody.pretty(#"  [ {"k" : null} , true ]  "#) == "[\n  {\n    \"k\": null\n  },\n  true\n]")
        #expect(LogBody.pretty(#"{"emoji":"🚀é"}"#) == "{\n  \"emoji\": \"🚀é\"\n}")
    }

    @Test("text that is not a JSON object or array shows as sent", arguments: [
        "Payment declined", "[INFO] started", "{not json}", "42", #""quoted""#, "", "[1, 2", "{} trailing",
    ])
    func notJSON(_ text: String) throws {
        #expect(LogBody.pretty(text) == nil)
        #expect(try LogLine(logRecord(body: text)).body == text)
    }

    @Test("bodies over 64,000 bytes show as sent")
    func largeBody() {
        let big = "[" + Array(repeating: "1", count: 40_000).joined(separator: ",") + "]"
        #expect(big.utf8.count > LogBody.prettyLimit)
        #expect(LogBody.pretty(big) == nil)
    }
}

@Suite("Span detail logs")
struct SpanDetailLogTests {
    @Test("the span's own logs, in time order, as the last section")
    func spanLogs() throws {
        let span = try spanRecord(attributes: #"{"http.route":"/payments"}"#)
        let logs = try [
            logRecord(id: 3, timeNs: 3_000, body: "third"),
            logRecord(id: 1, timeNs: 1_000, body: "first"),
            logRecord(id: 4, timeNs: 2_000, body: "other span", span: "00f067aa0ba90000"),
            logRecord(id: 5, timeNs: 2_000, body: "trace only", span: nil),
            logRecord(id: 6, timeNs: 2_000, body: "other trace", trace: "4bf92f3577b34da6a3ce929d0e0e0000"),
            logRecord(id: 2, timeNs: 3_000, body: "second at the same time, lower id"),
        ]
        let detail = SpanDetail(span: span, resource: try resourceRecord(#"{"service.name":"checkout-api"}"#), logs: logs)
        #expect(detail.logs.map(\.record.body) == ["first", "second at the same time, lower id", "third"])
        #expect(detail.sections == [.attributes, .resource, .logs])
        #expect(detail.sections.last == .logs && SpanDetail.Section.logs.title == "Logs")
    }

    @Test("no logs, no Logs section")
    func noLogs() throws {
        let detail = SpanDetail(span: try spanRecord(attributes: #"{"a":1}"#), resource: nil)
        #expect(detail.sections == [.attributes])
        #expect(detail.showAllLogsTitle == nil)
    }

    @Test("over 50 logs show the first 50 with Show All (N)")
    func manyLogs() throws {
        let span = try spanRecord()
        let logs = try (1...60).map { try logRecord(id: Int64($0), timeNs: Int64($0)) }
        let detail = SpanDetail(span: span, resource: nil, logs: logs)
        #expect(detail.shownLogs(all: false).count == 50 && detail.shownLogs(all: true).count == 60)
        #expect(detail.shownLogs(all: false).last?.id == 50)
        #expect(detail.showAllLogsTitle == "Show All (60)")
        let few = SpanDetail(span: span, resource: nil, logs: Array(logs.prefix(50)))
        #expect(few.showAllLogsTitle == nil && few.shownLogs(all: false).count == 50)
    }
}
