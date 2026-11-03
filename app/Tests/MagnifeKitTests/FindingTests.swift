import Foundation
import GRDB
import Testing
@testable import MagnifeKit

/// The detectors (S-023+) as pure functions, and the reads that feed them.
@Suite("Findings")
struct FindingTests {
    static let ms: Int64 = 1_000_000

    private func db(_ id: String, _ durationNs: Int64, system: String? = "postgresql", statement: String? = nil,
                    start: Int64 = 0, trace: String = "t1") -> DetectorSpan {
        DetectorSpan(traceID: trace, spanID: id, name: "SELECT orders", startNs: start, durationNs: durationNs,
                     dbSystem: system, dbStatement: statement)
    }

    // MARK: Slow SQL (S-023)

    @Test("Slow SQL: a span with db_system over 100 ms, and only over it",
          arguments: [(100 * ms, false), (100 * ms + 1, true), (99 * ms, false), (340 * ms, true), (2_000 * ms, true)])
    func slowThreshold(durationNs: Int64, flagged: Bool) {
        let found = Detectors.findings(in: [db("a", durationNs)])
        #expect(found.kinds(forSpan: "a") == (flagged ? [.slowSQL] : []))
    }

    @Test("a long span without db_system is not Slow SQL")
    func notDatabase() {
        let span = DetectorSpan(spanID: "a", name: "GET /reports", durationNs: 900 * Self.ms, httpMethod: "GET")
        #expect(Detectors.findings(in: [span]).isEmpty)
    }

    @Test("several slow queries give one finding each, in start order")
    func several() {
        let found = Detectors.findings(in: [db("b", 200 * Self.ms, start: 20), db("a", 150 * Self.ms, start: 10),
                                            db("c", 5 * Self.ms, start: 30)])
        #expect(found.findings.map(\.spanIDs) == [["a"], ["b"]])
        #expect(found.summary.counts == [.slowSQL: 2])
        #expect(found.summary.help(.slowSQL) == "Slow SQL: 2 queries over 100 ms")
        #expect(Detectors.findings(in: [db("a", 150 * Self.ms)]).summary.help(.slowSQL) == "Slow SQL: 1 query over 100 ms")
        #expect(found.summary.spoken == "findings: Slow SQL")
    }

    @Test("Slow SQL words: strip line, span detail text, VoiceOver")
    func slowWords() throws {
        let statement = "SELECT *\n  FROM orders\n  WHERE id = 1"
        let finding = try #require(Detectors.findings(in: [db("a", 340 * Self.ms, statement: statement)]).findings.first)
        #expect(finding.line == "Slow SQL · 340 ms · SELECT * FROM orders WHERE id = 1")
        #expect(finding.detailText == "This query took 340 ms. Queries over 100 ms are flagged.")
        #expect(finding.shownStatement == statement)
        #expect(finding.accessibilityLabel == "Select span: Slow SQL, 340 milliseconds")
    }

    @Test("Slow SQL with no statement names the database and the span")
    func noStatement() throws {
        for statement in [nil, "", "  \n"] {
            let finding = try #require(Detectors.findings(in: [db("a", 340 * Self.ms, statement: statement)]).findings.first)
            #expect(finding.shownStatement == nil)
            #expect(finding.detailText == "This postgresql query took 340 ms. Queries over 100 ms are flagged.")
            #expect(finding.line == "Slow SQL · 340 ms · SELECT orders")
        }
    }

    @Test("a long statement is one line of at most 300 characters in the strip")
    func longLine() throws {
        let statement = "SELECT " + Array(repeating: "column_name,\n", count: 200).joined() + "id FROM t"
        let finding = try #require(Detectors.findings(in: [db("a", 340 * Self.ms, statement: statement)]).findings.first)
        let tail = finding.line.dropFirst("Slow SQL · 340 ms · ".count)
        #expect(tail.count == 301 && tail.hasSuffix("…") && !tail.contains("\n"))
    }

