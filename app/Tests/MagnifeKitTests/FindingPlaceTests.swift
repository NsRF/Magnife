import Foundation
import Testing
@testable import MagnifeKit

/// Where a finding is (detector audit 7) and what each surface says with it
/// (audit 8), on the seed set's and the edge set's shapes written out by hand.
@Suite("Finding places")
struct FindingPlaceTests {
    static let ms: Int64 = 1_000_000

    @Test("the seed set's and the edge set's findings say what and where, on every surface",
          arguments: Array(FindingGolden.seed.keys) + Array(FindingGolden.edges.keys))
    func goldens(route: String) throws {
        let shape = try #require(FindingShape.all[route])
        let golden = try #require(FindingGolden.seed[route] ?? FindingGolden.edges[route])
        let placed = shape.placed
        let differences = golden.differences(placed.findings, summary: placed.findings.summary)
        #expect(differences.isEmpty, "\(route):\n\(differences.joined(separator: "\n"))")
        #expect(placed.findings.summary.counts == golden.counts)
        // Every finding has a place, and every span it names is a row.
        #expect(placed.findings.findings.allSatisfy { placed.findings.place(for: $0) != nil })
        #expect(placed.findings.findings.allSatisfy { $0.spanIDs.allSatisfy { placed.tree.index(of: $0) != nil } })
    }

    @Test("the edge set has 4 Slow SQL, 3 N+1 and 9 HTTP Error findings")
    func edgeTotals() {
        var counts: [FindingKind: Int] = [:]
        for route in FindingGolden.edges.keys {
            for (kind, count) in FindingShape.all[route]?.placed.findings.summary.counts ?? [:] { counts[kind, default: 0] += count }
        }
        #expect(counts == [.slowSQL: 4, .nPlusOne: 3, .httpError: 9])
    }

    @Test("the header's route and service are left out of the strip line, never out of the span detail")
    func underIsHeader() throws {
        let placed = try #require(FindingShape.all["inventory.reconcile"]).placed.findings
        let finding = try #require(placed.findings.first)
        let place = try #require(placed.place(for: finding))
        #expect(place.under == "inventory.reconcile" && place.underIsHeader)
        #expect(!finding.line(in: place).contains("reconcile"))
        #expect(finding.detailText(in: place).contains(", under inventory.reconcile"))
    }

    @Test("the strip shows 3 lines of the 4xx trace, then Show All Findings (4)")
    func stripOfFour() throws {
        let placed = try #require(FindingShape.all["GET /edge/profile"]).placed.findings
        #expect(placed.shownInStrip(all: false).count == 3)
        #expect(placed.showAllTitle == "Show All Findings (4)")
    }

    @Test("with no place, every string is the one without a place")
    func nilPlace() throws {
        let finding = try #require(FindingShape.all["GET /admin/reports"]?.placed.findings.findings.first)
        #expect(finding.line(in: nil) == finding.line)
        #expect(finding.detailText(in: nil) == finding.detailText)
        #expect(finding.accessibilityLabel(in: nil) == finding.accessibilityLabel)
        #expect(TraceFindings([finding]).place(for: finding) == nil)
    }

    // MARK: Rules

    private func span(_ id: String, _ parent: String?, _ name: String, kind: SpanKind = .internal, service: String = "api",
                      start: Int64 = 0, ms duration: Int64 = 1, status: SpanStatus = .unset,
                      method: String? = nil, route: String? = nil) -> WaterfallSpan {
        WaterfallSpan(spanID: id, parentSpanID: parent, name: name, kind: kind, startNs: start, durationNs: duration * Self.ms,
                      status: status, serviceName: service, httpMethod: method, httpRoute: route)
    }

    private func slow(_ id: String, service: String = "api", ms: Int64 = 150) -> DetectorSpan {
        DetectorSpan(spanID: id, name: "SELECT t", durationNs: ms * Self.ms, dbSystem: "postgresql",
                     dbStatement: "SELECT * FROM t WHERE id = 1", serviceName: service)
    }

    private func places(_ spans: [WaterfallSpan], _ detector: [DetectorSpan], trace: TraceSummary? = nil)
        -> (TraceFindings, [String: FindingPlace]) {
        let findings = Detectors.findings(in: detector)
        return (findings, FindingPlaces.build(findings, in: Waterfall(spans: spans), trace: trace))
    }

