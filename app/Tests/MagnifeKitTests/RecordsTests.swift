import Foundation
import Testing
@testable import MagnifeKit

@Suite("Records")
struct RecordsTests {
    @Test("attribute JSON decodes to typed values")
    func attributeValues() {
        let json = #"{"s":"x","i":42,"d":1.5,"b":true,"n":null,"a":["p",1],"o":{"k":"v"},"big":9007199254740993}"#
        let attributes = Attributes(json: json)
        #expect(attributes["s"] == .string("x"))
        #expect(attributes["i"] == .int(42))
        #expect(attributes["d"] == .double(1.5))
        #expect(attributes["b"] == .bool(true))
        #expect(attributes["n"] == .null)
        #expect(attributes["a"] == .array([.string("p"), .int(1)]))
        #expect(attributes["o"] == .object([Attribute("k", .string("v"))]))
        #expect(attributes["big"] == .int(9_007_199_254_740_993))
        #expect(attributes.pairs.map(\.key) == ["a", "b", "big", "d", "i", "n", "o", "s"])
    }

    @Test("attribute text reads like the value")
    func attributeText() {
        #expect(AttributeValue.double(0.25).text == "0.25")
        #expect(AttributeValue.int(-3).text == "-3")
        #expect(AttributeValue.array([.string("a"), .bool(false)]).text == #"["a", false]"#)
        #expect(AttributeValue.object([Attribute("k", .int(1))]).text == "{k: 1}")
    }

    @Test("broken JSON gives no attributes, not a crash")
    func brokenJSON() {
        #expect(Attributes(json: "{not json").isEmpty)
        #expect(Attributes(json: "").isEmpty)
        #expect(Attributes(json: "[1,2]").isEmpty)
    }

    @Test("exception events become exceptions")
    func exceptions() throws {
        let json = #"""
        [{"time_ns":5,"name":"exception","attributes":{"exception.type":"System.InvalidOperationException",
          "exception.message":"Sequence contains no elements","exception.stacktrace":"at A\nat B"}},
         {"time_ns":6,"name":"retry","attributes":{}},
         {"time_ns":7,"name":"exception","attributes":{"exception.type":"TimeoutException"}}]
        """#
        let events = try #require(JSONColumn.decode([SpanEvent].self, from: json))
        #expect(events.count == 3)
        let exceptions = events.compactMap(\.exception)
        #expect(exceptions.count == 2)
        #expect(exceptions[0].type == "System.InvalidOperationException")
        #expect(exceptions[0].stackTrace == "at A\nat B")
        #expect(exceptions[1].message == "")
        #expect(exceptions[1].stackTrace == "")
    }

    @Test("status and kind codes", arguments: [(0, SpanStatus.unset), (1, .ok), (2, .error), (9, .unset)])
    func status(code: Int, expected: SpanStatus) {
        #expect(SpanStatus(code: code) == expected)
    }

    @Test("status words follow the glossary")
    func statusWords() {
        #expect(SpanStatus.allCases.map(\.title) == ["Unset", "OK", "Error"])
        #expect(SpanKind(code: 2).title == "Server")
        #expect(SpanKind(code: 3) == .client)
        #expect(SpanKind(code: 42) == .unspecified)
    }

    @Test("severity numbers map to OTel ranges", arguments: [
        (1, SeverityLevel.trace), (4, .trace), (5, .debug), (8, .debug), (9, .info), (12, .info),
        (13, .warn), (16, .warn), (17, .error), (20, .error), (21, .fatal), (24, .fatal),
    ])
    func severity(number: Int, expected: SeverityLevel) {
        #expect(SeverityLevel(number: number) == expected)
        #expect(expected.range.contains(number))
    }

    @Test("severity outside 1-24 has no level")
    func severityUnknown() {
        #expect(SeverityLevel(number: 0) == nil)
        #expect(SeverityLevel(number: 25) == nil)
        #expect(SeverityLevel.error.range == 17...20)
        #expect(SeverityLevel.fatal.range == 21...24)
    }

    @Test("nanoseconds round-trip through Date")
    func dates() {
        let ns: Int64 = 1_730_000_000_123_456_000
        #expect(abs(Date(nanoseconds: ns).nanoseconds - ns) < 1_000)
    }
}
