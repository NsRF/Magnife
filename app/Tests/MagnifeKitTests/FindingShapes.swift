import Foundation
@testable import MagnifeKit

/// The seed set's four finding traces and the detector edge set's six
/// (`send-sample-traces`, `--edges`), as the helper stored them: same ids,
/// names, kinds, services, parents and nanoseconds, written out by hand so
/// the place tests need no store. `FindingGoldens` holds what each must say.
struct FindingShape {
    /// One stored span: start is from the trace's start.
    struct S {
        var id: String
        var parent: String?
        var name: String
        var kind: Int
        var service: String
        var start: Int64
        var duration: Int64
        var status = 0
        var message = ""
        var db: String?
        var statement: String?
        var method: String?
        var code: Int?
        var route: String?
        var url: String?

        init(_ id: String, _ parent: String?, _ name: String, _ kind: Int, _ service: String, _ start: Int64,
             _ duration: Int64, status: Int = 0, message: String = "", db: String? = nil, statement: String? = nil,
             method: String? = nil, code: Int? = nil, route: String? = nil, url: String? = nil) {
            (self.id, self.parent, self.name, self.kind, self.service, self.start, self.duration) =
                (id, parent, name, kind, service, start, duration)
            (self.status, self.message, self.db, self.statement, self.method, self.code, self.route, self.url) =
                (status, message, db, statement, method, code, route, url)
        }
    }

    var traceID: String
    var route: String
    var rootService: String
    var durationNs: Int64
    var spans: [S]

    static let base: Int64 = 1_793_000_000_000_000_000

    var trace: TraceSummary {
        TraceSummary(traceID: traceID, rootService: rootService, route: route, startNs: Self.base, durationNs: durationNs,
                     spanCount: spans.count)
    }

    var waterfallSpans: [WaterfallSpan] {
        spans.enumerated().map { index, s in
            WaterfallSpan(rowID: Int64(index), spanID: s.id, parentSpanID: s.parent, name: s.name, kind: SpanKind(code: s.kind),
                          startNs: Self.base + s.start, durationNs: s.duration, status: SpanStatus(code: s.status),
                          serviceName: s.service)
        }
    }

    /// What the reader's candidate filter passes to the detectors.
    var detectorSpans: [DetectorSpan] {
        spans.filter { $0.db != nil || $0.statement != nil || $0.method != nil || $0.code != nil }.map { s in
            DetectorSpan(traceID: traceID, spanID: s.id, name: s.name, kind: SpanKind(code: s.kind), startNs: Self.base + s.start,
                         durationNs: s.duration, status: SpanStatus(code: s.status), statusMessage: s.message, dbSystem: s.db,
                         dbStatement: s.statement, httpMethod: s.method, httpStatusCode: s.code, httpRoute: s.route,
                         httpURL: s.url, serviceName: s.service)
        }
    }

    /// The findings with their places, as `TelemetryReader.placedFindings` makes them.
    var placed: (findings: TraceFindings, tree: Waterfall) {
        let tree = Waterfall(spans: waterfallSpans)
        var findings = Detectors.findings(in: detectorSpans)
        let places = FindingPlaces.build(findings, in: tree, trace: trace)
        let messages = Dictionary(uniqueKeysWithValues: spans.map { ($0.id, $0.message) })
        findings.attach(FindingPlaces.withMessages(places, messages))
        return (findings, tree)
    }

