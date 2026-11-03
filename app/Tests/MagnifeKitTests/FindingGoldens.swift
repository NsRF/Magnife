import Foundation
@testable import MagnifeKit

/// What every finding of the seed set and the edge set says, per surface
/// (detector audit §9 and §10). `FindingPlaceTests` checks them on the
/// shapes written out by hand, `EdgeStoreGoldenTests` on a store the real
/// helper filled.
struct FindingGolden {
    /// In strip order (kind, then start).
    var lines: [String]
    var details: [String]
    /// By finding index, where the audit pins them.
    var labels: [Int: String] = [:]
    /// By span id: the waterfall row's finding words, joined with " · ".
    var rowHelp: [String: String] = [:]
    /// By span id: what the row adds for VoiceOver.
    var marks: [String: [String]] = [:]
    var help: [FindingKind: String]
    var spoken: String
    /// Spans the trace has that carry no finding.
    var unflagged: [String] = []

    var counts: [FindingKind: Int] {
        var counts: [FindingKind: Int] = [:]
        for line in lines {
            for kind in FindingKind.allCases where line.hasPrefix(kind.title + " · ") { counts[kind, default: 0] += 1 }
        }
        return counts
    }

    static let duplicateKey = #"23505: duplicate key value violates unique constraint "IX_Payments_OrderId"."#
    static let refundTimeout = "The request was canceled due to the configured HttpClient.Timeout of 30 seconds elapsing."