    @Test("a query just over 100 ms says so, in the strip, the span detail and VoiceOver",
          arguments: [100 * ms + 1, 100_400_000])
    func justOverThreshold(durationNs: Int64) throws {
        let finding = try #require(Detectors.findings(in: [db("a", durationNs, statement: "SELECT 1")]).findings.first)
        #expect(finding.durationText == "just over 100 ms")
        #expect(finding.line == "Slow SQL · just over 100 ms · SELECT 1")
        #expect(finding.detailText == "This query took just over 100 ms. Queries over 100 ms are flagged.")
        #expect(finding.accessibilityLabel == "Select span: Slow SQL, just over 100 milliseconds")
    }

    @Test("100.5 ms rounds to 101 ms; exactly 100 ms is no finding")
    func overThreshold() throws {
        let finding = try #require(Detectors.findings(in: [db("a", 100_500_000, statement: "SELECT 1")]).findings.first)
        #expect(finding.line == "Slow SQL · 101 ms · SELECT 1")
        #expect(finding.detailText == "This query took 101 ms. Queries over 100 ms are flagged.")
        #expect(Detectors.findings(in: [db("a", 100 * Self.ms)]).isEmpty)
    }

    @Test("counts group with a comma whatever the Mac's region")
    func countFormat() throws {
        // What the old words gave on a Mac set to these regions.
        for region in ["pt_BR", "en_BR", "de_DE"] {
            #expect(1_200.formatted(.number.locale(Locale(identifier: region))) == "1.200")
        }
        #expect(CountFormat.string(1_200) == "1,200")
        #expect(CountFormat.string(5) == "5")
        #expect(CountFormat.string(1_234_567) == "1,234,567")
        let found = Detectors.findings(in: items(1_200, ms: 1))
        let finding = try #require(found.findings.first)
        #expect(finding.line == "N+1 · 1,200 times · SELECT * FROM order_items WHERE order_id = ?")
        #expect(finding.detailText == "This statement ran 1,200 times in this trace.")
        #expect(finding.accessibilityLabel == "Select span: N+1, 1,200 times")
        #expect(finding.spokenMark(for: "i1199") == "N+1, 1,200 of 1,200")
        #expect(found.summary.help(.nPlusOne) == "N+1: a statement ran 1,200 times")
        let slow = Detectors.findings(in: (0..<1_200).map { db("s\($0)", 150 * Self.ms, start: Int64($0)) })
        #expect(slow.showAllTitle == "Show All Findings (1,200)")
        #expect(slow.summary.help(.slowSQL) == "Slow SQL: 1,200 queries over 100 ms")
    }

    @Test("findings by trace keep each trace's own")
    func byTrace() {
        let found = Detectors.findingsByTrace([db("a", 150 * Self.ms, trace: "t1"), db("b", 1 * Self.ms, trace: "t2")])
        #expect(found["t1"]?.count == 1)
        #expect(found["t2"]?.isEmpty == true)
    }

    // MARK: N+1 (S-024)

    private func items(_ count: Int, from start: Int64 = 0, ms: Int64 = 7) -> [DetectorSpan] {
        (0..<count).map { n in
            db("i\(n)", ms * Self.ms, statement: "SELECT * FROM order_items WHERE order_id = \(1042 + n)",
               start: start + Int64(n) * 10)
        }
    }

    @Test("N+1: the same normalized statement 5 or more times in a trace, and only then",
          arguments: [(4, false), (5, true), (8, true), (40, true)])
    func nPlusOneThreshold(count: Int, flagged: Bool) {
        let found = Detectors.findings(in: items(count))
        #expect(found.findings.filter { $0.kind == .nPlusOne }.count == (flagged ? 1 : 0))
    }

    @Test("N+1 gives one finding listing every repeated span, first by start")
    func nPlusOneSpans() throws {
        let spans = items(8).reversed() + [db("other", 6 * Self.ms, statement: "SELECT id FROM orders WHERE customer_id = 77")]
        let found = Detectors.findings(in: Array(spans))
        let finding = try #require(found.findings.first { $0.kind == .nPlusOne })
        #expect(found.findings.count == 1)
        #expect(finding.spanIDs == (0..<8).map { "i\($0)" })
        #expect(finding.count == 8)
        #expect(found.kinds(forSpan: "i3") == [.nPlusOne])
        #expect(found.kinds(forSpan: "other").isEmpty)
    }