    @Test("a server span named only for its method reads as its route when it has one (verifiers: route)")
    func methodOnlyWithRoute() throws {
        // Node's http instrumentation: web → client "POST" → server "POST" with http.route → INSERT.
        let spans = [span("r", nil, "POST /checkout/pay", kind: .server, service: "web", ms: 400),
                     span("c", "r", "POST", kind: .client, service: "web", start: 1, ms: 380),
                     span("s", "c", "POST", kind: .server, service: "pay", start: 2, ms: 360, method: "POST", route: "/payments"),
                     span("q", "s", "INSERT payments", kind: .client, service: "pay", start: 3, ms: 300)]
        let insert = DetectorSpan(spanID: "q", name: "INSERT payments", durationNs: 300 * Self.ms, dbSystem: "postgresql",
                                  dbStatement: "INSERT INTO payments (cents) VALUES ($1)", serviceName: "pay")
        let client = DetectorSpan(spanID: "c", name: "POST", kind: .client, startNs: 1, durationNs: 380 * Self.ms,
                                  status: .error, httpMethod: "POST", httpStatusCode: 500,
                                  httpURL: "http://localhost:3000/payments", serviceName: "web")
        let (findings, places) = places(spans, [insert, client])
        let query = try #require(findings.findings.first { $0.kind == .slowSQL })
        #expect(places[query.id]?.under == "POST /payments")
        let failed = try #require(findings.findings.first { $0.kind == .httpError })
        #expect(places[failed.id]?.calleeRoute == "POST /payments")
        #expect(failed.line(in: places[failed.id]) == "HTTP Error · 500 · 380 ms · web → pay · POST /payments")
        #expect(failed.detailText(in: places[failed.id]).hasPrefix(
            "web called POST http://localhost:3000/payments and got 500 after 380 ms. pay answered as POST /payments."))
        // A root named "GET" with its route: the trace's route, as the helper writes it.
        let root = [span("g", nil, "GET", kind: .server, service: "reports", ms: 350, method: "GET", route: "/admin/reports"),
                    span("q", "g", "SELECT t", kind: .client, service: "reports")]
        let (rootFindings, rootPlaces) = self.places(root, [slow("q", service: "reports")])
        #expect(rootPlaces[try #require(rootFindings.findings.first).id]?.under == "GET /admin/reports")
        #expect(WaterfallSpan(spanID: "x", name: "GET", startNs: 0, durationNs: 0, serviceName: "", httpRoute: "/x").route == "/x")
        #expect(WaterfallSpan(spanID: "x", name: "work", startNs: 0, durationNs: 0, serviceName: "", httpMethod: "GET").route == "work")
    }

    @Test("the strip line names the query before where, and a client's URL without its scheme, and its host when the callee is named")
    func stripWhat() throws {
        let finding = try #require(Detectors.findings(in: [slow("q")]).findings.first)
        #expect(finding.line(in: FindingPlace(services: ["api"])) == "Slow SQL · 150 ms · SELECT t · api · SELECT * FROM t WHERE id = 1")
        // The name is left out when the statement starts with it.
        let update = DetectorSpan(spanID: "u", name: "UPDATE t", durationNs: 150 * Self.ms, dbSystem: "postgresql",
                                  dbStatement: "UPDATE t SET a = 1", serviceName: "api")
        let updated = try #require(Detectors.findings(in: [update]).findings.first)
        #expect(updated.line(in: FindingPlace(services: ["api"])) == "Slow SQL · 150 ms · api · UPDATE t SET a = 1")
        func call(_ url: String) throws -> Finding {
            try #require(Detectors.httpErrors([DetectorSpan(spanID: "c", name: "GET", kind: .client, durationNs: Self.ms,
                                                            httpMethod: "GET", httpStatusCode: 404, httpURL: url,
                                                            serviceName: "web")]).first)
        }
        #expect(try call("https://api.example.com/v1/x?id=2").line(in: FindingPlace(services: ["web"], caller: "web"))
            == "HTTP Error · 404 · 1.0 ms · web · GET api.example.com/v1/x?id=2")
        #expect(try call("http://localhost:5080/customers/404").line(in: FindingPlace(services: ["web"], caller: "web", callee: "api"))
            == "HTTP Error · 404 · 1.0 ms · web → api · GET /customers/404")
        #expect(try call("http://localhost:5080").line(in: FindingPlace(services: ["web"], caller: "web", callee: "api"))
            == "HTTP Error · 404 · 1.0 ms · web → api · GET /")
        #expect(try call("http://localhost:5080/customers/404").detailText(in: FindingPlace(services: ["web"], caller: "web"))
            == "web called GET http://localhost:5080/customers/404 and got 404 after 1.0 ms.")
    }

    @Test("a server span named only for its method is skipped for one further up")
    func methodOnly() throws {
        let spans = [span("r", nil, "GET /orders", kind: .server), span("m", "r", "GET", kind: .server),
                     span("q", "m", "SELECT t", kind: .client)]
        let (findings, places) = places(spans, [slow("q")])
        #expect(places[try #require(findings.findings.first).id]?.under == "GET /orders")
        // Nothing else above: no under at all.
        let (alone, alonePlaces) = self.places([span("m", nil, "get", kind: .server), span("q", "m", "SELECT t")], [slow("q")])
        #expect(alonePlaces[try #require(alone.findings.first).id]?.under == nil)
    }

    @Test("Slow SQL with no server above sits under the root's name; an orphan or a root under nothing")
    func slowUnder() throws {
        let job = [span("j", nil, "nightly.job"), span("w", "j", "work"), span("q", "w", "SELECT t", kind: .client)]
        let (findings, places) = places(job, [slow("q")])
        #expect(places[try #require(findings.findings.first).id]?.under == "nightly.job")
        let (orphan, orphanPlaces) = self.places([span("q", "missing", "SELECT t", kind: .client)], [slow("q")])
        let lone = try #require(orphan.findings.first)
        let place = try #require(orphanPlaces[lone.id])
        #expect(place.under == nil)
        #expect(lone.line(in: place) == "Slow SQL · 150 ms · SELECT t · api · SELECT * FROM t WHERE id = 1")
    }

    @Test("an N+1 under two roots, or orphans, has no under; under two parents it sits under their common one")
    func nPlusOneUnder() throws {
        func repeated(_ parents: [String]) -> [DetectorSpan] {
            parents.indices.map { n in
                DetectorSpan(spanID: "q\(n)", name: "SELECT t", startNs: Int64(n), durationNs: Self.ms, dbSystem: "postgresql",
                             dbStatement: "SELECT * FROM t WHERE id = \(n)", serviceName: "api")
            }
        }
        let parents = ["a", "a", "b", "b", "b"]
        var tree = [span("r", nil, "GET /x", kind: .server), span("a", "r", "LoadA"), span("b", "r", "LoadB")]
        tree += parents.enumerated().map { span("q\($0.offset)", $0.element, "SELECT t", kind: .client, start: Int64($0.offset)) }
        let (found, places) = places(tree, repeated(parents))
        #expect(places[try #require(found.findings.first).id]?.under == "GET /x")

        var twoRoots = [span("r1", nil, "GET /x", kind: .server), span("r2", nil, "GET /y", kind: .server)]
        twoRoots += parents.enumerated().map { span("q\($0.offset)", $0.offset < 2 ? "r1" : "r2", "SELECT t", start: Int64($0.offset)) }
        let (split, splitPlaces) = self.places(twoRoots, repeated(parents))
        #expect(splitPlaces[try #require(split.findings.first).id]?.under == nil)

        let orphans = parents.indices.map { span("q\($0)", "gone\($0)", "SELECT t", start: Int64($0)) }
        let (lost, lostPlaces) = self.places(orphans, repeated(parents))
        #expect(lostPlaces[try #require(lost.findings.first).id]?.under == nil)

        // One repeated span under another: their common place is above both.
        let nested = [span("r", nil, "GET /n", kind: .server), span("q0", "r", "SELECT t"), span("q1", "q0", "SELECT t"),
                      span("q2", "q1", "SELECT t"), span("q3", "r", "SELECT t"), span("q4", "r", "SELECT t")]
        let (deep, deepPlaces) = self.places(nested, repeated(parents))
        #expect(deepPlaces[try #require(deep.findings.first).id]?.under == "GET /n")
    }

    @Test("the share of the trace is left out at a trace of 0, and when the finding took longer than the trace")
    func share() throws {
        let finding = try #require(Detectors.findings(in: [slow("q")]).findings.first)
        #expect(FindingPlace(services: ["api"], traceDurationNs: 0).share(of: finding) == nil)
        #expect(FindingPlace(services: ["api"], traceDurationNs: 150 * Self.ms).share(of: finding) == 100)
        // Runs at the same time, or clock skew: no "100% of the trace's 100 ms" for 150 ms.
        #expect(FindingPlace(services: ["api"], traceDurationNs: 100 * Self.ms).share(of: finding) == nil)
        let parallel = finding.detailText(in: FindingPlace(services: ["api"], under: "GET /x", traceDurationNs: 100 * Self.ms))
        #expect(parallel == "This query took 150 ms in api, under GET /x. Queries over 100 ms are flagged.")
        #expect(FindingPlace(services: ["api"], traceDurationNs: 100_000 * Self.ms).share(of: finding) == nil)
        let detail = finding.detailText(in: FindingPlace(services: ["api"], under: "GET /x", traceDurationNs: 0))
        #expect(detail == "This query took 150 ms in api, under GET /x. Queries over 100 ms are flagged.")
    }

    @Test("an N+1 across 3 services says \"3 services\"")
    func threeServices() throws {
        let spans = (0..<6).map { n in
            DetectorSpan(spanID: "q\(n)", name: "SELECT t", startNs: Int64(n), durationNs: 2 * Self.ms, dbSystem: "postgresql",
                         dbStatement: "SELECT * FROM t WHERE id = \(n)", serviceName: ["a", "b", "c"][n % 3])
        }
        let found = Detectors.findings(in: spans)
        let finding = try #require(found.findings.first)
        #expect(finding.services == ["a", "b", "c"])
        let place = FindingPlace(services: finding.services, under: "GET /x", traceDurationNs: 0)
        #expect(finding.line(in: place) == "N+1 · 6 times, 12 ms in all · SELECT t · 3 services · GET /x · SELECT * FROM t WHERE id = ?")
        #expect(found.summary.help(.nPlusOne) == "N+1: a statement ran 6 times in 3 services, 12 ms in all")
    }

    @Test("the first Error under a call is left out when it is the callee already named")
    func errorBelowIsCallee() throws {
        let shape = try #require(FindingShape.all["GET /stock/{sku}"])
        let placed = shape.placed.findings
        let client = try #require(placed.findings.first { $0.spanKind == .client })
        let place = try #require(placed.place(for: client))
        #expect(place.callee == "orders" && place.calleeRoute == "GET /v1/stock/{sku}")
        #expect(place.firstErrorBelow == nil)
        let root = try #require(placed.findings.first)
        #expect(placed.place(for: root)?.firstErrorBelow?.spanID == "8d3519c687ba673f")
        #expect(FindingPlaces.errorSpanIDs(FindingPlaces.build(placed, in: shape.placed.tree, trace: shape.trace))
                == ["8d3519c687ba673f"])
    }

    @Test("places cost little: 30,000 spans five levels deep, one N+1 of 22,001 runs and 36 Slow SQL")
    func cost() {
        let load = FindingPlaceLoad.make()
        let started = ContinuousClock.now
        let places = FindingPlaces.build(load.findings, in: load.tree, trace: nil)
        let elapsed = (ContinuousClock.now - started) / .milliseconds(1)
        #expect(places.count == 37)
        #expect(load.findings.findings.first { $0.kind == .nPlusOne }.flatMap { places[$0.id]?.under } == "GET /load")
        // Debug builds run far slower than the app's release build (the self-test's budget is 50 ms).
        #expect(elapsed < 1_000, "\(elapsed) ms")
    }
}