    /// By route.
    static let all: [String: FindingShape] = [
        "GET /account/orders": FindingShape(traceID: "e1cc591c804ffeeeca29b13ca4032264", route: "GET /account/orders", rootService: "web", durationNs: 96000000, spans: [
            S("cb7d087be195e63b", nil, "GET /account/orders", 2, "web", 0, 96000000, method: "GET", code: 200, route: "/account/orders", url: "/account/orders"),
            S("16632aeb90746c79", "cb7d087be195e63b", "GET", 3, "web", 3000000, 90000000, method: "GET", code: 200, url: "http://localhost:5080/orders/history?customerId=77"),
            S("bddfdafec281e391", "16632aeb90746c79", "GET /orders/history", 2, "checkout-api", 5000000, 86000000, method: "GET", code: 200, route: "/orders/history", url: "/orders/history?customerId=77"),
            S("23c02c4a1e5d9a5f", "bddfdafec281e391", "GET", 3, "checkout-api", 7000000, 81000000, method: "GET", code: 200, url: "http://localhost:8081/v1/orders?customer_id=77"),
            S("c08574802710146b", "23c02c4a1e5d9a5f", "GET /v1/orders", 2, "orders", 9000000, 77000000, method: "GET", code: 200, route: "/v1/orders"),
            S("8c34938f7857a8a7", "c08574802710146b", "SELECT orders", 3, "orders", 11000000, 6000000, db: "postgresql", statement: "SELECT id, status, total_cents, created_at FROM orders WHERE customer_id = 77 ORDER BY created_at DESC LIMIT 8"),
            S("8d2779403a011785", "c08574802710146b", "SELECT order_items", 3, "orders", 18000000, 7200000, db: "postgresql", statement: "SELECT * FROM order_items WHERE order_id = 1042"),
            S("7fd08f07c8336409", "c08574802710146b", "SELECT order_items", 3, "orders", 26000000, 7200000, db: "postgresql", statement: "SELECT * FROM order_items WHERE order_id = 1043"),
            S("e3c55a8663fd0111", "c08574802710146b", "SELECT order_items", 3, "orders", 34000000, 7200000, db: "postgresql", statement: "SELECT * FROM order_items WHERE order_id = 1044"),
            S("1c38d441bc2b8d03", "c08574802710146b", "SELECT order_items", 3, "orders", 42000000, 7200000, db: "postgresql", statement: "SELECT * FROM order_items WHERE order_id = 1045"),
            S("a091bf0337bea1e3", "c08574802710146b", "SELECT order_items", 3, "orders", 50000000, 7200000, db: "postgresql", statement: "SELECT * FROM order_items WHERE order_id = 1046"),
            S("8ad58aadf73a0a93", "c08574802710146b", "SELECT order_items", 3, "orders", 58000000, 7200000, db: "postgresql", statement: "SELECT * FROM order_items WHERE order_id = 1047"),
            S("d0eacc0a4bcea5bd", "c08574802710146b", "SELECT order_items", 3, "orders", 66000000, 7200000, db: "postgresql", statement: "SELECT * FROM order_items WHERE order_id = 1048"),
            S("c9f67da7a1346cb9", "c08574802710146b", "SELECT order_items", 3, "orders", 74000000, 7200000, db: "postgresql", statement: "SELECT * FROM order_items WHERE order_id = 1049"),
        ]),
        "GET /admin/reports": FindingShape(traceID: "ac389f1bbef04de031f7b4ca12ee833c", route: "GET /admin/reports", rootService: "web", durationNs: 884000000, spans: [
            S("c059dcfadf0d55d9", nil, "GET /admin/reports", 2, "web", 0, 884000000, method: "GET", code: 200, route: "/admin/reports", url: "/admin/reports"),
            S("335a6d2c4a5fe16b", "c059dcfadf0d55d9", "GET", 3, "web", 4000000, 874000000, method: "GET", code: 200, url: "http://localhost:5080/reports/sales?days=30"),
            S("4ef3fc611ccff1b3", "335a6d2c4a5fe16b", "GET /reports/sales", 2, "checkout-api", 6000000, 869000000, method: "GET", code: 200, route: "/reports/sales", url: "/reports/sales?days=30"),
            S("17951d7cc5588d25", "4ef3fc611ccff1b3", "SELECT Orders", 3, "checkout-api", 11000000, 851000000, db: "postgresql", statement: "SELECT date_trunc('day', o.\"CreatedAt\") AS \"Day\", count(*)::int AS \"Orders\", sum(o.\"TotalCents\") AS \"Revenue\" FROM \"Orders\" AS o WHERE o.\"CreatedAt\" >= @__since_0 GROUP BY date_trunc('day', o.\"CreatedAt\") ORDER BY 1"),
        ]),
        "POST /checkout/pay": FindingShape(traceID: "bc5b77bdd1f8b46622194f4aea57eaac", route: "POST /checkout/pay", rootService: "web", durationNs: 64000000, spans: [
            S("501fc7e0195d5a23", nil, "POST /checkout/pay", 2, "web", 0, 64000000, status: 2, method: "POST", code: 500, route: "/checkout/pay", url: "/checkout/pay"),
            S("7fbd7bed2a30a7f9", "501fc7e0195d5a23", "POST", 3, "web", 3000000, 57000000, status: 2, method: "POST", code: 500, url: "http://localhost:5080/payments"),
            S("bfd2c228554ddcc1", "7fbd7bed2a30a7f9", "POST /payments", 2, "checkout-api", 5000000, 52000000, status: 2, method: "POST", code: 500, route: "/payments", url: "/payments"),
            S("9acd2d438d963e7b", "bfd2c228554ddcc1", "SELECT Orders", 3, "checkout-api", 9000000, 3400000, db: "postgresql", statement: "SELECT o.\"Id\", o.\"Status\", o.\"TotalCents\" FROM \"Orders\" AS o WHERE o.\"Id\" = @__orderId_0 LIMIT 1"),
            S("5d79e1a861bf279b", "bfd2c228554ddcc1", "INSERT Payments", 3, "checkout-api", 15000000, 6800000, status: 2, message: "23505: duplicate key value violates unique constraint \"IX_Payments_OrderId\"", db: "postgresql", statement: "INSERT INTO \"Payments\" (\"Id\", \"OrderId\", \"AmountCents\", \"Provider\", \"CreatedAt\") VALUES (@p0, @p1, @p2, @p3, @p4)"),
        ]),
        "inventory.reconcile": FindingShape(traceID: "ef764bd47215bf1f018d0c1c98d9be99", route: "inventory.reconcile", rootService: "orders", durationNs: 2012000000, spans: [
            S("39a7c61ccdb21f71", nil, "inventory.reconcile", 1, "orders", 0, 2012000000, status: 2, message: "reconcile inventory: update sku SKU-1042: context deadline exceeded"),
            S("212c225a24e66b91", "39a7c61ccdb21f71", "UPDATE inventory", 3, "orders", 6000000, 2000000000, status: 2, message: "context deadline exceeded", db: "postgresql", statement: "UPDATE inventory SET available = available - $1, updated_at = now() WHERE sku = $2"),
        ]),
        "GET /edge/slow": FindingShape(traceID: "c777f2805d6c14cc9d377baf2e8ece72", route: "GET /edge/slow", rootService: "web", durationNs: 800000000, spans: [
            S("b7603e2c0e4c8747", nil, "GET /edge/slow", 2, "web", 0, 800000000, method: "GET", code: 200, route: "/edge/slow", url: "/edge/slow"),
            S("a7ee6d8090e93cd9", "b7603e2c0e4c8747", "GET", 3, "web", 2000000, 796000000, method: "GET", code: 200, url: "http://localhost:5080/reports/thresholds"),
            S("c89da29d002af0ab", "a7ee6d8090e93cd9", "GET /reports/thresholds", 2, "checkout-api", 4000000, 792000000, method: "GET", code: 200, route: "/reports/thresholds", url: "/reports/thresholds"),
            S("aaabab0b42f96489", "c89da29d002af0ab", "SELECT DailyTotals", 3, "checkout-api", 10000000, 99900000, db: "postgresql", statement: "SELECT \"Day\", \"Total\" FROM \"DailyTotals\" WHERE \"Day\" >= @__since_0"),
            S("c1831eb304c0c5af", "c89da29d002af0ab", "SELECT WeeklyTotals", 3, "checkout-api", 120000000, 100000000, db: "postgresql", statement: "SELECT \"Week\", \"Total\" FROM \"WeeklyTotals\" WHERE \"Week\" >= @__since_0"),
            S("5d48c99e1201e2eb", "c89da29d002af0ab", "SELECT MonthlyTotals", 3, "checkout-api", 230000000, 100400000, db: "postgresql", statement: "SELECT \"Month\", \"Total\" FROM \"MonthlyTotals\" WHERE \"Month\" >= @__since_0"),
            S("e40b4777895891af", "c89da29d002af0ab", "SELECT YearlyTotals", 3, "checkout-api", 340000000, 101000000, db: "postgresql", statement: "SELECT \"Year\", \"Total\" FROM \"YearlyTotals\" WHERE \"Year\" >= @__since_0"),
            S("01211a5f1871c229", "c89da29d002af0ab", "SELECT Ledger", 3, "checkout-api", 450000000, 330000000, db: "postgresql"),
        ]),
        "GET /edge/dashboard": FindingShape(traceID: "8cb5882e0d71db79007aea27436f3254", route: "GET /edge/dashboard", rootService: "web", durationNs: 120000000, spans: [
            S("97c71ac57271b22f", nil, "GET /edge/dashboard", 2, "web", 0, 120000000, method: "GET", code: 200, route: "/edge/dashboard", url: "/edge/dashboard"),
            S("fa7634329228e715", "97c71ac57271b22f", "GET", 3, "web", 2000000, 116000000, method: "GET", code: 200, url: "http://localhost:5080/dashboard?customerId=17"),
            S("e249081c4a1439d5", "fa7634329228e715", "GET /dashboard", 2, "checkout-api", 4000000, 112000000, method: "GET", code: 200, route: "/dashboard", url: "/dashboard"),
            S("93b6a6a1c8b251a7", "e249081c4a1439d5", "LoadRecentOrders", 1, "checkout-api", 6000000, 50000000),
            S("2b94a68c2df4747b", "93b6a6a1c8b251a7", "SELECT Customers", 3, "checkout-api", 8000000, 3100000, db: "postgresql", statement: "SELECT \"Name\", \"Email\" FROM \"Customers\" WHERE \"Id\" = 17"),
            S("852b417371862e7d", "93b6a6a1c8b251a7", "SELECT Customers", 3, "checkout-api", 13000000, 5000000, db: "postgresql", statement: "SELECT \"Name\", \"Email\" FROM \"Customers\" WHERE \"Id\" = 18"),
            S("c42608694b6ab067", "93b6a6a1c8b251a7", "SELECT Customers", 3, "checkout-api", 20000000, 9800000, db: "postgresql", statement: "SELECT \"Name\", \"Email\" FROM \"Customers\" WHERE \"Id\" = 19"),
            S("48c5f58a7c7d1d2f", "93b6a6a1c8b251a7", "SELECT prices", 3, "checkout-api", 31000000, 2000000, db: "postgresql", statement: "/*traceparent='00-8cb5882e0d71db79007aea27436f3254-0000000000000001-01'*/ SELECT sku, price_cents FROM prices WHERE sku IN ('SKU-1')"),
            S("98656d9737c2b2bf", "93b6a6a1c8b251a7", "SELECT prices", 3, "checkout-api", 34000000, 2000000, db: "postgresql", statement: "/*traceparent='00-8cb5882e0d71db79007aea27436f3254-0000000000000002-01'*/ SELECT sku, price_cents FROM prices WHERE sku IN ('SKU-1', 'SKU-2')"),
            S("eadd6e0cdd95290d", "93b6a6a1c8b251a7", "SELECT prices", 3, "checkout-api", 37000000, 2000000, db: "postgresql", statement: "/*traceparent='00-8cb5882e0d71db79007aea27436f3254-0000000000000003-01'*/ SELECT sku, price_cents FROM prices WHERE sku IN ('SKU-1', 'SKU-2', 'SKU-3')"),
            S("eac0f9023af4ed71", "93b6a6a1c8b251a7", "SELECT prices", 3, "checkout-api", 40000000, 2000000, db: "postgresql", statement: "/*traceparent='00-8cb5882e0d71db79007aea27436f3254-0000000000000004-01'*/ SELECT sku, price_cents FROM prices WHERE sku IN ('SKU-1', 'SKU-2', 'SKU-3', 'SKU-4')"),
            S("56e0e732cd253b49", "93b6a6a1c8b251a7", "SELECT prices", 3, "checkout-api", 43000000, 2000000, db: "postgresql", statement: "/*traceparent='00-8cb5882e0d71db79007aea27436f3254-0000000000000005-01'*/ SELECT sku, price_cents FROM prices WHERE sku IN ('SKU-1', 'SKU-2', 'SKU-3', 'SKU-4', 'SKU-5')"),
            S("f098262652f3d0e3", "e249081c4a1439d5", "LoadOpenCarts", 1, "checkout-api", 60000000, 54000000),
            S("df9627554264d15f", "f098262652f3d0e3", "SELECT Customers", 3, "checkout-api", 62000000, 4000000, db: "postgresql", statement: "SELECT \"Name\", \"Email\" FROM \"Customers\" WHERE \"Id\" = 20"),
            S("e7fa609af6643361", "f098262652f3d0e3", "SELECT Customers", 3, "checkout-api", 67000000, 6000000, db: "postgresql", statement: "SELECT \"Name\", \"Email\" FROM \"Customers\" WHERE \"Id\" = 21"),
            S("91f0310f3fa556f7", "f098262652f3d0e3", "SELECT Customers", 3, "checkout-api", 74000000, 7000000, db: "postgresql", statement: "SELECT \"Name\", \"Email\" FROM \"Customers\" WHERE \"Id\" = 22"),
            S("bf48016b5588ec8f", "f098262652f3d0e3", "SELECT Carts", 3, "checkout-api", 82000000, 2500000, db: "postgresql", statement: "SELECT c.\"Id\", c.\"Total\" FROM \"Carts\" AS c WHERE c.\"CustomerId\" = 17"),
            S("9b2f9467ab861b6d", "f098262652f3d0e3", "SELECT Carts", 3, "checkout-api", 86000000, 2500000, db: "postgresql", statement: "SELECT c.\"Id\", c.\"Total\" FROM \"Carts\" AS c WHERE c.\"CustomerId\" = 18"),
            S("3a4084517cb07187", "f098262652f3d0e3", "SELECT Carts", 3, "checkout-api", 90000000, 2500000, db: "postgresql", statement: "SELECT c.\"Id\", c.\"Total\" FROM \"Carts\" AS c WHERE c.\"CustomerId\" = 19"),
            S("ee5e345f11d25e61", "f098262652f3d0e3", "SELECT Carts", 3, "checkout-api", 94000000, 2500000, db: "postgresql", statement: "SELECT c.\"Id\", c.\"Total\" FROM \"Carts\" AS c WHERE c.\"CustomerId\" = 20"),
        ]),
        "GET /edge/stock": FindingShape(traceID: "bcd4b7d52fe651de1d7d4d682593f5c1", route: "GET /edge/stock", rootService: "web", durationNs: 200000000, spans: [
            S("4ff696c0b27e0eed", nil, "GET /edge/stock", 2, "web", 0, 200000000, method: "GET", code: 200, route: "/edge/stock", url: "/edge/stock"),
            S("f89adfc2454374d1", "4ff696c0b27e0eed", "GET", 3, "web", 2000000, 196000000, method: "GET", code: 200, url: "http://localhost:5080/stock?sku=SKU-1042"),
            S("4eff8902a8b6328b", "f89adfc2454374d1", "GET /stock", 2, "checkout-api", 4000000, 192000000, method: "GET", code: 200, route: "/stock", url: "/stock"),
            S("ef2d1964a270ea23", "4eff8902a8b6328b", "SELECT inventory", 3, "checkout-api", 6000000, 3000000, db: "postgresql", statement: "SELECT available FROM inventory WHERE sku = 'SKU-1042'"),
            S("913e527210a8587d", "4eff8902a8b6328b", "SELECT inventory", 3, "checkout-api", 10000000, 3000000, db: "postgresql", statement: "SELECT available FROM inventory WHERE sku = 'SKU-1042'"),
            S("b3c00bdf6f6a4a37", "4eff8902a8b6328b", "SELECT inventory", 3, "checkout-api", 14000000, 120000000, db: "postgresql", statement: "SELECT available FROM inventory WHERE sku = 'SKU-1042'"),
            S("5d6a43ba76d05eb3", "4eff8902a8b6328b", "GET", 3, "checkout-api", 136000000, 58000000, method: "GET", code: 200, url: "http://localhost:8081/v1/stock/SKU-1042"),
            S("56bea00a6b829cb3", "5d6a43ba76d05eb3", "GET /v1/stock/{sku}", 2, "orders", 138000000, 54000000, method: "GET", code: 200, route: "/v1/stock/{sku}"),
            S("6ab0e1efa8199909", "56bea00a6b829cb3", "SELECT inventory", 3, "orders", 140000000, 4000000, db: "postgresql", statement: "SELECT available FROM inventory WHERE sku = 'SKU-1042'"),
            S("f8ea2da02c809e4b", "56bea00a6b829cb3", "SELECT inventory", 3, "orders", 146000000, 4000000, db: "postgresql", statement: "SELECT available FROM inventory WHERE sku = 'SKU-1042'"),
            S("4dccfa8198d1f81d", "56bea00a6b829cb3", "SELECT inventory", 3, "orders", 152000000, 4000000, db: "postgresql", statement: "SELECT available FROM inventory WHERE sku = 'SKU-1042'"),
        ]),
        "GET /edge/profile": FindingShape(traceID: "cc0268a869e5712fcb5dfe2e6e69ad58", route: "GET /edge/profile", rootService: "web", durationNs: 60000000, spans: [
            S("dcf780cf90a64567", nil, "GET /edge/profile", 2, "web", 0, 60000000, method: "GET", code: 200, route: "/edge/profile", url: "/edge/profile"),
            S("ee9b1903c75520af", "dcf780cf90a64567", "GET", 3, "web", 2000000, 20000000, status: 2, method: "GET", code: 404, url: "http://localhost:5080/customers/404"),
            S("fea2de43bdc62b41", "ee9b1903c75520af", "GET /customers/{id}", 2, "checkout-api", 4000000, 16000000, method: "GET", code: 404, route: "/customers/{id}", url: "/customers/404"),
            S("52223f6fdad02275", "dcf780cf90a64567", "GET", 3, "web", 24000000, 10000000, method: "GET", code: 304, url: "http://localhost:5080/customers/77/avatar"),
            S("3e12d669dc0a87df", "52223f6fdad02275", "GET /customers/{id}/avatar", 2, "checkout-api", 25000000, 8000000, method: "GET", code: 304, route: "/customers/{id}/avatar", url: "/customers/77/avatar"),
            S("6e689598e3d9e16b", "dcf780cf90a64567", "POST", 3, "web", 36000000, 20000000, status: 2, method: "POST", code: 400, url: "http://localhost:5080/customers/77/validate"),
            S("06bab644ee2c56cf", "6e689598e3d9e16b", "POST /customers/{id}/validate", 2, "checkout-api", 38000000, 16000000, method: "POST", code: 400, route: "/customers/{id}/validate", url: "/customers/77/validate"),
        ]),
        "POST /refunds": FindingShape(traceID: "ae8074db3760c149a7e1bc94b741759c", route: "POST /refunds", rootService: "checkout-api", durationNs: 30020000000, spans: [
            S("fb3834528450fd33", nil, "POST /refunds", 2, "checkout-api", 0, 30020000000, status: 2, method: "POST", code: 502, route: "/refunds", url: "/refunds"),
            S("17c59dfb9a26f41b", "fb3834528450fd33", "POST", 3, "checkout-api", 8000000, 30000000000, status: 2, message: "The request was canceled due to the configured HttpClient.Timeout of 30 seconds elapsing.", method: "POST", url: "https://api.stripe.com/v1/refunds"),
        ]),
        "GET /stock/{sku}": FindingShape(traceID: "a9c307e5e0919f46aebbafb03cfa42c6", route: "GET /stock/{sku}", rootService: "checkout-api", durationNs: 40000000, spans: [
            S("e05a58a2e70ef83b", nil, "GET /stock/{sku}", 2, "checkout-api", 0, 40000000, status: 2, message: "stock read from cache after orders failed", method: "GET", code: 200, route: "/stock/{sku}", url: "/stock/SKU-9"),
            S("aad27b343450f975", "e05a58a2e70ef83b", "GET", 3, "checkout-api", 2000000, 30000000, status: 2, method: "GET", code: 503, url: "http://localhost:8081/v1/stock/SKU-9"),
            S("8d3519c687ba673f", "aad27b343450f975", "GET /v1/stock/{sku}", 2, "orders", 4000000, 26000000, status: 2, message: "inventory database unavailable", method: "GET", code: 503, route: "/v1/stock/{sku}"),
        ]),
    ]
}
