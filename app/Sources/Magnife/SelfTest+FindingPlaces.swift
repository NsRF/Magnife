import AppKit
import MagnifeKit

/// Where each finding is (detector audit 7 and 8) in the real app: the seed
/// set's strip lines with their place, tooltip and VoiceOver words, and the
/// detector edge set read from its own store (APP_EDGE_STORE, selftest.sh)
/// the way the open trace reads it.
extension SelfTest {
    /// Every strip line of the seed set's finding traces says what and where,
    /// its tooltip is the span detail's text, and a click selects its span.
    static func checkPlacedStrip(_ model: AppModel) async {
        for (route, golden) in PlacedGoldens.seed.sorted(by: { $0.key < $1.key }) {
            // By its fixed id: earlier checks send more traces with these routes, at other scales.
            guard let trace = try? await model.reader?.trace(id: golden.traceID) else {
                check("detector audit: the seed trace \(route) is stored", false)
                continue
            }
            model.selectedTraceID = nil
            model.selectedTraceID = trace.traceID
            let placed = await waitUntil(3) {
                isShown(model) && !model.openTraceFindings.isEmpty
                    && model.openTraceFindings.findings.allSatisfy { model.openTraceFindings.place(for: $0) != nil }
            }
            let findings = model.openTraceFindings
            guard placed else {
                check("detector audit: \(route) opens with its findings placed", false)
                continue
            }
            let lines = findings.findings.map { $0.line(in: findings.place(for: $0)) }
            check("detector audit: \(route)'s strip lines say what and where", lines == golden.lines, "\(lines)")
            let tooltips = findings.findings.map { $0.detailText(in: findings.place(for: $0)) }
            check("detector audit: \(route)'s strip tooltips are the span detail's text", tooltips == golden.details,
                  "\(tooltips)")
            let labels = findings.findings.map { $0.accessibilityLabel(in: findings.place(for: $0)) }
            let hints = findings.findings.map { $0.accessibilityHint(in: findings.place(for: $0)) ?? "" }
            check("detector audit: \(route)'s strip lines for VoiceOver", labels == golden.labels && hints == golden.hints,
                  "\(labels) \(hints)")
            checkStripAccessibility(route, labels: labels)
            guard let first = findings.findings.first else { continue }
            model.selectFinding(first)
            let selected = await waitUntil(2) { model.spanDetail?.span.spanID == first.spanIDs.first }
            check("detector audit: \(route)'s first strip line still selects its first span",
                  selected && model.selectedSpanID == first.spanIDs.first)
        }
        model.selectedTraceID = nil
    }

    /// The strip buttons as VoiceOver finds them, through the Accessibility
    /// API (it needs the Accessibility permission and an unlocked screen;
    /// walking SwiftUI's elements in process crashed the app, SelfTest+TraceList).
    private static func checkStripAccessibility(_ route: String, labels: [String]) {
        guard AXIsProcessTrusted(), accessibilityShowsWindows() else {
            return print("INFO strip accessibility check skipped for \(route): no Accessibility permission or no window")
        }
        let shown = Set(accessibilityButtonLabels())
        let missing = labels.prefix(TraceFindings.stripPreviewCount).filter { !shown.contains($0) }
        check("detector audit: VoiceOver finds \(route)'s strip buttons by their words", missing.isEmpty, "\(missing)")
    }

    /// The descriptions of this app's buttons, through AXUIElement.
    private static func accessibilityButtonLabels() -> [String] {
        func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
            var value: AnyObject?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
        var labels: [String] = []
        var stack = [AXUIElementCreateApplication(getpid())]
        var visited = 0
        while let element = stack.popLast(), visited < 5_000 {
            visited += 1
            if attribute(element, kAXRoleAttribute) as? String == kAXButtonRole,
               let label = attribute(element, kAXDescriptionAttribute) as? String {
                labels.append(label)
            }
            stack.append(contentsOf: attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [])
        }
        return labels
    }

