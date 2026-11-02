import Foundation
import GRDB
import Testing
@testable import MagnifeKit

/// The waterfall's tree (S-005): nesting, bar placement, late and orphan
/// spans, auto-collapse above 500 spans, and what VoiceOver reads.
@Suite("Waterfall (S-005)")
struct WaterfallTests {
    static let ms: Int64 = 1_000_000
    static let base: Int64 = 1_730_000_000_000_000_000

    static func span(_ id: String, parent: String? = nil, start: Int64, duration: Int64,
                     service: String = "checkout-api", status: SpanStatus = .unset) -> WaterfallSpan {
        WaterfallSpan(spanID: id, parentSpanID: parent, name: "op-\(id)", startNs: base + start * ms,
                      durationNs: duration * ms, status: status, serviceName: service)
    }

    /// POST /orders 240 ms: auth, then charge-card (payments, Error) with a
    /// nested call, then save; listed out of order on purpose.
    static let orders: [WaterfallSpan] = [
        span("save", parent: "root", start: 200, duration: 30),
        span("root", start: 0, duration: 240),
        span("charge", parent: "root", start: 12, duration: 80, service: "payments", status: .error),
        span("stripe", parent: "charge", start: 20, duration: 60, service: "payments"),
        span("auth", parent: "root", start: 2, duration: 8),
    ]

    func names(_ waterfall: Waterfall, _ rows: [Int]) -> [String] { rows.map { waterfall.nodes[$0].span.spanID } }

    @Test("spans nest under their parent, children in start order")
    func nesting() throws {
        let waterfall = Waterfall(spans: Self.orders)
        #expect(waterfall.count == 5)
        #expect(names(waterfall, waterfall.roots) == ["root"])
        #expect(names(waterfall, waterfall.visibleRows(collapsed: [])) == ["root", "auth", "charge", "stripe", "save"])
        let stripe = try #require(waterfall.node("stripe"))
        #expect(stripe.depth == 2)
        #expect(waterfall.node("root")?.descendantCount == 4)
        #expect(waterfall.node("charge")?.descendantCount == 1)
        #expect(waterfall.rootSpanID == "root")
        #expect(waterfall.durationNs == 240 * Self.ms)
        #expect(waterfall.maxDepth == 2)
    }

    @Test("bars are placed and sized by start time and duration")
    func bars() {
        let waterfall = Waterfall(spans: Self.orders)
        let root = waterfall.barFractions(of: waterfall.index(of: "root")!)
        #expect(root.start == 0 && root.width == 1)
        let charge = waterfall.barFractions(of: waterfall.index(of: "charge")!)
        #expect(abs(charge.start - 12.0 / 240) < 1e-9 && abs(charge.width - 80.0 / 240) < 1e-9)
        // A span that runs past the trace's end never draws outside it.
        let late = Waterfall(spans: [Self.span("a", start: 0, duration: 10), Self.span("b", parent: "a", start: 5, duration: 10)])
        let b = late.barFractions(of: late.index(of: "b")!)
        #expect(b.start + b.width <= 1)
        // A zero-length trace does not divide by zero.
        let instant = Waterfall(spans: [Self.span("a", start: 0, duration: 0)])
        let point = instant.barFractions(of: 0)
        #expect(point.start == 0 && point.width == 0)
    }

    @Test("spans that arrive after the trace was opened join under their parent")
    func lateSpans() {
        let first = Waterfall(spans: Array(Self.orders.prefix(3)))
        #expect(names(first, first.visibleRows(collapsed: [])) == ["root", "charge", "save"])
        // stripe arrives in a later batch, then auth: each lands in place.
        let second = Waterfall(spans: Array(Self.orders.prefix(4)))
        #expect(names(second, second.visibleRows(collapsed: [])) == ["root", "charge", "stripe", "save"])
        let third = Waterfall(spans: Self.orders)
        #expect(names(third, third.visibleRows(collapsed: [])) == ["root", "auth", "charge", "stripe", "save"])
        // A collapsed span keeps its late children hidden until it is expanded.
        #expect(names(third, third.visibleRows(collapsed: ["charge"])) == ["root", "auth", "charge", "save"])
    }

