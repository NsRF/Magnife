import Foundation
import Testing
@testable import MagnifeKit

/// The compare set of `send-sample-traces --compare` (S-036), span for span:
/// a fast and a slow GET /account/orders.
enum CompareFixture {
    static let ms: Int64 = 1_000_000
    static let base: Int64 = 1_730_000_000_000_000_000

    struct Builder {
        var spans: [ComparisonSpan] = []
        var next = 0
        mutating func add(_ name: String, parent: String? = nil, service: String, kind: SpanKind = .client,
                          start: Double, duration: Double, status: SpanStatus = .unset, route: String? = nil,
                          url: String? = nil, statement: String? = nil) -> String {
            next += 1
            let id = String(format: "%016x", next)
            let span = WaterfallSpan(rowID: Int64(next), spanID: id, parentSpanID: parent, name: name, kind: kind,
                                     startNs: base + Int64(start * Double(ms)), durationNs: Int64(duration * Double(ms)),
                                     status: status, serviceName: service, httpMethod: route == nil ? nil : "GET", httpRoute: route)
            spans.append(ComparisonSpan(span, httpURL: url, dbStatement: statement))
            return id
        }
    }

    static func trace(total: Double, orders: Double, selectOrders: Double, itemsAt: Double, items: Int,
                      slow: Bool) -> [ComparisonSpan] {
        var b = Builder()
        let web = b.add("GET /account/orders", service: "web", kind: .server, start: 0, duration: total, route: "/account/orders")
        let call = b.add("GET", parent: web, service: "web", start: 2, duration: total - 4,
                         url: "http://localhost:5080/orders/history?customerId=77")
        let api = b.add("GET /orders/history", parent: call, service: "checkout-api", kind: .server, start: 4,
                        duration: total - 8, route: "/orders/history")
        if !slow {
            _ = b.add("HGET", parent: api, service: "checkout-api", start: 5, duration: 1, statement: "HGET order-history:77 summary")
        }
        let out = b.add("GET", parent: api, service: "checkout-api", start: 8, duration: orders + 4,
                        url: "http://localhost:8081/v1/orders?customer_id=77")
        let srv = b.add("GET /v1/orders", parent: out, service: "orders", kind: .server, start: 10, duration: orders,
                        route: "/v1/orders")
        _ = b.add("SELECT orders", parent: srv, service: "orders", start: 12, duration: selectOrders,
                  statement: "SELECT id, status, total_cents, created_at FROM orders WHERE customer_id = 77 ORDER BY created_at DESC LIMIT 8")
        for i in 0..<items {
            _ = b.add("SELECT order_items", parent: srv, service: "orders", start: itemsAt + Double(i) * 6, duration: 5,
                      statement: "SELECT * FROM order_items WHERE order_id = \(1042 + i)")
        }
        if slow {
            _ = b.add("GET", parent: srv, service: "orders", start: 382, duration: 18,
                      url: "http://localhost:8082/v1/inventory?order_ids=1042,1043")
        }
        _ = b.add("GET", parent: api, service: "checkout-api", start: slow ? 408 : 54, duration: slow ? 6 : 4,
                  status: slow ? .error : .unset, url: "http://localhost:8083/v1/recommendations?customer_id=77")
        return b.spans
    }

    static let fast = trace(total: 64, orders: 40, selectOrders: 20, itemsAt: 34, items: 2, slow: false)
    static let slow = trace(total: 420, orders: 392, selectOrders: 320, itemsAt: 334, items: 8, slow: true)

    static func summary(_ id: String, _ spans: [ComparisonSpan]) -> TraceSummary {
        let start = spans.map(\.span.startNs).min() ?? 0
        let end = spans.map(\.span.endNs).max() ?? 0
        return TraceSummary(traceID: id, rootService: "web", route: "GET /account/orders", startNs: start,
                            durationNs: end - start, spanCount: spans.count)
    }

