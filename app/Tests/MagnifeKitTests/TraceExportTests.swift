import Foundation
import GRDB
import Testing
@testable import MagnifeKit

/// File > Export Trace… (v0.2). The export of a fixed trace is checked byte
/// for byte against `ingest/internal/receiver/testdata/magnife-export.jsonl`,
/// which the Go helper's TestImportMagnifeExport imports: a change to either
/// side's OTLP JSON fails one of the two tests. MAGNIFE_UPDATE_GOLDEN=1
/// rewrites the file.
@Suite("Trace export")
struct TraceExportTests {
    static let golden: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "ingest/internal/receiver/testdata/magnife-export.jsonl")

    static let trace = "4bf92f3577b34da6a3ce929d0e0e4736"
    static let root = "00f067aa0ba902b7"
    static let child = "53995c3f42cd8ad8"

    /// A two-service trace with every attribute type, an exception, a link,
    /// an error status, and logs with and without a span.
    static func makeStore() async throws -> (TempDir, TelemetryReader) {
        let dir = try TempDir("export")
        let url = dir.file("m.sqlite")
        let writer = try makeWriter(at: url)
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO resources (id, hash, service_name, attributes) VALUES
                  (1, 'h1', 'checkout-api', '{"host.name":"mac.local","service.name":"checkout-api","telemetry.sdk.language":"dotnet"}'),
                  (2, 'h2', 'payments', '{"service.name":"payments","service.version":"1.4.0"}')
                """)
            let base: Int64 = 1_793_000_000_000_000_000
            try db.execute(sql: """
                INSERT INTO spans (trace_id, span_id, parent_span_id, name, kind, start_ns, end_ns, duration_ns,
                    status_code, status_message, service_name, resource_id, scope_name, scope_version,
                    attributes, events, links, http_method, http_route, received_ns)
                VALUES (?, ?, NULL, 'POST /checkout', 2, ?, ?, 120000000, 2, '', 'checkout-api', 1,
                    'Microsoft.AspNetCore', '8.0.0',
                    '{"http.request.method":"POST","http.response.status_code":500,"http.route":"/checkout","retry":false,"sampled.ratio":0.25,"tags":["a",1,true],"user":{"id":42,"plan":"pro"},"empty":null}',
                    '[]', ?, 'POST', '/checkout', ?)
                """, arguments: [trace, root, base, base + 120_000_000,
                                 #"[{"trace_id":"0af7651916cd43dd8448eb211c80319c","span_id":"b7ad6b7169203331","attributes":{"link.kind":"retry"}}]"#,
                                 base])
            try db.execute(sql: """
                INSERT INTO spans (trace_id, span_id, parent_span_id, name, kind, start_ns, end_ns, duration_ns,
                    status_code, status_message, service_name, resource_id, scope_name, scope_version,
                    attributes, events, links, received_ns)
                VALUES (?, ?, ?, 'charge card', 3, ?, ?, 80000000, 2, 'card declined', 'payments', 2, 'payments.client', '',
                    '{"payment.amount":1999}', ?, '[]', ?)
                """, arguments: [trace, child, root, base + 20_000_000, base + 100_000_000,
                                 #"[{"time_ns":\#(base + 90_000_000),"name":"exception","attributes":{"exception.message":"card declined","exception.stacktrace":"at Pay()\n  at Main()","exception.type":"CardError"}}]"#,
                                 base])
            try db.execute(sql: """
                INSERT INTO logs (time_ns, observed_ns, severity_number, severity_text, service_name, resource_id,
                    scope_name, body, attributes, trace_id, span_id, event_name, received_ns) VALUES
                  (?, ?, 17, 'Error', 'payments', 2, 'payments.client', 'charge failed: card declined', '{"order.id":"A-17"}', ?, ?, '', ?),
                  (?, 0, 9, 'Information', 'checkout-api', 1, '', '{"msg":"checkout done"}', '{}', ?, NULL, 'checkout.done', ?)
                """, arguments: [base + 95_000_000, base + 95_000_100, trace, child, base,
                                 base + 119_000_000, trace, base])
        }
        return (dir, try await TelemetryReader.open(at: url))
    }

    @Test("the export matches the golden file the Go import test reads")
    func golden() async throws {
        let (dir, reader) = try await Self.makeStore()
        defer { dir.remove() }
        let export = try #require(try await reader.exportTrace(traceID: Self.trace))
        #expect(export.spanCount == 2)
        #expect(export.logCount == 2)
        if ProcessInfo.processInfo.environment["MAGNIFE_UPDATE_GOLDEN"] == "1" {
            try export.data.write(to: Self.golden)
        }
        let golden = try Data(contentsOf: Self.golden)
        #expect(export.data == golden, "export differs from \(Self.golden.path); MAGNIFE_UPDATE_GOLDEN=1 rewrites it")
    }

    @Test("one traces line and one logs line, in the OTLP/JSON encoding")
    func shape() async throws {
        let (dir, reader) = try await Self.makeStore()
        defer { dir.remove() }
        let export = try #require(try await reader.exportTrace(traceID: Self.trace))
        let lines = String(decoding: export.data, as: UTF8.self).split(separator: "\n")
        #expect(lines.count == 2)
        let traces = try #require(try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        let resourceSpans = try #require(traces["resourceSpans"] as? [[String: Any]])
        #expect(resourceSpans.count == 2, "one group per resource")

        let first = try #require((resourceSpans[0]["scopeSpans"] as? [[String: Any]])?.first)
        #expect((first["scope"] as? [String: String]) == ["name": "Microsoft.AspNetCore", "version": "8.0.0"])
        let span = try #require((first["spans"] as? [[String: Any]])?.first)
        #expect(span["traceId"] as? String == Self.trace)
        #expect(span["parentSpanId"] == nil)
        #expect(span["startTimeUnixNano"] as? String == "1793000000000000000", "64-bit integers are strings")
        #expect(span["kind"] as? Int == 2)
        let attributes = try #require(span["attributes"] as? [[String: Any]])
        func value(_ key: String) -> [String: Any]? { attributes.first { $0["key"] as? String == key }?["value"] as? [String: Any] }
        #expect(value("http.response.status_code")?["intValue"] as? String == "500")
        #expect(value("sampled.ratio")?["doubleValue"] as? Double == 0.25)
        #expect(value("retry")?["boolValue"] as? Bool == false)
        #expect(value("empty")?.isEmpty == true, "an empty value has no field")
        #expect((value("tags")?["arrayValue"] as? [String: Any])?["values"] as? [[String: Any]] != nil)
        #expect((value("user")?["kvlistValue"] as? [String: Any])?["values"] as? [[String: Any]] != nil)

        let logs = try #require(try JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any])
        #expect((logs["resourceLogs"] as? [[String: Any]])?.count == 2)
    }

    @Test("a trace without stored spans exports nothing")
    func missing() async throws {
        let (dir, reader) = try await Self.makeStore()
        defer { dir.remove() }
        #expect(try await reader.exportTrace(traceID: String(repeating: "0", count: 31) + "1") == nil)
    }

    @Test("file names come from the service and route", arguments: [
        ("checkout-api", "GET /reports/sales", "checkout-api GET reports sales 4bf92f35.jsonl"),
        ("web", "POST /payments?x=1", "web POST payments x 1 4bf92f35.jsonl"),
        ("", "///", "trace 4bf92f35.jsonl"),
    ])
    func fileName(service: String, route: String, expected: String) {
        let summary = TraceSummary(traceID: Self.trace, rootService: service, route: route, startNs: 0,
                                   durationNs: 0, spanCount: 1)
        #expect(TraceExport.suggestedFileName(for: summary) == expected)
    }
}