    /// The detector edge set (`send-sample-traces --edges`) in its own store:
    /// 4 Slow SQL, 3 N+1 and 9 HTTP Error findings, each with §10's words.
    static func checkEdgeFindings() async {
        guard let path = ProcessInfo.processInfo.environment["APP_EDGE_STORE"],
              let reader = try? await TelemetryReader.open(at: URL(fileURLWithPath: path)),
              let stored = try? await reader.latestTraces(limit: 100) else {
            return check("APP_EDGE_STORE names the detector edge set's store (tools/selftest.sh)", false)
        }
        check("detector audit: the edge store holds the 6 edge traces",
              Set(stored.map(\.traceID)) == Set(PlacedGoldens.edges.keys), "\(stored.map(\.route))")
        let summaries = (try? await reader.findingSummaries(traceIDs: Array(PlacedGoldens.edges.keys))) ?? [:]
        var totals: [FindingKind: Int] = [:]
        for (traceID, golden) in PlacedGoldens.edges.sorted(by: { $0.value.route < $1.value.route }) {
            guard let read = try? await reader.openTrace(traceID: traceID) else {
                check("detector audit: \(golden.route) reads", false)
                continue
            }
            let tree = await Waterfall.build(read.spans)
            let findings = (try? await reader.placedFindings(read.findings, in: tree, trace: read.trace, traceID: traceID))
                ?? read.findings
            for finding in findings.findings { totals[finding.kind, default: 0] += 1 }
            let lines = findings.findings.map { $0.line(in: findings.place(for: $0)) }
            check("detector audit: \(golden.route)'s strip lines", lines == golden.lines, "\(lines)")
            let details = findings.findings.map { $0.detailText(in: findings.place(for: $0)) }
            check("detector audit: \(golden.route)'s span detail texts", details == golden.details, "\(details)")
            let summary = summaries[traceID]
            let badges = summary.map { summary in summary.kinds.map { summary.help($0) } } ?? []
            check("detector audit: \(golden.route)'s badges and what VoiceOver reads on its row",
                  badges == golden.badges && summary?.spoken == golden.spoken, "\(badges) \(summary?.spoken ?? "none")")
            let flagged = golden.unflagged.filter { !findings.findings(forSpan: $0).isEmpty }
            check("detector audit: \(golden.route)'s spans under each threshold carry no finding", flagged.isEmpty, "\(flagged)")
        }
        check("detector audit: the edge set gives 4 Slow SQL, 3 N+1 and 9 HTTP Error findings",
              totals == [.slowSQL: 4, .nPlusOne: 3, .httpError: 9], "\(totals)")
        if let stock = try? await reader.openTrace(traceID: "bcd4b7d52fe651de1d7d4d682593f5c1") {
            check("detector audit: the 120 ms inventory query is Slow SQL and N+1 at once",
                  stock.findings.kinds(forSpan: "b3c00bdf6f6a4a37") == [.slowSQL, .nPlusOne])
        }
    }
}

/// What the strip, the span detail and the badges say (detector audit §9
/// and §10); the unit tests' `FindingGolden` holds the same strings.
enum PlacedGoldens {
    struct Seed {
        var traceID: String
        var lines: [String]
        var details: [String]
        var labels: [String]
        var hints: [String]
    }

    struct Edge {
        var route: String
        var lines: [String]
        var details: [String]
        /// One per kind, in kind order.
        var badges: [String]
        var spoken: String
        var unflagged: [String] = []
    }

    static let duplicateKey = #"23505: duplicate key value violates unique constraint "IX_Payments_OrderId"."#
    static let refundTimeout = "The request was canceled due to the configured HttpClient.Timeout of 30 seconds elapsing."
    static let span = "Selects the span in the waterfall"
    static let s1Detail = "This query took 851 ms in checkout-api, under GET /reports/sales: 96% of the trace's 884 ms. "
        + "Queries over 100 ms are flagged."