    static var comparison: TraceComparison {
        TraceComparison(traceA: summary("a", fast), spansA: fast, traceB: summary("b", slow), spansB: slow)
    }
}

@Suite("Trace comparison (S-036)")
struct TraceComparisonTests {
    typealias Fixture = CompareFixture

    func row(_ comparison: TraceComparison, _ title: String, service: String? = nil) throws -> TraceComparison.Row {
        try #require(comparison.rows.first { $0.title == title && (service == nil || $0.service == service) })
    }

    @Test("ids read as ?, names and words stay")
    func normalizedNames() {
        let n = TraceComparison.normalizedName
        #expect(n("GET /orders/1042") == n("GET /orders/1187"))
        #expect(n("GET /orders/1042") == "GET /orders/?")
        #expect(n("GET /v1/orders") == "GET /v1/orders")
        #expect(n("GET /users/550e8400-e29b-41d4-a716-446655440000/cart") == "GET /users/?/cart")
        #expect(n("span 4bf92f3577b34da6") == "span ?")
        #expect(n("cart-77") == "cart-?")
        #expect(n("order-history") == "order-history")
        #expect(n("deadbeefcafe") == "deadbeefcafe", "hex letters without a digit are a word")
        #expect(n("report 2026-11-06") == "report ?")
        #expect(n("tab 5") == "tab 5")
    }

    @Test("a span named for its method takes its route or URL path")
    func titles() {
        let client = ComparisonSpan(WaterfallSpan(spanID: "1", name: "GET", startNs: 0, durationNs: 1, serviceName: "orders"),
                                    httpURL: "http://localhost:8082/v1/inventory?order_ids=1,2")
        #expect(TraceComparison.title(client) == "GET /v1/inventory")
        let server = ComparisonSpan(WaterfallSpan(spanID: "2", name: "GET", startNs: 0, durationNs: 1, serviceName: "orders",
                                                  httpMethod: "GET", httpRoute: "/v1/orders/{id}"))
        #expect(TraceComparison.title(server) == "GET /v1/orders/{id}")
        let named = ComparisonSpan(WaterfallSpan(spanID: "3", name: "SELECT orders", startNs: 0, durationNs: 1, serviceName: "orders"))
        #expect(TraceComparison.title(named) == "SELECT orders")
        #expect(TraceComparison.path(of: "api.stripe.com/v1/refunds") == "api.stripe.com/v1/refunds")
        #expect(TraceComparison.path(of: "https://api.stripe.com") == "/")
    }

    @Test("over 1 ms and over 20% of A is Slower or Faster, else Same")
    func changeRule() {
        let ms = Fixture.ms
        #expect(TraceComparison.change(from: 20 * ms, to: 320 * ms) == .slower)
        #expect(TraceComparison.change(from: 320 * ms, to: 20 * ms) == .faster)
        #expect(TraceComparison.change(from: 100 * ms, to: 119 * ms) == .same, "19% is noise")
        #expect(TraceComparison.change(from: 100 * ms, to: 121 * ms) == .slower)
        #expect(TraceComparison.change(from: 2 * ms, to: 3 * ms) == .same, "1 ms is not over 1 ms")
        #expect(TraceComparison.change(from: 0, to: 2 * ms) == .slower)
    }

    @Test("the compare set: pairs, the group, New and Missing")
    func compareSet() throws {
        let c = Fixture.comparison
        #expect(c.roots.count == 1)
        let root = c.rows[c.roots[0]]
        #expect(root.title == "GET /account/orders" && root.change == .slower)
        let select = try row(c, "SELECT orders")
        #expect(select.change == .slower && select.bDurationNs - select.aDurationNs == 300 * Fixture.ms)
        let items = try row(c, "SELECT order_items")
        #expect(items.isGroup && items.aRuns == 2 && items.bRuns == 8 && items.change == .repeated)
        #expect(items.children.count == 8)
        #expect(items.children.map { c.rows[$0].change }.filter { $0 == .new }.count == 6)
        #expect(try row(c, "GET /v1/inventory").change == .new)
        #expect(try row(c, "HGET").change == .missing)
        let recommendations = try row(c, "GET /v1/recommendations")
        #expect(recommendations.statusChanged && recommendations.change == .slower)
        #expect(!c.hasLittleInCommon)
        #expect(c.matchedSpans == 9 && c.comparedSpans == 17)
    }

