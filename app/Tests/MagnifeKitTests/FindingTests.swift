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

    @Test("findings by trace keep each trace's own")
    func byTrace() {
        let found = Detectors.findingsByTrace([db("a", 150 * Self.ms, trace: "t1"), db("b", 1 * Self.ms, trace: "t2")])
        #expect(found["t1"]?.count == 1)
        #expect(found["t2"]?.isEmpty == true)
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
        }
        let reader = try await TelemetryReader.open(at: url)
        let findings = try await reader.traceFindings(traceID: traceID(1))
        #expect(findings.findings.map(\.spanIDs) == [["00000000000000a1"]])
        #expect(findings.findings.first?.statement == "SELECT 1")
        let summaries = try await reader.findingSummaries(traceIDs: [traceID(1), traceID(2), traceID(2)])
        #expect(summaries[traceID(1)]?.counts == [.slowSQL: 1])
        #expect(summaries[traceID(2)]?.isEmpty == true)
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