    static let seed: [String: Seed] = [
        "GET /admin/reports": Seed(
            traceID: "ac389f1bbef04de031f7b4ca12ee833c",
            lines: [#"Slow SQL · 851 ms · checkout-api · GET /reports/sales · SELECT date_trunc('day', o."CreatedAt") AS "Day", count(*)::int AS "Orders", sum(o."TotalCents") AS "Revenue" FROM "Orders" AS o WHERE o."CreatedAt" >= @__since_0 GROUP BY date_trunc('day', o."CreatedAt") ORDER BY 1"#],
            details: [s1Detail],
            labels: ["Slow SQL, 851 milliseconds, SELECT Orders in checkout-api, under GET /reports/sales"],
            hints: [span]),
        "inventory.reconcile": Seed(
            traceID: "ef764bd47215bf1f018d0c1c98d9be99",
            lines: ["Slow SQL · 2.00 s · orders · UPDATE inventory SET available = available - $1, updated_at = now() WHERE sku = $2"],
            details: ["This query took 2.00 s in orders, under inventory.reconcile: 99% of the trace's 2.01 s. Queries over 100 ms are flagged. The span has status Error: context deadline exceeded."],
            labels: ["Slow SQL, 2.00 seconds, UPDATE inventory in orders, under inventory.reconcile, status Error"],
            hints: [span]),
        "GET /account/orders": Seed(
            traceID: "e1cc591c804ffeeeca29b13ca4032264",
            lines: ["N+1 · 8 times, 58 ms in all · orders · GET /v1/orders · SELECT * FROM order_items WHERE order_id = ?"],
            details: ["This statement ran 8 times in orders, under GET /v1/orders, 58 ms in all: 60% of the trace's 96 ms. Each run took 7.2 ms. Statements that run 5 or more times in one trace are flagged."],
            labels: ["N+1, SELECT order_items ran 8 times, 58 milliseconds in all, in orders, under GET /v1/orders"],
            hints: ["Selects the first of the 8 spans"]),
        "POST /checkout/pay": Seed(
            traceID: "bc5b77bdd1f8b46622194f4aea57eaac",
            lines: ["HTTP Error · 500 · 64 ms · web · POST /checkout/pay",
                    "HTTP Error · 500 · 57 ms · web → checkout-api · POST http://localhost:5080/payments",
                    "HTTP Error · 500 · 52 ms · checkout-api · POST /payments"],
            details: ["POST /checkout/pay in web returned 500 after 64 ms. Under it, INSERT Payments in checkout-api has status Error: \(duplicateKey)",
                      "web called POST http://localhost:5080/payments and got 500 after 57 ms. checkout-api answered as POST /payments. Under it, INSERT Payments in checkout-api has status Error: \(duplicateKey)",
                      "POST /payments in checkout-api returned 500 to web after 52 ms. Under it, INSERT Payments in checkout-api has status Error: \(duplicateKey)"],
            labels: ["HTTP Error, POST /checkout/pay in web returned 500 after 64 milliseconds",
                     "HTTP Error, web called POST http://localhost:5080/payments and got 500 after 57 milliseconds",
                     "HTTP Error, POST /payments in checkout-api returned 500 to web after 52 milliseconds"],
            hints: [span, span, span]),
    ]

    /// By trace id.
    static let edges: [String: Edge] = [
        "c777f2805d6c14cc9d377baf2e8ece72": Edge(
            route: "GET /edge/slow",
            lines: [#"Slow SQL · just over 100 ms · checkout-api · GET /reports/thresholds · SELECT "Month", "Total" FROM "MonthlyTotals" WHERE "Month" >= @__since_0"#,
                    #"Slow SQL · 101 ms · checkout-api · GET /reports/thresholds · SELECT "Year", "Total" FROM "YearlyTotals" WHERE "Year" >= @__since_0"#,
                    "Slow SQL · 330 ms · checkout-api · GET /reports/thresholds · SELECT Ledger"],
            details: ["This query took just over 100 ms in checkout-api, under GET /reports/thresholds: 13% of the trace's 800 ms. Queries over 100 ms are flagged.",
                      "This query took 101 ms in checkout-api, under GET /reports/thresholds: 13% of the trace's 800 ms. Queries over 100 ms are flagged.",
                      "This postgresql query took 330 ms in checkout-api, under GET /reports/thresholds: 41% of the trace's 800 ms. Queries over 100 ms are flagged."],
            badges: ["Slow SQL: 3 queries over 100 ms, the slowest 330 ms in checkout-api"],
            spoken: "findings: 3 Slow SQL",
            unflagged: ["aaabab0b42f96489", "c1831eb304c0c5af"]),
        "8cb5882e0d71db79007aea27436f3254": Edge(
            route: "GET /edge/dashboard",
            lines: [#"N+1 · 6 times, 35 ms in all · checkout-api · GET /dashboard · SELECT "Name", "Email" FROM "Customers" WHERE "Id" = ?"#,
                    "N+1 · 5 times, 10 ms in all · checkout-api · LoadRecentOrders · SELECT sku, price_cents FROM prices WHERE sku IN (?)"],
            details: ["This statement ran 6 times in checkout-api, under GET /dashboard, 35 ms in all: 29% of the trace's 120 ms. The runs took 3.1 ms to 9.8 ms. Statements that run 5 or more times in one trace are flagged.",
                      "This statement ran 5 times in checkout-api, under LoadRecentOrders, 10 ms in all: 8% of the trace's 120 ms. Each run took 2.0 ms. Statements that run 5 or more times in one trace are flagged."],
            badges: ["N+1: 2 statements ran 5 or more times, the most 6 times in checkout-api"],
            spoken: "findings: 2 N+1",
            unflagged: ["bf48016b5588ec8f", "9b2f9467ab861b6d", "3a4084517cb07187", "ee5e345f11d25e61"]),
        "bcd4b7d52fe651de1d7d4d682593f5c1": Edge(
            route: "GET /edge/stock",
            lines: ["Slow SQL · 120 ms · checkout-api · GET /stock · SELECT available FROM inventory WHERE sku = 'SKU-1042'",
                    "N+1 · 6 times, 138 ms in all · checkout-api and orders · GET /stock · SELECT available FROM inventory WHERE sku = ?"],
            details: ["This query took 120 ms in checkout-api, under GET /stock: 60% of the trace's 200 ms. Queries over 100 ms are flagged.",
                      "This statement ran 6 times in checkout-api and orders, under GET /stock, 138 ms in all: 69% of the trace's 200 ms. The runs took 3.0 ms to 120 ms. Statements that run 5 or more times in one trace are flagged."],
            badges: ["Slow SQL: 1 query over 100 ms, 120 ms in checkout-api",
                     "N+1: a statement ran 6 times in checkout-api and orders, 138 ms in all"],
            spoken: "findings: Slow SQL, N+1"),
        "cc0268a869e5712fcb5dfe2e6e69ad58": Edge(
            route: "GET /edge/profile",
            lines: ["HTTP Error · 404 · 20 ms · web → checkout-api · GET http://localhost:5080/customers/404",
                    "HTTP Error · 404 · 16 ms · checkout-api · GET /customers/{id}",
                    "HTTP Error · 400 · 20 ms · web → checkout-api · POST http://localhost:5080/customers/77/validate",
                    "HTTP Error · 400 · 16 ms · checkout-api · POST /customers/{id}/validate"],
            details: ["web called GET http://localhost:5080/customers/404 and got 404 after 20 ms. checkout-api answered as GET /customers/{id}.",
                      "GET /customers/{id} in checkout-api returned 404 to web after 16 ms.",
                      "web called POST http://localhost:5080/customers/77/validate and got 400 after 20 ms. checkout-api answered as POST /customers/{id}/validate.",
                      "POST /customers/{id}/validate in checkout-api returned 400 to web after 16 ms."],
            badges: ["HTTP Error: 4 calls returned 400 or 404, in web and checkout-api"],
            spoken: "findings: 4 HTTP Error",
            unflagged: ["dcf780cf90a64567", "52223f6fdad02275", "3e12d669dc0a87df"]),
        "ae8074db3760c149a7e1bc94b741759c": Edge(
            route: "POST /refunds",
            lines: ["HTTP Error · 502 · 30.0 s · checkout-api · POST /refunds",
                    "HTTP Error · no response code · 30.0 s · checkout-api · POST https://api.stripe.com/v1/refunds"],
            details: ["POST /refunds in checkout-api returned 502 after 30.0 s. Under it, POST https://api.stripe.com/v1/refunds in checkout-api has status Error: \(refundTimeout)",
                      "checkout-api called POST https://api.stripe.com/v1/refunds and got no response code in 30.0 s. The span has status Error: \(refundTimeout) Responses of 400 or higher, and spans with status Error, are flagged."],
            badges: ["HTTP Error: 2 calls returned 502 or had status Error, in checkout-api"],
            spoken: "findings: 2 HTTP Error"),
        "a9c307e5e0919f46aebbafb03cfa42c6": Edge(
            route: "GET /stock/{sku}",
            lines: ["HTTP Error · 200 · 40 ms · checkout-api · GET /stock/{sku}",
                    "HTTP Error · 503 · 30 ms · checkout-api → orders · GET http://localhost:8081/v1/stock/SKU-9",
                    "HTTP Error · 503 · 26 ms · orders · GET /v1/stock/{sku}"],
            details: ["GET /stock/{sku} in checkout-api returned 200 after 40 ms, but the span has status Error: stock read from cache after orders failed. Under it, GET /v1/stock/{sku} in orders has status Error: inventory database unavailable. Responses of 400 or higher, and spans with status Error, are flagged.",
                      "checkout-api called GET http://localhost:8081/v1/stock/SKU-9 and got 503 after 30 ms. orders answered as GET /v1/stock/{sku}.",
                      "GET /v1/stock/{sku} in orders returned 503 to checkout-api after 26 ms. The span has status Error: inventory database unavailable."],
            badges: ["HTTP Error: 3 calls returned 503 or had status Error, in checkout-api and orders"],
            spoken: "findings: 3 HTTP Error"),
    ]
}
