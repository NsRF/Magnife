import Foundation
import GRDB
import Testing
@testable import MagnifeKit

/// A span row as the helper stores it, for the span detail's rules.
func spanRecord(name: String = "POST /payments", kind: Int = 2, startNs: Int64 = 1_000_000_000,
                durationNs: Int64 = 52_000_000, status: Int = 2, message: String = "",
                attributes: String = "{}", events: String = "[]") throws -> SpanRecord {
    try SpanRecord(row: Row([
        "id": 1, "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736", "span_id": "00f067aa0ba902b7",
        "parent_span_id": nil, "name": name, "kind": kind, "start_ns": startNs, "end_ns": startNs + durationNs,
        "duration_ns": durationNs, "status_code": status, "status_message": message, "service_name": "checkout-api",
        "resource_id": 7, "scope_name": "", "scope_version": "", "attributes": attributes, "events": events,
        "links": "[]", "db_system": nil, "db_statement": nil, "http_method": nil, "http_status_code": nil,
        "http_route": nil, "http_url": nil, "received_ns": startNs,
    ]))
}

func resourceRecord(_ attributes: String) throws -> ResourceRecord {
    try ResourceRecord(row: Row(["id": 7, "service_name": "checkout-api", "attributes": attributes]))
}

@Suite("Span detail")
struct SpanDetailTests {
    @Test("http.* and db.* attributes come first, then the rest by key (design decision 5)")
    func attributeOrder() throws {
        let span = try spanRecord(attributes: #"""
            {"server.port":5080,"db.system.name":"postgresql","error.type":"x","http.route":"/payments",
             "aaa":"first by key","http.request.method":"POST","db.query.text":"SELECT 1","url.path":"/payments",
             "http_not_prefix":1,"dbx":2}
            """#)
        let detail = SpanDetail(span: span, resource: nil)
        #expect(detail.attributes.map(\.key) == [
            "http.request.method", "http.route", "db.query.text", "db.system.name",
            "aaa", "dbx", "error.type", "http_not_prefix", "server.port", "url.path",
        ])
    }

    @Test("resource attributes: service.* first, then by key")
    func resourceOrder() throws {
        let resource = try resourceRecord(#"{"host.name":"mac","service.version":"1.8.2","os.type":"darwin","service.name":"checkout-api"}"#)
        let detail = SpanDetail(span: try spanRecord(), resource: resource)
        #expect(detail.resourceAttributes.map(\.key) == ["service.name", "service.version", "host.name", "os.type"])
    }

    @Test("a section with nothing in it is left out")
    func emptySections() throws {
        let bare = SpanDetail(span: try spanRecord(), resource: nil)
        #expect(bare.sections.isEmpty)
        let attributesOnly = SpanDetail(span: try spanRecord(attributes: #"{"a":1}"#), resource: try resourceRecord("{}"))
        #expect(attributesOnly.sections == [.attributes])
        let all = SpanDetail(span: try spanRecord(attributes: #"{"a":1}"#, events: #"[{"time_ns":1,"name":"retry"}]"#),
                             resource: try resourceRecord(#"{"service.name":"x"}"#))
        #expect(all.sections == [.attributes, .events, .resource])
        #expect(all.sections.map(\.title) == ["Attributes", "Events", "Resource"])
    }

    @Test("events are listed in time order with their attributes")
    func eventOrder() throws {
        let span = try spanRecord(startNs: 1_000_000_000, events: #"""
            [{"time_ns":1012000000,"name":"second","attributes":{"message.id":2}},
             {"time_ns":1003000000,"name":"first","attributes":{"message.type":"RECEIVED"}},
             {"time_ns":1012000000,"name":"tie","attributes":{}}]
            """#)
        let detail = SpanDetail(span: span, resource: nil)
        #expect(detail.events.map(\.name) == ["first", "second", "tie"])
        #expect(detail.events[0].attributes["message.type"] == .string("RECEIVED"))
        #expect(detail.offsetText(detail.events[0].timeNs) == "at 3.0 ms")
        #expect(detail.offsetText(detail.events[1].timeNs) == "at 12 ms")
        #expect(detail.offsetText(999_000_000) == "at −1.0 ms")
    }

    @Test("the header line reads kind, duration and status")
    func summary() throws {
        #expect(SpanDetail(span: try spanRecord(), resource: nil).summary == "Server · 52 ms · Error")
        #expect(SpanDetail(span: try spanRecord(kind: 3, durationNs: 1_240_000_000, status: 1), resource: nil).summary
                == "Client · 1.24 s · OK")
        #expect(SpanDetail(span: try spanRecord(kind: 1, durationNs: 850_000, status: 0), resource: nil).summary
                == "Internal · 850 µs · Unset")
    }

    @Test("VoiceOver reads a pair as \"key, value\"")
    func spokenPair() {
        #expect(SpanDetail.accessibilityLabel(Attribute("http.route", .string("/payments"))) == "http.route, /payments")
        #expect(SpanDetail.accessibilityLabel(Attribute("server.port", .int(5080))) == "server.port, 5080")
    }

    @Test("exception events keep their other attributes")
    func exceptionAttributes() throws {
        let span = try spanRecord(events: #"""
            [{"time_ns":5,"name":"exception","attributes":{"exception.type":"E","exception.escaped":true}}]
            """#)
        let exception = try #require(span.exceptions.first)
        #expect(exception.attributes == [Attribute("exception.escaped", .bool(true))])
    }
}