    @Test("a span whose parent never arrives shows at the root, and moves when the parent arrives")
    func orphans() throws {
        let spans = Self.orders.filter { $0.spanID != "charge" }
        let waterfall = Waterfall(spans: spans)
        #expect(names(waterfall, waterfall.roots) == ["root", "stripe"])
        let stripe = try #require(waterfall.node("stripe"))
        #expect(stripe.isOrphan && stripe.depth == 0 && stripe.parent == nil)
        #expect(waterfall.node("root")?.isOrphan == false)
        #expect(waterfall.rootSpanID == "root")
        #expect(waterfall.accessibilityLabel(of: waterfall.index(of: "stripe")!).hasSuffix(", Parent span not received"))
        #expect(Waterfall.orphanHelp == "Parent span not received")

        let joined = Waterfall(spans: Self.orders)
        #expect(joined.node("stripe")?.isOrphan == false)
        #expect(joined.node("stripe")?.depth == 2)

        // A trace whose root never arrived still selects its first span.
        let rootless = Waterfall(spans: [Self.span("x", parent: "gone", start: 1, duration: 1)])
        #expect(rootless.rootSpanID == "x")
    }

    @Test("an empty parent id is a root, a self-parent and a parent cycle still show every span")
    func malformed() {
        let empty = Waterfall(spans: [WaterfallSpan(spanID: "a", parentSpanID: "", name: "a", startNs: 0, durationNs: 1,
                                                    serviceName: "s")])
        #expect(empty.node("a")?.isOrphan == false && empty.roots == [0])
        let selfParent = Waterfall(spans: [Self.span("a", parent: "a", start: 0, duration: 1)])
        #expect(selfParent.roots.count == 1)
        let cycle = Waterfall(spans: [Self.span("a", parent: "b", start: 0, duration: 1),
                                      Self.span("b", parent: "a", start: 1, duration: 1),
                                      Self.span("c", start: 2, duration: 1)])
        let rows = cycle.visibleRows(collapsed: [])
        #expect(rows.count == 3 && Set(rows).count == 3)
        #expect(cycle.node("a")?.isOrphan == true && cycle.node("b")?.depth == 1)
    }

    @Test("a chain 30,000 spans deep builds without recursion")
    func deepChain() {
        let spans = (0..<30_000).map { n in
            Self.span("s\(n)", parent: n == 0 ? nil : "s\(n - 1)", start: Int64(n), duration: 1)
        }
        let waterfall = Waterfall(spans: spans)
        #expect(waterfall.maxDepth == 29_999)
        #expect(waterfall.node("s0")?.descendantCount == 29_999)
        #expect(waterfall.visibleRows(collapsed: []).count == 30_000)
    }

    /// The shape of `send-sample-traces --huge-trace`: fanout 6, breadth first.
    static func huge(_ count: Int) -> [WaterfallSpan] {
        var spans = [span("n0", start: 0, duration: Int64(count) * 2)]
        var parent = 0
        while spans.count < count {
            for _ in 0..<6 where spans.count < count {
                spans.append(span("n\(spans.count)", parent: "n\(parent)", start: Int64(spans.count), duration: 1))
            }
            parent += 1
        }
        return spans
    }

    @Test("up to 500 spans open fully expanded")
    func smallOpensExpanded() {
        let waterfall = Waterfall(spans: Self.huge(500))
        #expect(waterfall.defaultCollapsed().isEmpty)
    }

    @Test("over 500 spans open with deep subtrees collapsed, showing at most 500 rows")
    func largeOpensCollapsed() {
        for count in [501, 1_000, 5_000, 30_000] {
            let waterfall = Waterfall(spans: Self.huge(count))
            let collapsed = waterfall.defaultCollapsed()
            let rows = waterfall.visibleRows(collapsed: collapsed)
            #expect(!collapsed.isEmpty, "\(count)")
            #expect(rows.count <= Waterfall.autoCollapseLimit, "\(count): \(rows.count) rows")
            // The root and its children always show.
            #expect(rows.prefix(1).map { waterfall.nodes[$0].span.spanID } == ["n0"])
            #expect(rows.count > waterfall.node("n0")!.children.count)
            // Every collapsed span is on the deepest shown level and has children.
            let depths = Set(collapsed.map { waterfall.node($0)!.depth })
            #expect(collapsed.allSatisfy { !waterfall.node($0)!.children.isEmpty })
            #expect(depths.min() == rows.map { waterfall.nodes[$0].depth }.max(), "\(count)")
        }
        // 30,000 spans: levels of 1, 6, 36 and 216 spans show (259 rows); the 216 are collapsed.
        let big = Waterfall(spans: Self.huge(30_000))
        #expect(big.visibleRows(collapsed: big.defaultCollapsed()).count == 259)
    }

