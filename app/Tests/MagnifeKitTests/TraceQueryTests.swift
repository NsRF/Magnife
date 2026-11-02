import Foundation
import Testing
@testable import MagnifeKit

/// The query language Search, the filter bar and saved filters share
/// (docs/ux.md, "Search tokens"; design decision 2).
private func any(_ text: String) -> TraceCondition {
    TraceCondition(field: .anyField, op: .contains, value: text)
}

private func attribute(_ key: String, _ op: TraceCondition.Operator, _ value: String = "") -> TraceCondition {
    TraceCondition(field: .attribute(key), op: op, value: value)
}

@Suite("Trace query (S-017)")
struct TraceQueryTests {
    /// Each typed token and the filter the bar would show for it.
    static let tokens: [(String, TraceFilter)] = [
        ("service:checkout-api", TraceFilter(service: "checkout-api")),
        ("SERVICE:orders", TraceFilter(service: "orders")),
        ("service:\"my service\"", TraceFilter(service: "my service")),
        ("status:error", TraceFilter(statuses: [.error])),
        ("status:ERROR", TraceFilter(statuses: [.error])),
        ("Status:Ok", TraceFilter(statuses: [.ok])),
        ("status:unset", TraceFilter(statuses: [.unset])),
        ("status:error status:ok", TraceFilter(statuses: [.error, .ok])),
        ("route:/orders", TraceFilter(conditions: [TraceCondition(field: .route, op: .contains, value: "/orders")])),
        ("route:\"GET /items/{id}\"",
         TraceFilter(conditions: [TraceCondition(field: .route, op: .contains, value: "GET /items/{id}")])),
        ("route=/orders", TraceFilter(conditions: [TraceCondition(field: .route, op: .is, value: "/orders")])),
        ("route!=/health", TraceFilter(conditions: [TraceCondition(field: .route, op: .isNot, value: "/health")])),
        (">200ms", TraceFilter(slowerThanNs: 200_000_000)),
        (">200", TraceFilter(slowerThanNs: 200_000_000)),
        (">1.5s", TraceFilter(slowerThanNs: 1_500_000_000)),
        (">200 ms", TraceFilter(slowerThanNs: 200_000_000)),
        (">850us", TraceFilter(slowerThanNs: 850_000)),
        ("http.route=/orders", TraceFilter(conditions: [attribute("http.route", .is, "/orders")])),
        ("http.method!=GET", TraceFilter(conditions: [attribute("http.method", .isNot, "GET")])),
        ("db.statement~orders", TraceFilter(conditions: [attribute("db.statement", .contains, "orders")])),
        ("http.status_code>499", TraceFilter(conditions: [attribute("http.status_code", .greater, "499")])),
        ("retries<3", TraceFilter(conditions: [attribute("retries", .less, "3")])),
        ("db.statement=\"SELECT 1\"", TraceFilter(conditions: [attribute("db.statement", .is, "SELECT 1")])),
        ("has:db.system", TraceFilter(conditions: [attribute("db.system", .exists)])),
        ("paymnt", TraceFilter(conditions: [any("paymnt")])),
        ("\"payment declined\"", TraceFilter(conditions: [any("payment declined")])),
        ("4bf92f3577b34da6", TraceFilter(conditions: [any("4bf92f3577b34da6")])),
        ("service:orders status:error >200ms route:/orders paymnt",
         TraceFilter(service: "orders", statuses: [.error], slowerThanNs: 200_000_000,
                     conditions: [TraceCondition(field: .route, op: .contains, value: "/orders"), any("paymnt")])),
    ]

    @Test("tokens parse into the filter bar's filters", arguments: tokens)
    func parses(_ text: String, expected: TraceFilter) {
        #expect(TraceQuery(text).filter == expected)
    }

    /// Text that is no token is free text, whole, so nothing is lost or misread.
    static let freeText: [(String, [String])] = [
        ("payment declined", ["payment", "declined"]),
        ("https://api.stripe.com/v1/charges?a=b", ["https://api.stripe.com/v1/charges?a=b"]),
        ("a>b", ["a>b"]),
        ("=value", ["=value"]),
        ("1=2", ["1=2"]),
        ("GET /orders", ["GET", "/orders"]),
        ("\"status:error\"", ["status:error"]),
        ("café", ["café"]),
        ("50%", ["50%"]),
        ("under_score", ["under_score"]),
        ("x\"y z\"", []), // a key-less quote: one word
    ]

    @Test("other words are Any Field conditions", arguments: freeText)
    func freeWords(_ text: String, words: [String]) {
        let query = TraceQuery(text)
        if words.isEmpty {
            #expect(query.filter.conditions.count == 1)
            #expect(query.filter.conditions.first?.field == .anyField)
        } else {
            #expect(query.filter.conditions == words.map { any($0) }, "\(query.filter)")
            #expect(query.filter.service == nil && query.filter.statuses.isEmpty && query.filter.slowerThanNs == nil)
        }
    }