    @Test("N+1 words: strip line, span detail, VoiceOver, tooltip")
    func nPlusOneWords() throws {
        let found = Detectors.findings(in: items(8))
        let finding = try #require(found.findings.first)
        #expect(finding.line == "N+1 · 8 times · SELECT * FROM order_items WHERE order_id = ?")
        #expect(finding.detailText == "This statement ran 8 times in this trace.")
        #expect(finding.shownStatement == "SELECT * FROM order_items WHERE order_id = ?")
        #expect(finding.accessibilityLabel == "Select span: N+1, 8 times")
        #expect(finding.spokenMark(for: "i0") == "N+1, 1 of 8")
        #expect(finding.spokenMark(for: "i2") == "N+1, 3 of 8")
        #expect(found.summary.help(.nPlusOne) == "N+1: a statement ran 8 times")
        #expect(found.summary.spoken == "findings: N+1")
    }

    @Test("two repeated statements give two findings; a span can be Slow SQL and N+1 at once")
    func nPlusOneTwice() {
        let users = (0..<5).map { n in
            db("u\(n)", n == 0 ? 150 * Self.ms : 3 * Self.ms, statement: "SELECT * FROM users WHERE id = '\(n)'",
               start: 1_000 + Int64(n))
        }
        let found = Detectors.findings(in: items(6) + users)
        #expect(found.findings.map(\.kind) == [.slowSQL, .nPlusOne, .nPlusOne])
        #expect(found.kinds(forSpan: "u0") == [.slowSQL, .nPlusOne])
        #expect(found.summary.counts == [.slowSQL: 1, .nPlusOne: 2])
        #expect(found.summary.help(.nPlusOne) == "N+1: 2 statements ran 5 or more times")
        #expect(found.summary.spoken == "findings: Slow SQL, N+1")
    }

    @Test("spans without a statement never make an N+1; different tables never group")
    func nPlusOneNegatives() {
        #expect(Detectors.findings(in: (0..<9).map { db("n\($0)", Self.ms, statement: nil) }).isEmpty)
        #expect(Detectors.findings(in: (0..<9).map { db("e\($0)", Self.ms, statement: "") }).isEmpty)
        let tables = (0..<9).map { db("t\($0)", Self.ms, statement: "SELECT * FROM t\($0) WHERE id = 1") }
        #expect(Detectors.findings(in: tables).isEmpty)
    }

    @Test("statements without db_system group like the reader's candidates; they are never Slow SQL")
    func nPlusOneStatementOnly() throws {
        let spans = (0..<5).map { n in
            db("s\(n)", 150 * Self.ms, system: nil, statement: "SELECT * FROM items WHERE id = \(n)", start: Int64(n))
        }
        let found = Detectors.findings(in: spans)
        #expect(found.findings.map(\.kind) == [.nPlusOne])
        #expect(try #require(found.findings.first).dbSystem == nil)
    }

    @Test("long IN lists of 4- and 5-digit ids, cut at 10,000 bytes, are one N+1")
    func nPlusOneLongLists() throws {
        let spans = (0..<6).map { n in
            let first = n.isMultiple(of: 2) ? 1_000 : 10_000
            let list = (first..<(first + 3_000)).map(String.init).joined(separator: ", ")
            return db("l\(n)", Self.ms, statement: "SELECT id FROM t WHERE id IN (\(list))", start: Int64(n))
        }
        let finding = try #require(Detectors.findings(in: spans).findings.first)
        #expect(finding.count == 6)
        #expect(finding.statement == "SELECT id FROM t WHERE id IN (? …")
    }

    // MARK: HTTP Error (S-025)

    private func http(_ id: String, kind: SpanKind = .server, name: String = "POST /payments", method: String? = "POST",
                      code: Int?, status: SpanStatus = .unset, message: String = "", route: String? = "/payments",
                      url: String? = nil) -> DetectorSpan {
        DetectorSpan(spanID: id, name: name, kind: kind, durationNs: Self.ms, status: status, statusMessage: message,
                     httpMethod: method, httpStatusCode: code, httpRoute: route, httpURL: url)
    }

