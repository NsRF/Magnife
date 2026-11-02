import AppKit
import MagnifeKit

/// S-007: exceptions in the span detail. The seed set's .NET and Go
/// exceptions, then a span sent to the seed helper with three exception
/// events out of time order (one without a stack trace, one of 42 lines).
extension SelfTest {
    static func checkExceptions(_ model: AppModel) async {
        model.sidebar = .allTraces
        await model.reload()
        await checkSeedExceptions(model)
        await checkSeveralExceptions(model)
        model.selectedTraceID = nil
    }

    private static func trace(_ model: AppModel, route: String) async -> String? {
        try? await model.reader?.latestTraces(limit: 2_000).first { $0.route == route }?.traceID
    }

    private static func checkSeedExceptions(_ model: AppModel) async {
        guard let payments = await openSpan(model, trace: await trace(model, route: "POST /checkout/pay"),
                                            where: { $0.name == "POST /payments" }) else {
            return check("the failed checkout-api span opens", false)
        }
        let dotnet = payments.exceptions.first
        check("an Error span opens on Exception, first in the span detail",
              payments.sections.first == .exception && payments.exceptions.count == 1)
        check("the exception block has type, message and stack trace",
              dotnet?.type == "Microsoft.EntityFrameworkCore.DbUpdateException"
                && dotnet?.message.hasPrefix("An error occurred while saving the entity changes.") == true
                && dotnet?.stackTrace.contains("PaymentService.cs:line 87") == true)
        check("a stack trace over 20 lines shows the first 20 with Show All",
              (dotnet?.stackTraceLines.count ?? 0) > 20 && dotnet?.stackTracePreview()?.split(separator: "\n", omittingEmptySubsequences: false).count == 20,
              "\(dotnet?.stackTraceLines.count ?? 0) lines")
        check("Edit > Copy Stack Trace is enabled for it", MenuState.shared.hasStackTrace
              && menuItem("Copy Stack Trace")?.menu?.title == "Edit")

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("Magnife.selftest.stack"))
        model.copyStackTrace(at: 0, to: pasteboard)
        check("Copy Stack Trace copies the whole stack trace, not the first 20 lines",
              pasteboard.string(forType: .string) == dotnet?.stackTrace && model.copiedStackTrace == 0)
        try? await Task.sleep(for: .seconds(2.2))
        check("the button reads Copied for 2 seconds", model.copiedStackTrace == nil)

        guard let job = await openSpan(model, trace: await trace(model, route: "inventory.reconcile"),
                                       where: { $0.parentSpanID == nil }) else {
            return check("the Go job's span opens", false)
        }
        check("a short stack trace shows whole", job.exceptions.first?.type == "*fmt.wrapError"
              && job.exceptions.first?.stackTracePreview() == nil && job.exceptions.first?.hasStackTrace == true)