    @Test("tokens still being typed filter nothing and offer their values")
    func unfinished() throws {
        let empty = TraceQuery("status:")
        #expect(empty.filter == TraceFilter())
        #expect(empty.unfinished?.prefix == .status)
        #expect(empty.unfinished?.suggestions(from: TraceQuery.statusValues) == ["error", "ok", "unset"])
        let partial = TraceQuery("orders status:er")
        #expect(partial.unfinished?.suggestions(from: TraceQuery.statusValues) == ["error"])
        #expect(partial.completing(with: "error") == "orders status:error ")
        #expect(TraceQuery("orders status:error ").filter.statuses == [.error])
        // A finished token followed by a space is no longer being typed.
        #expect(TraceQuery("status:error ").unfinished == nil)
        #expect(TraceQuery("status:error").unfinished == nil)
        let service = TraceQuery("service:che")
        #expect(service.unfinished?.suggestions(from: ["checkout-api", "orders", "web"]) == ["checkout-api"])
        #expect(TraceQuery("service:").unfinished?.suggestions(from: ["web", "orders"]) == ["web", "orders"])
        #expect(TraceQuery("service:orders").unfinished?.suggestions(from: ["web", "orders"]) == [])
        // Names containing the text follow those that start with it.
        #expect(TraceQuery("service:o").unfinished?.suggestions(from: ["checkout-api", "orders"]) == ["orders", "checkout-api"])
        let has = TraceQuery("has:http.r")
        #expect(has.unfinished?.prefix == .has)
        #expect(has.unfinished?.suggestions(from: ["http.method", "http.route"]) == ["http.route"])
        #expect(TraceQuery("service:\"my s").unfinished?.prefix == .service)
        #expect(TraceQuery(">").filter == TraceFilter())
        #expect(TraceQuery(">100m").filter == TraceFilter())
        #expect(TraceQuery(">fast").filter == TraceFilter())
        #expect(TraceQuery("\">fast\"").filter == TraceFilter(conditions: [any(">fast")]))
        #expect(TraceQuery("route:").filter == TraceFilter())
        #expect(TraceQuery("has:").filter == TraceFilter())
    }

    @Test("a completed service with spaces is quoted")
    func completesQuoted() {
        #expect(TraceQuery("service:my").completing(with: "my service") == "service:\"my service\" ")
    }

    @Test("repeated tokens: statuses add up, the last service and duration win")
    func repeats() {
        let query = TraceQuery("service:web service:orders >1s >200ms status:ok status:ok")
        #expect(query.filter == TraceFilter(service: "orders", statuses: [.ok], slowerThanNs: 200_000_000))
        #expect(query.tokens.map(\.spokenText) == ["service is orders", "slower than 200 ms", "status is OK"])
    }

    @Test("chips read what each token means")
    func chips() {
        let query = TraceQuery("status:error service:checkout-api >1.5s http.route=/orders has:db.system paymnt")
        #expect(query.tokens.map(\.spokenText) == ["status is Error", "service is checkout-api", "slower than 1.5 s",
                                                   "http.route is /orders", "db.system exists", "Any Field contains paymnt"])
    }

    @Test("trace ID words: 8 to 32 hex digits")
    func traceIDs() {
        #expect(TraceQuery("4bf92f35").traceIDPrefixes == ["4bf92f35"])
        #expect(TraceQuery("4BF92F3577B34DA6A3CE929D0E0E4736").traceIDPrefixes == ["4bf92f3577b34da6a3ce929d0e0e4736"])
        #expect(TraceQuery("4bf92f3").traceIDPrefixes.isEmpty)
        #expect(TraceQuery("checkout").traceIDPrefixes.isEmpty)
        #expect(TraceQuery("service:4bf92f35").traceIDPrefixes.isEmpty)
    }

    static let filters: [TraceFilter] = [
        TraceFilter(),
        TraceFilter(service: "checkout-api", statuses: [.error]),
        TraceFilter(service: "my service", statuses: [.ok, .unset, .error], slowerThanNs: 1_500_000_000),
        TraceFilter(slowerThanNs: 850_000),
        TraceFilter(slowerThanNs: 200_000_000, conditions: [
            TraceCondition(field: .route, op: .contains, value: "GET /items/{id}"),
            TraceCondition(field: .route, op: .is, value: "/orders"),
            TraceCondition(field: .route, op: .isNot, value: "/health"),
            attribute("http.route", .is, "/orders"),
            attribute("http.method", .isNot, "GET"),
            attribute("db.statement", .contains, "SELECT \"x\" FROM t"),
            attribute("db.system", .exists),
            attribute("http.status_code", .greater, "499"),
            attribute("retries", .less, "3.5"),
            any("paymnt"),
            any("payment declined"),
            any("status:error"),
            any(">200ms"),
            any(">fast"),
            any("a=b"),
            any("back\\slash"),
        ]),
    ]

    @Test("a filter formats into a query that parses back to it", arguments: filters)
    func roundTrips(_ filter: TraceFilter) {
        let text = TraceQuery.format(filter)
        #expect(TraceQuery(text).filter == filter, "\(text)")
    }

    @Test("formatting follows the filter bar's order")
    func formats() {
        let filter = TraceFilter(service: "checkout-api", statuses: [.ok, .error], slowerThanNs: 200_000_000,
                                 conditions: [attribute("http.route", .is, "/orders"), attribute("", .is, "ignored")])
        #expect(TraceQuery.format(filter) == "service:checkout-api status:error status:ok >200ms http.route=/orders")
    }

    @Test("conditions without a key, value or number take no part")
    func inactive() {
        #expect(!attribute("", .is, "x").isActive)
        #expect(!attribute("k", .is, "  ").isActive)
        #expect(attribute("k", .exists).isActive)
        #expect(!attribute("k", .greater, "abc").isActive)
        #expect(attribute("k", .greater, "1.5").isActive)
        #expect(!TraceCondition(field: .anyField, op: .is, value: "x").isActive)
        #expect(!TraceCondition(field: .route, op: .exists).isActive)
        #expect(TraceFilter(conditions: [attribute("", .is, "x")]).narrowsScope == false)
    }
}