/// The places' cost input (`DetectorLoad.places` in the self-test builds the
/// same): 30,000 spans in five levels (root, 10 loads, 100 steps, 100
/// repositories, 29,789 leaves); 22,001 leaves run one statement, 36 are slow.
enum FindingPlaceLoad {
    static func make() -> (tree: Waterfall, findings: TraceFindings) {
        var spans = [WaterfallSpan(spanID: "root", name: "GET /load", kind: .server, startNs: 0, durationNs: 2_000_000_000,
                                   serviceName: "api")]
        var detector: [DetectorSpan] = []
        var leaf = 0
        for a in 0..<10 {
            spans.append(WaterfallSpan(spanID: "a\(a)", parentSpanID: "root", name: "Load\(a)", startNs: Int64(a), durationNs: 1,
                                       serviceName: "api"))
            for b in 0..<10 {
                let step = "b\(a)-\(b)", repository = "r\(a)-\(b)"
                spans.append(WaterfallSpan(spanID: step, parentSpanID: "a\(a)", name: "Step", startNs: Int64(b), durationNs: 1,
                                           serviceName: "api"))
                spans.append(WaterfallSpan(spanID: repository, parentSpanID: step, name: "Repository", startNs: Int64(b),
                                           durationNs: 1, serviceName: "api"))
                for _ in 0..<298 where spans.count < 30_000 {
                    let id = "l\(leaf)"
                    spans.append(WaterfallSpan(spanID: id, parentSpanID: repository, name: "SELECT items", kind: .client,
                                               startNs: Int64(leaf), durationNs: 1, serviceName: "api"))
                    if leaf < 22_001 {
                        detector.append(DetectorSpan(spanID: id, name: "SELECT items", startNs: Int64(leaf), durationNs: 1_000,
                                                     dbSystem: "postgresql", dbStatement: "SELECT * FROM items WHERE id = \(leaf)",
                                                     serviceName: "api"))
                    } else if leaf < 22_037 {
                        detector.append(DetectorSpan(spanID: id, name: "SELECT report", startNs: Int64(leaf),
                                                     durationNs: 150_000_000, dbSystem: "postgresql",
                                                     dbStatement: "SELECT * FROM report_\(leaf)", serviceName: "api"))
                    }
                    leaf += 1
                }
            }
        }
        return (Waterfall(spans: spans), Detectors.findings(in: detector))
    }
}