    @Test("HTTP Error: a response code of 400 or higher, or status Error",
          arguments: [(200, SpanStatus.ok, false), (399, .unset, false), (400, .unset, true), (404, .unset, true),
                      (500, .error, true), (503, .unset, true), (200, .error, true), (302, .unset, false)])
    func httpRule(code: Int, status: SpanStatus, flagged: Bool) {
        #expect(Detectors.findings(in: [http("a", code: code, status: status)]).kinds(forSpan: "a") == (flagged ? [.httpError] : []))
    }

    @Test("only HTTP spans: a span with neither method nor code is never an HTTP Error")
    func httpOnly() {
        let job = DetectorSpan(spanID: "a", name: "inventory.reconcile", kind: .internal, durationNs: Self.ms, status: .error)
        #expect(Detectors.findings(in: [job]).isEmpty)
        // A code alone is enough.
        #expect(Detectors.findings(in: [http("b", method: nil, code: 502)]).kinds(forSpan: "b") == [.httpError])
    }

    @Test("HTTP Error words: method, route or URL, code")
    func httpWords() throws {
        let server = try #require(Detectors.findings(in: [http("a", code: 500, status: .error)]).findings.first)
        #expect(server.line == "HTTP Error · 500 · POST /payments")
        #expect(server.detailText == "POST /payments returned 500.")
        #expect(server.accessibilityLabel == "Select span: HTTP Error, POST /payments returned 500")
        #expect(server.spokenMark(for: "a") == "HTTP Error")

        let client = try #require(Detectors.findings(in: [
            http("b", kind: .client, name: "POST", code: nil, status: .error, message: "connection reset",
                 route: nil, url: "https://api.stripe.com/v1/charges"),
        ]).findings.first)
        #expect(client.line == "HTTP Error · POST https://api.stripe.com/v1/charges")
        #expect(client.detailText
                == "POST https://api.stripe.com/v1/charges has status Error and no response code. connection reset")

        let ok = try #require(Detectors.findings(in: [http("c", code: 200, status: .error)]).findings.first)
        #expect(ok.detailText == "POST /payments returned 200 and has status Error.")
    }

    @Test("client spans name the URL, server spans the route, else the span name, never the method twice")
    func httpTarget() throws {
        func call(_ span: DetectorSpan) throws -> String { try #require(Detectors.findings(in: [span]).findings.first).call }
        #expect(try call(http("a", kind: .client, name: "POST", code: 500, url: "http://localhost:5080/payments"))
                == "POST http://localhost:5080/payments")
        #expect(try call(http("b", kind: .server, code: 500, url: "/payments?x=1")) == "POST /payments")
        #expect(try call(http("d", kind: .server, name: "POST /pay", code: 500, route: nil, url: nil)) == "POST /pay")
        #expect(try call(http("e", kind: .server, name: "GET", method: "GET", code: 404, route: nil, url: nil)) == "GET")
        #expect(try call(http("f", kind: .client, name: "fetch", method: nil, code: 500, route: nil, url: "http://a/b"))
                == "http://a/b")
    }

    @Test("an empty URL or route counts as none, so the call falls back to the other, then the span name")
    func emptyURLFallsBackToRoute() throws {
        func call(_ span: DetectorSpan) throws -> String { try #require(Detectors.findings(in: [span]).findings.first).call }
        #expect(try call(http("a", kind: .client, name: "GET", method: "GET", code: 500, route: "/x", url: "")) == "GET /x")
        #expect(try call(http("b", kind: .server, name: "GET", method: "GET", code: 500, route: "", url: "/y")) == "GET /y")
        #expect(try call(http("c", kind: .client, name: "GET /z", method: "GET", code: 500, route: "", url: "")) == "GET /z")
    }

    @Test("several failed calls: one strip line each, and the badge counts them")
    func httpSeveral() {
        let found = Detectors.findings(in: [http("a", code: 500), http("b", kind: .client, code: 502, url: "http://x/y")])
        #expect(found.findings.map(\.kind) == [.httpError, .httpError])
        #expect(found.summary.help(.httpError) == "HTTP Error: 2 calls returned 400 or higher, or had status Error")
        #expect(Detectors.findings(in: [http("a", code: 500)]).summary.help(.httpError)
                == "HTTP Error: 1 call returned 400 or higher, or had status Error")
        #expect(found.summary.spoken == "findings: HTTP Error")
    }

    // MARK: Strip

    @Test("the strip shows 3 lines, then Show All Findings (7)")
    func strip() {
        let spans = (0..<7).map { db("s\($0)", 150 * Self.ms, start: Int64($0)) }
        let found = Detectors.findings(in: spans)
        #expect(found.shownInStrip(all: false).map(\.spanIDs.first) == ["s0", "s1", "s2"])
        #expect(found.shownInStrip(all: true).count == 7)
        #expect(found.showAllTitle == "Show All Findings (7)")
        #expect(Detectors.findings(in: Array(spans.prefix(3))).showAllTitle == nil)
    }

    // MARK: Cache

    @Test("the list's cache reads a trace again only when its updated_seq changes")
    func cache() {
        func row(_ id: String, seq: Int64) -> TraceSummary {
            TraceSummary(traceID: id, rootService: "web", route: "GET /", startNs: 0, durationNs: 1, spanCount: 1,
                         updatedSeq: seq)
        }
        var cache = FindingCache()
        let rows = [row("a", seq: 1), row("b", seq: 1)]
        #expect(cache.stale(rows).map(\.traceID) == ["a", "b"])
        let slow = FindingSummary(counts: [.slowSQL: 1])
        cache.store(["a": slow, "b": FindingSummary()], seqs: ["a": 1, "b": 1])
        #expect(cache.stale(rows).isEmpty)
        #expect(cache.summary(for: rows[0]) == slow)
        #expect(cache.summary(for: rows[1])?.isEmpty == true)
        // b received spans: only b is read again.
        let grown = [row("a", seq: 1), row("b", seq: 2)]
        #expect(cache.stale(grown).map(\.traceID) == ["b"])
        cache.store(["b": slow], seqs: ["b": 2])
        // An older read that finishes late never replaces a newer one.
        cache.store(["b": FindingSummary()], seqs: ["b": 1])
        #expect(cache.summary(for: grown[1]) == slow)
        cache.keep(only: ["b"])
        #expect(cache.count == 1)
    }

    // MARK: Reads

    @Test("the reader runs the detectors on a trace's database spans and on a page of traces")
    func reads() async throws {
        let dir = try TempDir("findings")
        defer { dir.remove() }
        let url = dir.file("magnife.sqlite")
        let writer = try makeWriter(at: url)
        let base: Int64 = 1_730_000_000_000_000_000
        try await writer.write { db in
            try insertTrace(db, id: traceID(1), startNs: base, durationNs: 900 * Self.ms)
            try insertTrace(db, id: traceID(2), startNs: base + 1_000_000_000)
            try insertDetectorSpan(db, trace: traceID(1), span: "00000000000000a1", start: base + 1, duration: 851 * Self.ms,
                                   system: "postgresql", statement: "SELECT 1")
            try insertDetectorSpan(db, trace: traceID(1), span: "00000000000000a2", start: base + 2, duration: 4 * Self.ms,
                                   system: "postgresql", statement: "SELECT 2")
            // Long, but not a database span.
            try insertDetectorSpan(db, trace: traceID(2), span: "00000000000000b1", start: base + 3, duration: 900 * Self.ms)
            try insertTrace(db, id: traceID(3), startNs: base + 2_000_000_000)
            try insertDetectorSpan(db, trace: traceID(3), span: "00000000000000c1", kind: 2, start: base + 4,
                                   duration: Self.ms, status: 2, method: "POST", code: 500, route: "/payments")
            try insertDetectorSpan(db, trace: traceID(3), span: "00000000000000c2", kind: 3, start: base + 5,
                                   duration: Self.ms, method: "GET", code: 200, url: "http://a/ok")
        }
        let reader = try await TelemetryReader.open(at: url)
        let findings = try await reader.traceFindings(traceID: traceID(1))
        #expect(findings.findings.map(\.spanIDs) == [["00000000000000a1"]])
        #expect(findings.findings.first?.statement == "SELECT 1")
        let summaries = try await reader.findingSummaries(traceIDs: [traceID(1), traceID(2), traceID(2)])
        #expect(summaries[traceID(1)]?.counts == [.slowSQL: 1])
        #expect(summaries[traceID(2)]?.isEmpty == true)
        let failed = try await reader.traceFindings(traceID: traceID(3))
        #expect(failed.findings.map(\.line) == ["HTTP Error · 500 · POST /payments"])
        #expect(try await reader.findingSummaries(traceIDs: []).isEmpty)

        // Both reads use an index on trace_id, never a scan of spans.
        let one: StatementArguments = [traceID(1)]
        let many: StatementArguments = ["[\"\(traceID(1))\"]"]
        let queries: [(String, StatementArguments)] = [(TelemetrySQL.detectorSpansOfTrace, one),
                                                       (TelemetrySQL.detectorSpansOfTraces, many)]
        for (sql, arguments) in queries {
            let plan: [String] = try await writer.read { db in
                try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql, arguments: arguments).map { row -> String in row["detail"] }
            }
            #expect(plan.contains { $0.contains("spans USING") && $0.contains("INDEX") }, "\(plan)")
            #expect(!plan.contains { $0.hasPrefix("SCAN spans") }, "\(plan)")
        }
    }

    @Test("an open trace reads its row, its spans and its findings in one read; a statement alone is a database span")
    func openTrace() async throws {
        let dir = try TempDir("open-trace")
        defer { dir.remove() }
        let url = dir.file("magnife.sqlite")
        let writer = try makeWriter(at: url)
        let base: Int64 = 1_730_000_000_000_000_000
        try await writer.write { db in
            try insertTrace(db, id: traceID(1), startNs: base, durationNs: 900 * Self.ms, spanCount: 6)
            // No db_system: an instrumentation that sends only the statement still groups (S-024).
            for n in 1...5 {
                try insertDetectorSpan(db, trace: traceID(1), span: String(format: "00000000000000%02x", n),
                                       parent: String(traceID(1).prefix(16)), start: base + Int64(n), duration: Self.ms,
                                       statement: "SELECT * FROM items WHERE id = \(n)")
            }
        }
        let reader = try await TelemetryReader.open(at: url)
        let read = try await reader.openTrace(traceID: traceID(1))
        #expect(read.trace?.traceID == traceID(1))
        #expect(read.spans.count == 6)
        #expect(read.findings.findings.map(\.kind) == [.nPlusOne])
        // Every span a finding names is in the spans read with it.
        let ids = Set(read.spans.map(\.spanID))
        #expect(read.findings.findings.allSatisfy { $0.spanIDs.allSatisfy(ids.contains) })
        #expect(try await reader.findingSummaries(traceIDs: [traceID(1)])[traceID(1)]?.counts == [.nPlusOne: 1])
        let missing = try await reader.openTrace(traceID: traceID(9))
        #expect(missing.trace == nil && missing.spans.isEmpty && missing.findings.findings.isEmpty)
    }
}

/// A span with the promoted columns the detectors read.
func insertDetectorSpan(_ db: Database, trace: String, span: String, parent: String? = nil, name: String = "span",
                        kind: Int = 3, start: Int64, duration: Int64, status: Int = 0, statusMessage: String = "",
                        system: String? = nil, statement: String? = nil, method: String? = nil, code: Int? = nil,
                        route: String? = nil, url: String? = nil, service: String = "checkout-api") throws {
    try db.execute(sql: "INSERT OR IGNORE INTO resources (id, hash, service_name, attributes) VALUES (?, ?, ?, ?)",
                   arguments: [abs(service.hashValue % 100_000), "hash-\(service)", service, "{}"])
    let resource = try Int64.fetchOne(db, sql: "SELECT id FROM resources WHERE service_name = ?", arguments: [service])!
    try db.execute(sql: """
        INSERT OR REPLACE INTO spans (trace_id, span_id, parent_span_id, name, kind, start_ns, end_ns, duration_ns,
            status_code, status_message, service_name, resource_id, db_system, db_statement, http_method,
            http_status_code, http_route, http_url, received_ns)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, arguments: [trace, span, parent, name, kind, start, start + duration, duration, status, statusMessage,
                         service, resource, system, statement, method, code, route, url, start])
}