    @Test("the strip: the Error, then by the time each difference explains, self time for Slower")
    func strip() throws {
        let c = Fixture.comparison
        let lines = c.differences.map(c.line)
        #expect(lines.first == "Error · Unset → Error · GET /v1/recommendations · checkout-api")
        #expect(lines.dropFirst().first == "Slower · +300 ms · SELECT orders · orders")
        #expect(lines.contains("Repeated · 2 → 8 runs · +30 ms · SELECT order_items · orders"))
        #expect(lines.contains("New · GET /v1/inventory · orders"))
        #expect(lines.contains("Missing · HGET · checkout-api"))
        // The spans above SELECT orders are slower only because of it: their own time barely moved.
        #expect(!lines.contains { $0.hasPrefix("Slower") && $0.contains("GET /account/orders") })
        #expect(!lines.contains { $0.contains("SELECT order_items") && !$0.hasPrefix("Repeated") }, "the group's extra runs are not New lines")
        let select = try #require(c.differences.first { c.rows[$0.row].title == "SELECT orders" })
        #expect(c.detailText(select) == "SELECT orders took 320 ms in B and 20 ms in A; 300 ms of it is its own time, not its children's.")
        #expect(c.totalSentence == "B took 356 ms longer than A (6.6×). B has 6 more spans.")
    }

    @Test("Queries: each service's normalized statements, changed runs first")
    func queries() throws {
        let c = Fixture.comparison
        let first = try #require(c.queries.first)
        #expect(first.statement == SQLNormalizer.normalize("SELECT * FROM order_items WHERE order_id = 1042"))
        #expect(TraceComparison.runsText(first) == "2 → 8")
        #expect(TraceComparison.durationText(first) == "10 ms → 40 ms")
        #expect(c.queries.count == 3)
        let cache = try #require(c.queries.first { $0.statement.hasPrefix("HGET") })
        #expect(TraceComparison.durationText(cache) == "1.0 ms → —")
    }

    @Test("the cells: durations, groups and changes")
    func cells() throws {
        let c = Fixture.comparison
        let index = try #require(c.rows.firstIndex { $0.title == "SELECT order_items" })
        #expect(c.durationText(of: index, inA: true) == "2 × 5.0 ms")
        #expect(c.durationText(of: index, inA: false) == "8 × 5.0 ms")
        #expect(c.changeText(of: index) == "2 → 8 runs")
        let select = try #require(c.rows.firstIndex { $0.title == "SELECT orders" })
        #expect(c.changeText(of: select) == "+300 ms")
        #expect(c.accessibilityLabel(of: select) == "SELECT orders, orders, A 20 milliseconds, B 320 milliseconds, Slower by 300 milliseconds")
        let cache = try #require(c.rows.firstIndex { $0.title == "HGET" })
        #expect(c.durationText(of: cache, inA: false) == "—")
        #expect(c.accessibilityLabel(of: cache) == "HGET, checkout-api, A 1.0 milliseconds, only in A, Missing")
        #expect(c.shownService(of: c.roots[0]) == "web")
    }

    @Test("swapping A and B turns Slower into Faster and New into Missing")
    func swapped() throws {
        let c = TraceComparison(spansA: Fixture.slow, spansB: Fixture.fast)
        #expect(try row(c, "SELECT orders").change == .faster)
        #expect(try row(c, "GET /v1/inventory").change == .missing)
        #expect(try row(c, "HGET").change == .new)
        #expect(try row(c, "GET /v1/recommendations").statusChanged)
        #expect(c.differences.map(c.line).first == "Error · Error → Unset · GET /v1/recommendations · checkout-api")
    }