    @Test("a root with more than 500 children still shows them all")
    func wideRoot() {
        let spans = [Self.span("r", start: 0, duration: 1_000)]
            + (0..<800).map { Self.span("c\($0)", parent: "r", start: Int64($0), duration: 1) }
            + [Self.span("g", parent: "c0", start: 0, duration: 1)]
        let waterfall = Waterfall(spans: spans)
        let collapsed = waterfall.defaultCollapsed()
        #expect(collapsed == ["c0"])
        #expect(waterfall.visibleRows(collapsed: collapsed).count == 801)
    }

    @Test("Collapse All Spans closes every span with children")
    func parents() {
        let waterfall = Waterfall(spans: Self.orders)
        #expect(waterfall.parentSpanIDs == ["root", "charge"])
        #expect(names(waterfall, waterfall.visibleRows(collapsed: waterfall.parentSpanIDs)) == ["root"])
    }

    @Test("the service shows only where it differs from the parent's")
    func shownService() {
        let waterfall = Waterfall(spans: Self.orders)
        #expect(waterfall.shownService(of: waterfall.index(of: "root")!) == "checkout-api")
        #expect(waterfall.shownService(of: waterfall.index(of: "auth")!) == nil)
        #expect(waterfall.shownService(of: waterfall.index(of: "charge")!) == "payments")
        #expect(waterfall.shownService(of: waterfall.index(of: "stripe")!) == nil)
    }

    @Test("VoiceOver reads a row as name, service, start, duration, status")
    func spoken() {
        let waterfall = Waterfall(spans: Self.orders)
        #expect(waterfall.accessibilityLabel(of: waterfall.index(of: "charge")!)
                == "op-charge, payments, starts at 12 milliseconds, lasts 80 milliseconds, Error")
        #expect(waterfall.accessibilityLabel(of: waterfall.index(of: "root")!)
                == "op-root, checkout-api, starts at 0 microseconds, lasts 240 milliseconds")
    }

    @Test("the header reads route, then service, duration and span count")
    func header() {
        let trace = TraceSummary(traceID: "t", rootService: "checkout-api", route: "POST /orders", startNs: 0,
                                 durationNs: 240 * Self.ms, spanCount: 18)
        #expect("\(trace.route) · \(trace.waterfallSubtitle)" == "POST /orders · checkout-api · 240 ms · 18 spans")
        #expect(TraceList.spansText(1) == "1 span" && TraceList.spansText(30_000) == "\(30_000.formatted()) spans")
    }

    @Test("the reader's waterfall columns build the same tree as full spans")
    func readerColumns() async throws {
        let dir = try TempDir("waterfall")
        defer { dir.remove() }
        let writer = try makeWriter(at: dir.file("magnife.sqlite"))
        let trace = traceID(1)
        try await writer.write { db in
            try insertTrace(db, id: trace, startNs: Self.base, durationNs: 240 * Self.ms, spanCount: 3)
            let root = String(trace.prefix(16))
            try insertSpan(db, trace: trace, span: "b000000000000002", parent: root, name: "charge-card",
                           service: "payments", startNs: Self.base + 12 * Self.ms, durationNs: 80 * Self.ms, status: 2)
            try insertSpan(db, trace: trace, span: "b000000000000003", parent: "ffffffffffffffff", name: "lost",
                           service: "payments", startNs: Self.base + 20 * Self.ms, durationNs: Self.ms)
        }
        let reader = try await TelemetryReader.open(at: dir.file("magnife.sqlite"))
        let spans = try await reader.waterfallSpans(traceID: trace)
        let waterfall = await Waterfall.build(spans)
        #expect(names(waterfall, waterfall.visibleRows(collapsed: []))
                == [String(trace.prefix(16)), "b000000000000002", "b000000000000003"])
        #expect(waterfall.node("b000000000000002")?.depth == 1)
        #expect(waterfall.node("b000000000000002")?.span.status == .error)
        #expect(waterfall.node("b000000000000003")?.isOrphan == true)
        #expect(waterfall.rootSpanID == String(trace.prefix(16)))
        let full = try #require(try await reader.span(traceID: trace, spanID: "b000000000000002"))
        #expect(full.name == "charge-card" && full.kind == .client)
    }
}
