import Foundation
import GRDB
import Testing
@testable import MagnifeKit

/// Failure notifications (S-028): the words, the coalescing per service
/// within 10 seconds, when permission is asked, and the reader's read.
@Suite("Failure notifications")
struct FailureNotificationTests {
    private let start = Date(timeIntervalSince1970: 1_730_000_000)

    private func failed(_ n: Int, route: String = "POST /orders", service: String = "checkout-api") -> FailedTrace {
        FailedTrace(traceID: traceID(n), route: route, service: service,
                    exceptionType: "InvalidOperationException", exceptionMessage: "Cart is empty")
    }

    @Test("a single banner reads route, service and the exception (docs/ux.md)")
    func singleWords() {
        let notice = FailureNotice.single(failed(1), id: "failure-1")
        #expect(notice.title == "POST /orders")
        #expect(notice.subtitle == "checkout-api")
        #expect(notice.body == "InvalidOperationException: Cart is empty")
        #expect(notice.threadID == "checkout-api" && notice.traceID == traceID(1) && notice.count == 1)
    }

    @Test("without an exception the body names the Error span")
    func detail() {
        var trace = FailedTrace(traceID: "t", route: "POST /orders", service: "checkout-api", errorSpanName: "charge-card")
        #expect(trace.detail == "Error in span charge-card")
        trace.exceptionType = "TimeoutError"
        #expect(trace.detail == "TimeoutError")
        trace.exceptionType = ""
        trace.exceptionMessage = "upstream timed out"
        #expect(trace.detail == "upstream timed out")
        #expect(FailedTrace(traceID: "t", route: "r", service: "s").detail == "Error")
    }

    @Test("a flood of 20,000 failures from one service coalesces in linear time (S-030)")
    func flood() {
        var coalescer = FailureCoalescer()
        let started = ContinuousClock.now
        var posted = 0
        for n in 1...20_000 { posted += coalescer.add(failed(n), at: start.addingTimeInterval(Double(n) / 10_000)).count }
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(posted == 1)
        #expect(coalescer.flush(at: start.addingTimeInterval(12)).first?.title == "20000 traces with errors")
    }

    @Test("a burst within 10 seconds posts one banner, then one follow-up naming the count")
    func burst() {
        var coalescer = FailureCoalescer()
        let first = coalescer.add(failed(1), at: start)
        #expect(first.map(\.title) == ["POST /orders"])
        for n in 2...5 {
            #expect(coalescer.add(failed(n, route: "GET /cart/\(n)"), at: start.addingTimeInterval(Double(n))).isEmpty)
        }
        #expect(coalescer.flush(at: start.addingTimeInterval(9.9)).isEmpty)
        #expect(coalescer.nextDeadline == start.addingTimeInterval(10))
        let followUp = coalescer.flush(at: start.addingTimeInterval(10))
        #expect(followUp.count == 1)
        #expect(followUp.first?.id == first.first?.id, "the follow-up replaces the banner")
        #expect(followUp.first?.title == "5 traces with errors")
        #expect(followUp.first?.subtitle == "checkout-api")
        #expect(followUp.first?.body == "Newest: GET /cart/5")
        #expect(followUp.first?.traceID == traceID(5), "clicking a burst opens its newest trace")
        // A quiet window ends the burst; the next failure starts another with a new id.
        #expect(coalescer.flush(at: start.addingTimeInterval(20)).isEmpty)
        #expect(coalescer.nextDeadline == nil)
        let next = coalescer.add(failed(6), at: start.addingTimeInterval(21))
        #expect(next.count == 1 && next.first?.id != first.first?.id && next.first?.count == 1)
    }

    @Test("one trace alone posts no follow-up")
    func single() {
        var coalescer = FailureCoalescer()
        #expect(coalescer.add(failed(1), at: start).count == 1)
        #expect(coalescer.flush(at: start.addingTimeInterval(10)).isEmpty)
        #expect(coalescer.nextDeadline == nil)
    }

    @Test("each service has its own window and thread")
    func perService() {
        var coalescer = FailureCoalescer()
        let a = coalescer.add(failed(1), at: start)
        let b = coalescer.add(failed(2, service: "orders"), at: start.addingTimeInterval(1))
        #expect(a.first?.threadID == "checkout-api" && b.first?.threadID == "orders")
        #expect(a.first?.id != b.first?.id)
        #expect(coalescer.add(failed(3), at: start.addingTimeInterval(2)).isEmpty)
        let due = coalescer.flush(at: start.addingTimeInterval(11))
        #expect(due.map(\.subtitle) == ["checkout-api"] && due.first?.count == 2)
    }

