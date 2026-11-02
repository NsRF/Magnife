import Foundation
import GRDB
import Testing
@testable import MagnifeKit

/// Condition rows (S-020): span and resource attributes, a trace matching
/// when any of its spans does, on TraceFilterSQLTests' store.
@Suite("Attribute filter (S-020)", .serialized)
struct AttributeFilterTests {
    private func makeStore() async throws -> (TempDir, TelemetryReader) {
        let (dir, writer, reader) = try await TraceFilterSQLTests.makeStore()
        try await writer.write { db in
            // Trace 1's root holds a user id; its child holds the route.
            try db.execute(sql: "UPDATE spans SET attributes = ? WHERE trace_id = ? AND parent_span_id IS NULL",
                           arguments: [#"{"user.id":"u1"}"#, traceID(1)])
            // A key with a double quote, which a JSON path cannot name.
            try db.execute(sql: "UPDATE spans SET attributes = ? WHERE trace_id = ?",
                           arguments: [#"{"payment.id":"x1","we\"ird":"v"}"#, traceID(3)])
        }
        return (dir, reader)
    }

    private func numbers(_ reader: TelemetryReader, _ conditions: [TraceCondition]) async throws -> [Int] {
        try await reader.tracePage(filter: TraceFilter(conditions: conditions)).traces.map { trace in
            [traceID(1), traceID(2), traceID(3)].firstIndex(of: trace.traceID).map { $0 + 1 } ?? 0
        }
    }

    private static func row(_ key: String, _ op: TraceCondition.Operator, _ value: String = "") -> TraceCondition {
        ConditionDraft(key: key, op: op, value: value).condition
    }

    static let cases: [(String, [TraceCondition], [Int])] = [
        ("a child span's attribute", [row("http.route", .is, "/orders")], [1]),
        ("a resource attribute", [row("host.name", .is, "build-box")], [2]),
        ("service.name from the resource", [row("service.name", .is, "orders")], [2]),
        ("is is exact", [row("host.name", .is, "BUILD-BOX")], []),
        ("contains ignores the case of A to Z", [row("host.name", .contains, "BUILD")], [2]),
        ("contains on a statement", [row("db.statement", .contains, "from orders")], [2]),
        ("a number as text", [row("http.status_code", .is, "500")], [1]),
        ("a bool as text", [row("retry", .is, "true")], [1]),
        ("> on a number", [row("http.status_code", .greater, "499")], [1]),
        ("< on a number", [row("http.status_code", .less, "500")], []),
        ("> with a decimal", [row("items", .greater, "2.5")], [2]),
        ("> on a string is never true", [row("coupon", .greater, "1")], []),
        ("exists on a span", [row("db.system", .exists)], [2]),
        ("exists on every resource", [row("service.name", .exists)], [3, 2, 1]),
        ("is not: no span has that value", [row("http.route", .isNot, "/orders")], [3, 2]),
        ("is not on a resource", [row("host.name", .isNot, "build-box")], [3, 1]),
        ("conditions AND, met by different spans", [row("user.id", .is, "u1"), row("http.route", .is, "/orders")], [1]),
        ("conditions AND, nothing meets both", [row("user.id", .is, "u1"), row("db.system", .exists)], []),
        ("a key never received", [row("nope", .is, "1")], []),
        ("a key with a double quote", [row("we\"ird", .is, "v")], [3]),
        ("a key with a double quote, contains", [row("we\"ird", .contains, "V")], [3]),
        ("a key with a double quote, exists", [row("we\"ird", .exists)], [3]),
        ("Route is", [row("Route", .is, "POST /orders")], [2]),
        ("Route is not", [row("Route", .isNot, "GET /health")], [2, 1]),
        ("Route contains", [row("route", .contains, "/CHECK")], [1]),
        ("Any Field", [row("Any Field", .is, "stripe")], [1]),
        ("an empty row is ignored", [row("", .is, "x"), row("db.system", .exists)], [2]),
        ("> with no number is ignored", [row("items", .greater, "many")], [3, 2, 1]),
    ]

    @Test("conditions match span and resource attributes; a trace matches if any span does", arguments: cases)
    func matches(_ name: String, conditions: [TraceCondition], expected: [Int]) async throws {
        let (dir, reader) = try await makeStore()
        defer { dir.remove() }
        #expect(try await numbers(reader, conditions) == expected, "\(name)")
    }

    @Test("the list, Search and new-trace counts agree on conditions")
    func sameEverywhere() async throws {
        let (dir, reader) = try await makeStore()
        defer { dir.remove() }
        let filter = TraceFilter(conditions: [Self.row("http.route", .is, "/orders")])
        let page = try await reader.tracePage(filter: filter)
        let search = try await reader.searchTraces(TraceQuery(TraceQuery.format(filter)))
        let held = try await reader.heldTraces(base: 0, applied: 0, shown: [], filter: filter)
        #expect(page.traces.map(\.traceID) == search.traces.map(\.traceID))
        #expect(held.newCount == page.traceCount && page.traceCount == 1 && page.scopeCount == 3)
        #expect(TraceQuery.format(filter) == "http.route=/orders")
    }

    @Test("a row: its operators, the operator in effect, words")
    func drafts() {
        #expect(ConditionDraft(key: "Any Field", op: .is).effectiveOp == .contains)
        #expect(ConditionDraft(key: "Route", op: .exists).effectiveOp == .is)
        #expect(ConditionDraft(key: "http.route").operators.map(\.title) == ["is", "is not", "contains", "exists", ">", "<"])
        #expect(!ConditionDraft(key: "k", op: .exists).showsValue)
        #expect(ConditionDraft(key: "k", op: .greater, value: "abc").needsNumber)
        #expect(!ConditionDraft(key: "k", op: .greater, value: "12").needsNumber)
        #expect(!ConditionDraft(key: "k", op: .greater).needsNumber)
        #expect(ConditionDraft(key: "http.route", op: .is, value: "/orders").spokenText(number: 1)
                == "Condition 1: http.route is /orders")
        #expect(ConditionDraft.rows(for: []).count == 1 && ConditionDraft.rows(for: []).first?.key == "")
        let condition = Self.row("db.system", .exists)
        #expect(ConditionDraft(condition).condition == condition && ConditionDraft(condition).id == condition.id)
        #expect(ConditionDraft.limitHelp == "Up to 10 conditions" && ConditionDraft.numberError == "Type a number")
    }

    static let keys = [AttributeKey(key: "http.route", source: .span), AttributeKey(key: "http.method", source: .span),
                       AttributeKey(key: "host.name", source: .resource), AttributeKey(key: "db.system", source: .span),
                       AttributeKey(key: "db.system.name", source: .span), AttributeKey(key: "OrderId", source: .log),
                       AttributeKey(key: "service.name", source: .resource), AttributeKey(key: "net.host.name", source: .span)]

    @Test("keys complete from attributes received, built-in keys first")
    func suggestions() {
        let all = ConditionKeySuggestion.suggestions(for: "", keys: Self.keys)
        #expect(all.prefix(2).map(\.title) == ["Any Field", "Route"])
        #expect(!all.contains { $0.key == "OrderId" }, "log keys are not trace filters")
        #expect(ConditionKeySuggestion.suggestions(for: "ht", keys: Self.keys).map(\.title)
                == ["http.method — span", "http.route — span"])
        #expect(ConditionKeySuggestion.suggestions(for: "host", keys: Self.keys).map(\.title)
                == ["host.name — resource", "net.host.name — span"])
        #expect(ConditionKeySuggestion.suggestions(for: "ROU", keys: Self.keys).map(\.title)
                == ["Route", "http.route — span"])
        #expect(ConditionKeySuggestion.suggestions(for: "http.route", keys: Self.keys).isEmpty)
        #expect(ConditionKeySuggestion.suggestions(for: "db.system", keys: Self.keys).isEmpty)
        #expect(ConditionKeySuggestion.suggestions(for: "db.system.", keys: Self.keys).map(\.key) == ["db.system.name"])
        #expect(ConditionKeySuggestion.suggestions(for: "zzz", keys: Self.keys).isEmpty)
        let many = (1...40).map { AttributeKey(key: "k\($0)", source: .span) }
        #expect(ConditionKeySuggestion.suggestions(for: "k", keys: many).count == 20)
    }
}