    @Test("one root on each side always match; several roots match by key")
    func roots() throws {
        typealias B = CompareFixture.Builder
        var a = B(), b = B()
        _ = a.add("GET /a", service: "web", kind: .server, start: 0, duration: 10)
        _ = b.add("GET /renamed", service: "web", kind: .server, start: 0, duration: 10)
        let renamed = TraceComparison(spansA: a.spans, spansB: b.spans)
        #expect(renamed.rows.count == 1 && !renamed.rows[0].isOneSided)
        #expect(renamed.rows[0].title == "GET /renamed", "B names the row")

        var c = B(), d = B()
        _ = c.add("job", service: "orders", kind: .internal, start: 0, duration: 5)
        _ = c.add("orphan", parent: "ffffffffffffffff", service: "orders", start: 1, duration: 1)
        _ = d.add("job", service: "orders", kind: .internal, start: 0, duration: 6)
        let several = TraceComparison(spansA: c.spans, spansB: d.spans)
        #expect(try row(several, "job").isOneSided == false)
        #expect(try row(several, "orphan").change == .missing)
    }

    @Test("the i-th run pairs with the i-th, in start order")
    func runsPairInOrder() throws {
        typealias B = CompareFixture.Builder
        var a = B(), b = B()
        let ra = a.add("root", service: "s", kind: .server, start: 0, duration: 100)
        let rb = b.add("root", service: "s", kind: .server, start: 0, duration: 100)
        for (i, d) in [10.0, 20, 30].enumerated() { _ = a.add("q", parent: ra, service: "s", start: Double(i) * 30, duration: d) }
        for (i, d) in [10.0, 40, 30].enumerated() { _ = b.add("q", parent: rb, service: "s", start: Double(i) * 30, duration: d) }
        let c = TraceComparison(spansA: a.spans, spansB: b.spans)
        let group = try row(c, "q")
        #expect(group.isGroup && group.change == .slower, "same runs, slower in all: Slower by its total")
        #expect(group.children.map { c.rows[$0].change } == [.same, .slower, .same])
    }

    @Test("self time is the duration less the union of its children")
    func selfTime() {
        typealias B = CompareFixture.Builder
        var b = B()
        let root = b.add("root", service: "s", kind: .server, start: 0, duration: 100)
        _ = b.add("x", parent: root, service: "s", start: 10, duration: 30)
        _ = b.add("y", parent: root, service: "s", start: 20, duration: 30)
        _ = b.add("z", parent: root, service: "s", start: 90, duration: 30)
        let tree = Waterfall(spans: b.spans.map(\.span))
        let selfNs = TraceComparison.selfTimes(tree)
        // Covered: 10..50 and 90..100 = 50 ms.
        #expect(selfNs[tree.index(of: root)!] == 50 * CompareFixture.ms)
    }

    @Test("a span that got faster overall is never a Slower line, whatever its own time did")
    func lineFollowsDuration() {
        typealias B = CompareFixture.Builder
        var a = B(), b = B()
        let ra = a.add("root", service: "web", kind: .server, start: 0, duration: 180)
        _ = a.add("work", parent: ra, service: "web", start: 2, duration: 176)
        let rb = b.add("root", service: "web", kind: .server, start: 0, duration: 96)
        _ = b.add("other", parent: rb, service: "web", start: 2, duration: 90)
        let c = TraceComparison(spansA: a.spans, spansB: b.spans)
        #expect(c.rows[c.roots[0]].change == .faster)
        #expect(!c.differences.contains { $0.kind == .slower }, "\(c.differences.map(c.line))")
    }