    @Test("a steady stream keeps one notification per burst, at most one every 10 seconds")
    func steadyStream() {
        var coalescer = FailureCoalescer()
        var posted: [FailureNotice] = []
        for second in 0..<35 {
            let now = start.addingTimeInterval(Double(second))
            posted += coalescer.add(failed(second + 1), at: now)
        }
        posted += coalescer.flush(at: start.addingTimeInterval(60))
        // At 0 s the banner, then follow-ups at 10, 20, 30 and the last window's end.
        #expect(posted.count == 5, "\(posted.map(\.title))")
        #expect(Set(posted.map(\.id)).count == 1)
        #expect(posted.last?.title == "35 traces with errors")
    }

    @Test("a trace reported twice counts once")
    func duplicate() {
        var coalescer = FailureCoalescer()
        _ = coalescer.add(failed(1), at: start)
        _ = coalescer.add(failed(1), at: start.addingTimeInterval(1))
        #expect(coalescer.flush(at: start.addingTimeInterval(10)).isEmpty)
    }

    @Test("follow-ups that are due go out before the next banner")
    func dueFirst() {
        var coalescer = FailureCoalescer(window: 10, idPrefix: "run")
        _ = coalescer.add(failed(1), at: start)
        _ = coalescer.add(failed(2), at: start.addingTimeInterval(1))
        let notices = coalescer.add(failed(3, service: "orders"), at: start.addingTimeInterval(12))
        #expect(notices.map(\.title) == ["2 traces with errors", "POST /orders"])
        #expect(notices.allSatisfy { $0.id.hasPrefix("run-") })
    }

    @Test("reset forgets open bursts")
    func reset() {
        var coalescer = FailureCoalescer()
        _ = coalescer.add(failed(1), at: start)
        _ = coalescer.add(failed(2), at: start.addingTimeInterval(1))
        coalescer.reset()
        #expect(coalescer.flush(at: start.addingTimeInterval(10)).isEmpty && coalescer.nextDeadline == nil)
    }

    @Test("permission is asked once, on the first failure, only while the setting is on")
    func permission() {
        #expect(NotificationPermission.notDetermined.action(isEnabled: true, askedThisRun: false) == .ask)
        #expect(NotificationPermission.notDetermined.action(isEnabled: true, askedThisRun: true) == .drop)
        #expect(NotificationPermission.notDetermined.action(isEnabled: false, askedThisRun: false) == .drop)
        #expect(NotificationPermission.authorized.action(isEnabled: true, askedThisRun: false) == .post)
        #expect(NotificationPermission.authorized.action(isEnabled: false, askedThisRun: false) == .drop)
        #expect(NotificationPermission.denied.action(isEnabled: true, askedThisRun: false) == .drop)
    }

    @Test("Settings' status line (docs/ux.md)")
    func statusLine() {
        #expect(NotificationPermission.notDetermined.statusLine
                == "Magnife asks for permission when the first trace with an error arrives.")
        #expect(NotificationPermission.denied.statusLine == "Notifications for Magnife are off in System Settings.")
        #expect(NotificationPermission.authorized.statusLine == nil)
    }

    @Test("the reader reads a batch's traces with errors and their first exception")
    func reader() async throws {
        let dir = try TempDir("failed-traces")
        defer { dir.remove() }
        let url = dir.file("magnife.sqlite")
        let writer = try makeWriter(at: url)
        let exception = #"[{"time_ns":5,"name":"exception","attributes":{"exception.type":"InvalidOperationException","exception.message":"Cart is empty"}}]"#
        try await writer.write { db in
            try insertTrace(db, id: traceID(1), route: "POST /orders", startNs: 100, status: 2)
            // Error spans in start order: one without an exception, then one with.
            try insertSpan(db, trace: traceID(1), span: "s1", parent: String(traceID(1).prefix(16)), name: "charge-card",
                           service: "payments", startNs: 110, durationNs: 5, status: 2)
            try insertSpan(db, trace: traceID(1), span: "s2", parent: "s1", name: "validate", service: "payments",
                           startNs: 120, durationNs: 5, status: 2, events: exception)
            try insertTrace(db, id: traceID(2), route: "GET /cart", startNs: 50, status: 2)
            try insertSpan(db, trace: traceID(2), span: "s3", parent: String(traceID(2).prefix(16)), name: "load-cart",
                           service: "cart", startNs: 40, durationNs: 5, status: 2)
            try insertTrace(db, id: traceID(3), route: "GET /", startNs: 10, status: 1)
        }
        let reader = try await TelemetryReader.open(at: url)
        let traces = try await reader.failedTraces(ids: [traceID(1), traceID(2), traceID(3), traceID(9)])
        #expect(traces.map(\.traceID) == [traceID(2), traceID(1)], "oldest first; OK and missing traces left out")
        #expect(traces.last?.detail == "InvalidOperationException: Cart is empty")
        #expect(traces.last?.service == "checkout-api" && traces.last?.route == "POST /orders")
        #expect(traces.last?.errorSpanName == "POST /orders", "the root is the earliest Error span")
        #expect(traces.first?.detail == "Error in span load-cart")
        #expect(try await reader.failedTraces(ids: []).isEmpty)
        _ = writer
    }
}
