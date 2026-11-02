import Foundation
import Testing
@testable import MagnifeKit

@Suite("Exceptions in the span detail")
struct ExceptionTests {
    static func stack(_ lines: Int) -> String {
        (1...lines).map { "   at Frame\($0)()" }.joined(separator: "\n")
    }

    /// Three exception events out of time order, one with no stack trace, and a plain event.
    static let events = #"""
        [{"time_ns":1030000000,"name":"exception","attributes":{"exception.type":"System.TimeoutException",
           "exception.message":"third","exception.stacktrace":"at C"}},
         {"time_ns":1010000000,"name":"exception","attributes":{"exception.type":"Npgsql.PostgresException",
           "exception.message":"first","exception.stacktrace":"at A\nat B"}},
         {"time_ns":1020000000,"name":"exception","attributes":{"exception.type":"System.InvalidOperationException",
           "exception.message":"second"}},
         {"time_ns":1015000000,"name":"retry","attributes":{"attempt":2}}]
        """#

    @Test("a span with several exception events shows each one, in time order")
    func severalExceptions() throws {
        let detail = SpanDetail(span: try spanRecord(startNs: 1_000_000_000, events: Self.events), resource: nil)
        #expect(detail.exceptions.map(\.message) == ["first", "second", "third"])
        #expect(detail.exceptions.map(\.type) == ["Npgsql.PostgresException", "System.InvalidOperationException",
                                                  "System.TimeoutException"])
        #expect(detail.exceptions.map { detail.offsetText($0.timeNs) } == ["at 10 ms", "at 20 ms", "at 30 ms"])
    }

    @Test("Exception comes first, and exception events are not listed again in Events")
    func sectionOrder() throws {
        let detail = SpanDetail(span: try spanRecord(attributes: #"{"a":1}"#, events: Self.events),
                                resource: try resourceRecord(#"{"service.name":"x"}"#))
        #expect(detail.sections == [.exception, .attributes, .events, .resource])
        #expect(detail.events.map(\.name) == ["retry"])
        let onlyExceptions = SpanDetail(span: try spanRecord(events: #"[{"time_ns":1,"name":"exception","attributes":{}}]"#),
                                        resource: nil)
        #expect(onlyExceptions.sections == [.exception])
        #expect(SpanDetail(span: try spanRecord(), resource: nil).exceptions.isEmpty)
    }

    @Test("a missing stack trace leaves type and message only")
    func missingStackTrace() throws {
        let detail = SpanDetail(span: try spanRecord(events: Self.events), resource: nil)
        let second = detail.exceptions[1]
        #expect(!second.hasStackTrace && second.stackTraceLines.isEmpty && second.stackTracePreview() == nil)
        #expect(detail.exceptions[0].hasStackTrace)
        // Copy Stack Trace in the Edit menu takes the first exception that has one.
        #expect(detail.firstStackTrace == "at A\nat B")
        let none = SpanDetail(span: try spanRecord(events: #"[{"time_ns":1,"name":"exception","attributes":{"exception.type":"E"}}]"#),
                              resource: nil)
        #expect(none.firstStackTrace == nil)
    }

    @Test("stack traces over 20 lines show the first 20", arguments: [(20, false), (21, true), (42, true), (1, false)])
    func preview(lines: Int, cut: Bool) {
        let exception = SpanException(type: "E", message: "m", stackTrace: Self.stack(lines), timeNs: 0)
        #expect(exception.stackTraceLines.count == lines)
        let preview = exception.stackTracePreview()
        #expect((preview != nil) == cut)
        if let preview {
            #expect(preview.split(separator: "\n").count == 20)
            #expect(exception.stackTrace.hasPrefix(preview))
        }
    }

    @Test("line counting: a trailing break adds no line, \\r\\n counts once, blank lines count")
    func lineCount() {
        func count(_ text: String) -> Int { SpanException(type: "", message: "", stackTrace: text, timeNs: 0).stackTraceLines.count }
        #expect(count("a\nb\n") == 2)
        #expect(count("a\r\nb\r\nc") == 3)
        #expect(count("a\n\nb") == 3)
        #expect(count("") == 0)
    }

    @Test("VoiceOver reads \"stack trace, 42 lines\"")
    func spokenStackTrace() {
        #expect(SpanException(type: "E", message: "", stackTrace: Self.stack(42), timeNs: 0).stackTraceAccessibilityLabel
                == "stack trace, 42 lines")
        #expect(SpanException(type: "E", message: "", stackTrace: "at A", timeNs: 0).stackTraceAccessibilityLabel
                == "stack trace, 1 line")
    }
}