    @Test("under 20% of the spans matched: little in common")
    func littleInCommon() {
        typealias B = CompareFixture.Builder
        var a = B(), b = B()
        let ra = a.add("root", service: "web", kind: .server, start: 0, duration: 100)
        let rb = b.add("root", service: "web", kind: .server, start: 0, duration: 100)
        for i in 0..<10 { _ = a.add("a\(i)x", parent: ra, service: "web", start: Double(i), duration: 1) }
        for i in 0..<10 { _ = b.add("b\(i)y", parent: rb, service: "orders", start: Double(i), duration: 1) }
        let c = TraceComparison(spansA: a.spans, spansB: b.spans)
        #expect(c.hasLittleInCommon)
        #expect(c.littleInCommonText == "These traces have little in common: 1 of 21 spans match. They may not be the same request.")
    }

    @Test("row ids stay the same across a rebuild, so the selection survives")
    func stableIDs() {
        let one = Fixture.comparison
        let two = Fixture.comparison
        #expect(one.rows.map(\.id) == two.rows.map(\.id))
        #expect(Set(one.rows.map(\.id)).count == one.rows.count)
    }

    @Test("Show Only Differences collapses subtrees with no difference; groups start collapsed")
    func collapsing() throws {
        typealias B = CompareFixture.Builder
        var a = B(), b = B()
        let ra = a.add("root", service: "s", kind: .server, start: 0, duration: 100)
        let rb = b.add("root", service: "s", kind: .server, start: 0, duration: 200)
        let ca = a.add("calm", parent: ra, service: "s", start: 0, duration: 10)
        let cb = b.add("calm", parent: rb, service: "s", start: 0, duration: 10)
        _ = a.add("leaf", parent: ca, service: "s", start: 1, duration: 5)
        _ = b.add("leaf", parent: cb, service: "s", start: 1, duration: 5)
        _ = b.add("slow", parent: rb, service: "s", start: 20, duration: 150)
        let c = TraceComparison(spansA: a.spans, spansB: b.spans)
        let calm = try row(c, "calm")
        #expect(c.defaultCollapsed(onlyDifferences: true).contains(calm.id))
        #expect(!c.defaultCollapsed(onlyDifferences: false).contains(calm.id))
        let items = try row(Fixture.comparison, "SELECT order_items")
        #expect(Fixture.comparison.defaultCollapsed(onlyDifferences: false).contains(items.id))
    }

    @Test("two 30,000-span chains compare without recursion, and the rows on screen stay bounded")
    func deepChains() {
        func chain(_ count: Int, slow: Bool) -> [ComparisonSpan] {
            (0..<count).map { i in
                ComparisonSpan(WaterfallSpan(rowID: Int64(i), spanID: String(format: "%016x", i + 1),
                                             parentSpanID: i == 0 ? nil : String(format: "%016x", i),
                                             name: "step \(i % 7)", startNs: Int64(i) * 1_000,
                                             durationNs: Int64(count - i) * 1_000 + (slow && i == count - 1 ? 5_000_000 : 0),
                                             serviceName: "orders"))
            }
        }
        let c = TraceComparison(spansA: chain(30_000, slow: false), spansB: chain(30_000, slow: true))
        #expect(c.rows.count == 30_000)
        #expect(c.rows.allSatisfy { !$0.isOneSided })
        #expect(c.visibleRows(collapsed: c.defaultCollapsed(onlyDifferences: false)).count <= Waterfall.autoCollapseLimit + 1)
        #expect(c.differences.first.map(c.line)?.hasPrefix("Slower · +5.0 ms · step") == true)
    }

    @Test("a missing side makes everything one-sided")
    func prunedSide() {
        let c = TraceComparison(spansA: CompareFixture.fast, spansB: [])
        #expect(c.rows.allSatisfy { $0.change == .missing })
        #expect(c.differences.count == 1 && c.differences[0].kind == .missing)
        #expect(c.line(c.differences[0]) == "Missing · 10 spans · GET /account/orders · web")
    }
}
