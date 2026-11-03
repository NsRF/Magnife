import Foundation
import Testing
@testable import MagnifeKit

/// The detector edge set through the real pipeline (detector audit §A.4):
/// `MAGNIFE_EDGE_STORE=<db>` names a store the helper filled from
/// `send-sample-traces --edges` (the seed set's finding traces are checked
/// too when present). Each trace is read the way `AppModel.readWaterfall`
/// reads it, and every string must be §10's. Skipped without the variable,
/// like `MAGNIFE_PERF_STORES`. `MAGNIFE_FINDINGS_DUMP=<file>` also writes
/// what each trace says as JSON, for a verifier to compare.
@Suite("Edge store goldens")
struct EdgeStoreGoldenTests {
    struct Dump: Encodable {
        struct Line: Encodable {
            var kind: String
            var line: String
            var detail: String
            var label: String
            var rowHelp: [String]
            var spokenMarks: [String]
        }

        var traceID: String
        var route: String
        var findings: [Line]
        var help: [String: String]
        var spoken: String?
    }

    @Test("every edge trace in the store says what §10 says (MAGNIFE_EDGE_STORE)")
    func edgeStore() async throws {
        guard let path = ProcessInfo.processInfo.environment["MAGNIFE_EDGE_STORE"], !path.isEmpty else { return }
        let reader = try await TelemetryReader.open(at: URL(fileURLWithPath: path))
        let traces = try await reader.latestTraces(limit: 1_000)
        var dumps: [Dump] = []
        var totals: [FindingKind: Int] = [:]
        for (route, traceID) in FindingGolden.edgeTraceIDs {
            #expect(traces.contains { $0.traceID == traceID && $0.route == route }, "\(route) \(traceID) is stored")
        }
        let goldens = FindingGolden.edges.merging(FindingGolden.seed) { edge, _ in edge }
        for trace in traces {
            guard let golden = goldens[trace.route] else { continue }
            let read = try await reader.openTrace(traceID: trace.traceID)
            let tree = await Waterfall.build(read.spans)
            let findings = try await reader.placedFindings(read.findings, in: tree, trace: read.trace, traceID: trace.traceID)
            let summary = try #require(try await reader.findingSummaries(traceIDs: [trace.traceID])[trace.traceID])
            let differences = golden.differences(findings, summary: summary)
            #expect(differences.isEmpty, "\(trace.route):\n\(differences.joined(separator: "\n"))")
            #expect(summary == findings.summary, "the list's badges and the open trace agree")
            if FindingGolden.edges[trace.route] != nil {
                for (kind, count) in summary.counts { totals[kind, default: 0] += count }
            }
            dumps.append(Self.dump(trace, findings, summary))
        }
        #expect(totals == [.slowSQL: 4, .nPlusOne: 3, .httpError: 9], "\(totals)")
        if let out = ProcessInfo.processInfo.environment["MAGNIFE_FINDINGS_DUMP"], !out.isEmpty {
            try Self.write(dumps, to: out)
        }
    }

    /// `MAGNIFE_DUMP_STORE=<db> MAGNIFE_FINDINGS_DUMP=<file>`: what every
    /// trace of any store says, with no golden to match (probe stores).
    @Test("every trace of a store, dumped (MAGNIFE_DUMP_STORE)")
    func dumpStore() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["MAGNIFE_DUMP_STORE"], !path.isEmpty, let out = env["MAGNIFE_FINDINGS_DUMP"], !out.isEmpty else { return }
        let reader = try await TelemetryReader.open(at: URL(fileURLWithPath: path))
        var dumps: [Dump] = []
        for trace in try await reader.latestTraces(limit: 10_000) {
            let read = try await reader.openTrace(traceID: trace.traceID)
            let tree = await Waterfall.build(read.spans)
            let findings = try await reader.placedFindings(read.findings, in: tree, trace: read.trace, traceID: trace.traceID)
            let summary = try await reader.findingSummaries(traceIDs: [trace.traceID])[trace.traceID] ?? FindingSummary()
            #expect(summary == findings.summary, "\(trace.route): the list's badges and the open trace agree")
            dumps.append(Self.dump(trace, findings, summary))
        }
        try Self.write(dumps, to: out)
    }

    static func dump(_ trace: TraceSummary, _ findings: TraceFindings, _ summary: FindingSummary) -> Dump {
        Dump(traceID: trace.traceID, route: trace.route, findings: findings.findings.map { finding in
            let place = findings.place(for: finding)
            return Dump.Line(kind: finding.kind.title, line: finding.line(in: place), detail: finding.detailText(in: place),
                             label: finding.accessibilityLabel(in: place),
                             rowHelp: finding.spanIDs.map { finding.rowHelp(for: $0) },
                             spokenMarks: finding.spanIDs.map { finding.spokenMark(for: $0) })
        }, help: Dictionary(uniqueKeysWithValues: summary.kinds.map { ($0.title, summary.help($0)) }), spoken: summary.spoken)
    }

    static func write(_ dumps: [Dump], to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(dumps.sorted { $0.traceID < $1.traceID }).write(to: URL(fileURLWithPath: path))
    }
}