        guard let query = await openSpan(model, trace: await trace(model, route: "GET /admin/reports"),
                                         where: { $0.name == "SELECT Orders" }) else {
            return check("the slow query's span opens", false)
        }
        check("no exception means no Exception section, and Copy Stack Trace is disabled",
              !query.sections.contains(.exception) && !MenuState.shared.hasStackTrace)
    }

    private static func checkSeveralExceptions(_ model: AppModel) async {
        guard let http = ProcessInfo.processInfo.environment["APP_SEED_HTTP"]?.split(separator: ":").last.flatMap({ Int($0) }),
              let reader = model.reader else {
            return check("APP_SEED_HTTP names the seed helper (tools/selftest.sh)", false)
        }
        let trace = "5e1f7e57000000000000000000000007"
        let spanID = "5e1f7e5700000c01"
        let start = UInt64(Date().timeIntervalSince1970 * 1e9)
        let long = (1...42).map { "   at Checkout.Worker.Step\($0)() in /src/Worker.cs:line \($0)" }.joined(separator: "\\n")
        func value(_ key: String, _ text: String) -> String {
            #"{"key":"\#(key)","value":{"stringValue":"\#(text)"}}"#
        }
        func exception(at ms: UInt64, type: String, message: String, stack: String?) -> String {
            let attributes = [value("exception.type", type), value("exception.message", message)]
                + (stack.map { [value("exception.stacktrace", $0)] } ?? [])
            return #"{"timeUnixNano":"\#(start + ms * 1_000_000)","name":"exception","attributes":[\#(attributes.joined(separator: ","))]}"#
        }
        // Sent out of time order: the detail stacks them by time.
        let events = [
            exception(at: 30, type: "System.TimeoutException", message: "third", stack: "   at Checkout.Retry()"),
            exception(at: 10, type: "Npgsql.PostgresException", message: "first", stack: long),
            exception(at: 20, type: "System.InvalidOperationException", message: "second", stack: nil),
            #"{"timeUnixNano":"\#(start + 15_000_000)","name":"retry","attributes":[\#(value("attempt", "2"))]}"#,
        ]
        let status = await post(port: http, path: "/v1/traces", body: """
            {"resourceSpans":[{"resource":{"attributes":[\(value("service.name", "selftest"))]},
            "scopeSpans":[{"spans":[{"traceId":"\(trace)","spanId":"\(spanID)","name":"POST /retry","kind":2,
            "startTimeUnixNano":"\(start)","endTimeUnixNano":"\(start + 40_000_000)","status":{"code":2},
            "attributes":[\(value("http.route", "/retry"))],"events":[\(events.joined(separator: ","))]}]}]}]}
            """)
        var stored = false
        for _ in 0..<50 where !stored {
            stored = (try? await reader.trace(id: trace)) != nil
            if !stored { try? await Task.sleep(for: .milliseconds(100)) }
        }
        guard status == 200, stored else { return check("the span with three exceptions is stored", false, "\(status)") }
        await model.reload()
        guard let detail = await openSpan(model, trace: trace, where: { $0.spanID == spanID }) else {
            return check("the span with three exceptions opens", false)
        }
        let exceptions = detail.exceptions
        check("several exceptions each show, stacked in time order",
              exceptions.map(\.message) == ["first", "second", "third"]
                && exceptions.map { detail.offsetText($0.timeNs) } == ["at 10 ms", "at 20 ms", "at 30 ms"],
              "\(exceptions.map(\.message))")
        check("exception events are not listed again in Events",
              detail.sections == [.exception, .attributes, .events, .resource] && detail.events.map(\.name) == ["retry"],
              "\(detail.sections)")
        check("a missing stack trace shows type and message only",
              exceptions.count == 3 && !exceptions[1].hasStackTrace && exceptions[1].type == "System.InvalidOperationException")
        check("VoiceOver reads \"stack trace, 42 lines\"", exceptions.first?.stackTraceAccessibilityLabel == "stack trace, 42 lines",
              exceptions.first?.stackTraceAccessibilityLabel ?? "")

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("Magnife.selftest.stack"))
        model.copyStackTrace(at: 2, to: pasteboard)
        check("each exception's Copy Stack Trace copies its own", pasteboard.string(forType: .string) == "   at Checkout.Retry()"
              && model.copiedStackTrace == 2)
        model.copyStackTrace(at: 1, to: pasteboard)
        check("an exception without a stack trace copies nothing", pasteboard.string(forType: .string) == "   at Checkout.Retry()")
        model.copyStackTrace(to: pasteboard)
        check("Edit > Copy Stack Trace copies the first exception that has one",
              pasteboard.string(forType: .string)?.split(separator: "\n").count == 42 && model.copiedStackTrace == 0)
        let stackID = SpanDetailValueID.stackTrace(0)
        model.toggleExpanded(stackID)
        check("Show All opens the whole stack trace", model.expandedValues.contains(stackID))
        model.toggleExpanded(stackID)
    }
}