    /// By route: the seed set's four finding traces.
    static let seed: [String: FindingGolden] = [
        "GET /admin/reports": FindingGolden(
            lines: [#"Slow SQL · 851 ms · SELECT Orders · checkout-api · GET /reports/sales · SELECT date_trunc('day', o."CreatedAt") AS "Day", count(*)::int AS "Orders", sum(o."TotalCents") AS "Revenue" FROM "Orders" AS o WHERE o."CreatedAt" >= @__since_0 GROUP BY date_trunc('day', o."CreatedAt") ORDER BY 1"#],
            details: ["This query took 851 ms in checkout-api, under GET /reports/sales: 96% of the trace's 884 ms. Queries over 100 ms are flagged."],
            labels: [0: "Slow SQL, 851 milliseconds, SELECT Orders in checkout-api, under GET /reports/sales"],
            rowHelp: ["17951d7cc5588d25": "Slow SQL: 851 ms, over 100 ms"],
            marks: ["17951d7cc5588d25": ["Slow SQL, over 100 milliseconds"]],
            help: [.slowSQL: "Slow SQL: 1 query over 100 ms, 851 ms in checkout-api"],
            spoken: "findings: Slow SQL"),
        "inventory.reconcile": FindingGolden(
            lines: ["Slow SQL · 2.00 s · orders · UPDATE inventory SET available = available - $1, updated_at = now() WHERE sku = $2"],
            details: ["This query took 2.00 s in orders, under inventory.reconcile: 99% of the trace's 2.01 s. Queries over 100 ms are flagged. The span has status Error: context deadline exceeded."],
            labels: [0: "Slow SQL, 2.00 seconds, UPDATE inventory in orders, under inventory.reconcile, status Error"],
            help: [.slowSQL: "Slow SQL: 1 query over 100 ms, 2.00 s in orders"],
            spoken: "findings: Slow SQL"),
        "GET /account/orders": FindingGolden(
            lines: ["N+1 · 8 times, 58 ms in all · SELECT order_items · orders · GET /v1/orders · SELECT * FROM order_items WHERE order_id = ?"],
            details: ["This statement ran 8 times in orders, under GET /v1/orders, 58 ms in all: 60% of the trace's 96 ms. Each run took 7.2 ms. Statements that run 5 or more times in one trace are flagged."],
            labels: [0: "N+1, SELECT order_items ran 8 times, 58 milliseconds in all, in orders, under GET /v1/orders"],
            rowHelp: ["8d2779403a011785": "N+1: run 1 of 8, 58 ms in all", "c9f67da7a1346cb9": "N+1: run 8 of 8, 58 ms in all"],
            marks: ["8d2779403a011785": ["N+1, run 1 of 8"], "c9f67da7a1346cb9": ["N+1, run 8 of 8"]],
            help: [.nPlusOne: "N+1: a statement ran 8 times in orders, 58 ms in all"],
            spoken: "findings: N+1",
            unflagged: ["8c34938f7857a8a7"]),
        "POST /checkout/pay": FindingGolden(
            lines: ["HTTP Error · 500 · 64 ms · web · POST /checkout/pay",
                    "HTTP Error · 500 · 57 ms · web → checkout-api · POST /payments",
                    "HTTP Error · 500 · 52 ms · checkout-api · POST /payments"],
            details: ["POST /checkout/pay in web returned 500 after 64 ms. Under it, INSERT Payments in checkout-api has status Error: \(duplicateKey)",
                      "web called POST http://localhost:5080/payments and got 500 after 57 ms. checkout-api answered as POST /payments. Under it, INSERT Payments in checkout-api has status Error: \(duplicateKey)",
                      "POST /payments in checkout-api returned 500 to web after 52 ms. Under it, INSERT Payments in checkout-api has status Error: \(duplicateKey)"],
            labels: [0: "HTTP Error, POST /checkout/pay in web returned 500 after 64 milliseconds",
                     1: "HTTP Error, web called POST http://localhost:5080/payments and got 500 after 57 milliseconds",
                     2: "HTTP Error, POST /payments in checkout-api returned 500 to web after 52 milliseconds"],
            rowHelp: ["501fc7e0195d5a23": "HTTP Error: 500", "7fbd7bed2a30a7f9": "HTTP Error: 500", "bfd2c228554ddcc1": "HTTP Error: 500"],
            marks: ["bfd2c228554ddcc1": ["HTTP Error, 500"]],
            help: [.httpError: "HTTP Error: 3 calls returned 500, in web and checkout-api"],
            spoken: "findings: 3 HTTP Error",
            unflagged: ["5d79e1a861bf279b", "9acd2d438d963e7b"]),
    ]

    /// By route: the edge set (`send-sample-traces --edges`).
    static let edges: [String: FindingGolden] = [
        "GET /edge/slow": FindingGolden(
            lines: [#"Slow SQL · just over 100 ms · SELECT MonthlyTotals · checkout-api · GET /reports/thresholds · SELECT "Month", "Total" FROM "MonthlyTotals" WHERE "Month" >= @__since_0"#,
                    #"Slow SQL · 101 ms · SELECT YearlyTotals · checkout-api · GET /reports/thresholds · SELECT "Year", "Total" FROM "YearlyTotals" WHERE "Year" >= @__since_0"#,
                    "Slow SQL · 330 ms · checkout-api · GET /reports/thresholds · SELECT Ledger"],
            details: ["This query took just over 100 ms in checkout-api, under GET /reports/thresholds: 13% of the trace's 800 ms. Queries over 100 ms are flagged.",
                      "This query took 101 ms in checkout-api, under GET /reports/thresholds: 13% of the trace's 800 ms. Queries over 100 ms are flagged.",
                      "This postgresql query took 330 ms in checkout-api, under GET /reports/thresholds: 41% of the trace's 800 ms. Queries over 100 ms are flagged."],
            labels: [0: "Slow SQL, just over 100 milliseconds, SELECT MonthlyTotals in checkout-api, under GET /reports/thresholds"],
            rowHelp: ["5d48c99e1201e2eb": "Slow SQL: just over 100 ms", "e40b4777895891af": "Slow SQL: 101 ms, over 100 ms"],
            help: [.slowSQL: "Slow SQL: 3 queries over 100 ms, the slowest 330 ms in checkout-api"],
            spoken: "findings: 3 Slow SQL",
            unflagged: ["aaabab0b42f96489", "c1831eb304c0c5af"]),
        "GET /edge/dashboard": FindingGolden(
            lines: [#"N+1 · 6 times, 35 ms in all · SELECT Customers · checkout-api · GET /dashboard · SELECT "Name", "Email" FROM "Customers" WHERE "Id" = ?"#,
                    "N+1 · 5 times, 10 ms in all · SELECT prices · checkout-api · LoadRecentOrders · SELECT sku, price_cents FROM prices WHERE sku IN (?)"],
            details: ["This statement ran 6 times in checkout-api, under GET /dashboard, 35 ms in all: 29% of the trace's 120 ms. The runs took 3.1 ms to 9.8 ms. Statements that run 5 or more times in one trace are flagged.",
                      "This statement ran 5 times in checkout-api, under LoadRecentOrders, 10 ms in all: 8% of the trace's 120 ms. Each run took 2.0 ms. Statements that run 5 or more times in one trace are flagged."],
            labels: [0: "N+1, SELECT Customers ran 6 times, 35 milliseconds in all, in checkout-api, under GET /dashboard"],
            help: [.nPlusOne: "N+1: 2 statements ran 5 or more times, the most 6 times in checkout-api"],
            spoken: "findings: 2 N+1",
            unflagged: ["bf48016b5588ec8f", "9b2f9467ab861b6d", "3a4084517cb07187", "ee5e345f11d25e61"]),
        "GET /edge/stock": FindingGolden(
            lines: ["Slow SQL · 120 ms · SELECT inventory · checkout-api · GET /stock · SELECT available FROM inventory WHERE sku = 'SKU-1042'",
                    "N+1 · 6 times, 138 ms in all · SELECT inventory · checkout-api and orders · GET /stock · SELECT available FROM inventory WHERE sku = ?"],
            details: ["This query took 120 ms in checkout-api, under GET /stock: 60% of the trace's 200 ms. Queries over 100 ms are flagged.",
                      "This statement ran 6 times in checkout-api and orders, under GET /stock, 138 ms in all: 69% of the trace's 200 ms. The runs took 3.0 ms to 120 ms. Statements that run 5 or more times in one trace are flagged."],
            rowHelp: ["b3c00bdf6f6a4a37": "Slow SQL: 120 ms, over 100 ms · N+1: run 3 of 6, 138 ms in all"],
            marks: ["b3c00bdf6f6a4a37": ["Slow SQL, over 100 milliseconds", "N+1, run 3 of 6"]],
            help: [.slowSQL: "Slow SQL: 1 query over 100 ms, 120 ms in checkout-api",
                   .nPlusOne: "N+1: a statement ran 6 times in checkout-api and orders, 138 ms in all"],
            spoken: "findings: Slow SQL, N+1"),
        "GET /edge/profile": FindingGolden(
            lines: ["HTTP Error · 404 · 20 ms · web → checkout-api · GET /customers/404",
                    "HTTP Error · 404 · 16 ms · checkout-api · GET /customers/{id}",
                    "HTTP Error · 400 · 20 ms · web → checkout-api · POST /customers/77/validate",
                    "HTTP Error · 400 · 16 ms · checkout-api · POST /customers/{id}/validate"],
            details: ["web called GET http://localhost:5080/customers/404 and got 404 after 20 ms. checkout-api answered as GET /customers/{id}.",
                      "GET /customers/{id} in checkout-api returned 404 to web after 16 ms.",
                      "web called POST http://localhost:5080/customers/77/validate and got 400 after 20 ms. checkout-api answered as POST /customers/{id}/validate.",
                      "POST /customers/{id}/validate in checkout-api returned 400 to web after 16 ms."],
            rowHelp: ["fea2de43bdc62b41": "HTTP Error: 404"],
            help: [.httpError: "HTTP Error: 4 calls returned 400 or 404, in web and checkout-api"],
            spoken: "findings: 4 HTTP Error",
            unflagged: ["dcf780cf90a64567", "52223f6fdad02275", "3e12d669dc0a87df"]),
        "POST /refunds": FindingGolden(
            lines: ["HTTP Error · 502 · 30.0 s · checkout-api · POST /refunds",
                    "HTTP Error · no response code · 30.0 s · checkout-api · POST api.stripe.com/v1/refunds"],
            details: ["POST /refunds in checkout-api returned 502 after 30.0 s. Under it, POST https://api.stripe.com/v1/refunds in checkout-api has status Error: \(refundTimeout)",
                      "checkout-api called POST https://api.stripe.com/v1/refunds and got no response code in 30.0 s. The span has status Error: \(refundTimeout) Responses of 400 or higher, and spans with status Error, are flagged."],
            labels: [1: "HTTP Error, checkout-api called POST https://api.stripe.com/v1/refunds and got no response code in 30.0 seconds, status Error"],
            rowHelp: ["17c59dfb9a26f41b": "HTTP Error: no response code, status Error"],
            marks: ["17c59dfb9a26f41b": ["HTTP Error, no response code"]],
            help: [.httpError: "HTTP Error: 2 calls returned 502 or had status Error, in checkout-api"],
            spoken: "findings: 2 HTTP Error"),
        "GET /stock/{sku}": FindingGolden(
            lines: ["HTTP Error · 200 · 40 ms · checkout-api · GET /stock/{sku}",
                    "HTTP Error · 503 · 30 ms · checkout-api → orders · GET /v1/stock/SKU-9",
                    "HTTP Error · 503 · 26 ms · orders · GET /v1/stock/{sku}"],
            details: ["GET /stock/{sku} in checkout-api returned 200 after 40 ms, but the span has status Error: stock read from cache after orders failed. Under it, GET /v1/stock/{sku} in orders has status Error: inventory database unavailable. Responses of 400 or higher, and spans with status Error, are flagged.",
                      "checkout-api called GET http://localhost:8081/v1/stock/SKU-9 and got 503 after 30 ms. orders answered as GET /v1/stock/{sku}.",
                      "GET /v1/stock/{sku} in orders returned 503 to checkout-api after 26 ms. The span has status Error: inventory database unavailable."],
            rowHelp: ["e05a58a2e70ef83b": "HTTP Error: 200, status Error"],
            marks: ["e05a58a2e70ef83b": ["HTTP Error, 200, status Error"]],
            help: [.httpError: "HTTP Error: 3 calls returned 503 or had status Error, in checkout-api and orders"],
            spoken: "findings: 3 HTTP Error"),
    ]

    /// The edge set's trace ids, by route.
    static let edgeTraceIDs: [String: String] = [
        "GET /edge/slow": "c777f2805d6c14cc9d377baf2e8ece72", "GET /edge/dashboard": "8cb5882e0d71db79007aea27436f3254",
        "GET /edge/stock": "bcd4b7d52fe651de1d7d4d682593f5c1", "GET /edge/profile": "cc0268a869e5712fcb5dfe2e6e69ad58",
        "POST /refunds": "ae8074db3760c149a7e1bc94b741759c", "GET /stock/{sku}": "a9c307e5e0919f46aebbafb03cfa42c6",
    ]

    /// Checks one trace's placed findings and summary against this golden;
    /// returns what differs, empty when all agree.
    func differences(_ findings: TraceFindings, summary: FindingSummary) -> [String] {
        var out: [String] = []
        func expect(_ what: String, _ got: some Equatable & CustomStringConvertible, _ want: some Equatable & CustomStringConvertible) {
            if String(describing: got) != String(describing: want) { out.append("\(what): got «\(got)», want «\(want)»") }
        }
        let all = findings.findings
        expect("lines", all.map { $0.line(in: findings.place(for: $0)) }.joined(separator: "\n"), lines.joined(separator: "\n"))
        expect("details", all.map { $0.detailText(in: findings.place(for: $0)) }.joined(separator: "\n"),
               details.joined(separator: "\n"))
        for (index, label) in labels {
            expect("label \(index)", index < all.count ? all[index].accessibilityLabel(in: findings.place(for: all[index])) : "none", label)
        }
        for (spanID, help) in rowHelp {
            expect("row help \(spanID)", findings.findings(forSpan: spanID).map { $0.rowHelp(for: spanID) }.joined(separator: " · "), help)
        }
        for (spanID, spoken) in marks {
            expect("marks \(spanID)", findings.findings(forSpan: spanID).map { $0.spokenMark(for: spanID) }.joined(separator: "|"),
                   spoken.joined(separator: "|"))
        }
        for spanID in unflagged { expect("no finding on \(spanID)", findings.findings(forSpan: spanID).count, 0) }
        for (kind, help) in help { expect("badge \(kind.title)", summary.help(kind), help) }
        expect("badge kinds", summary.kinds.map(\.title).joined(separator: ","), help.keys.sorted().map(\.title).joined(separator: ","))
        expect("spoken", summary.spoken ?? "nil", spoken)
        return out
    }
}
