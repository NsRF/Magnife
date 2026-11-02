import Foundation
import MagnifeKit

/// S-009: the sidebar of services. A model with its own helper, the way the
/// app starts it: a service appears when its first span arrives, in its
/// alphabetical place with its count of traces with errors, and selecting it
/// scopes the list to traces with a span from it.
extension SelfTest {
    static func checkSidebar() async {
        guard let helper = AppModel.helperExecutable(environment: [:]),
              let sender = ProcessInfo.processInfo.environment["APP_SAMPLE_SENDER"].map(URL.init(fileURLWithPath:)) else {
            return check("the helper and APP_SAMPLE_SENDER exist", false)
        }
        let root = URL(fileURLWithPath: "/tmp/Magnife-selftest-sidebar")
        try? FileManager.default.removeItem(at: root)
        let model = AppModel(storeURL: root.appending(path: "magnife.sqlite"))
        let ports = (grpc: freePort(), http: freePort())
        model.startReceiver(executable: helper, ports: ports)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await waitUntil(3) { model.receiver.isReceiving && model.storeState == .ready }
        check("no services yet shows only All Services", model.services.isEmpty && model.title == "All Services")

        let sent = await run(sender, ["--protocol", "http-protobuf", "--scenarios", "healthy",
                                      "--grpc", "127.0.0.1:\(ports.grpc)", "--http", "127.0.0.1:\(ports.http)"])
        let healthy = await waitUntil(2) { model.services.count == 3 }
        check("the healthy trace's services appear, alphabetical and with no errors",
              sent.status == 0 && healthy && model.services.map(\.name) == ["checkout-api", "orders", "web"]
                && model.services.allSatisfy { $0.errorCount == 0 && $0.spokenErrors == "no errors" },
              "\(model.services.map(\.name))")
        guard let trace = model.traces.first else { return check("the healthy trace is listed", false) }

        // One Error span from a new service, a child in the healthy trace (not its root).
        let now = UInt64(Date().timeIntervalSince1970 * 1e9)
        let posted = await post(port: ports.http, path: "/v1/traces", body: """
            {"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"inventory"}}]},
            "scopeSpans":[{"spans":[{"traceId":"\(trace.traceID)","spanId":"5e1f7e5700000e01",
            "parentSpanId":"\(trace.rootSpanID ?? "")","name":"reserve stock","kind":3,
            "startTimeUnixNano":"\(now)","endTimeUnixNano":"\(now + 2_000_000)","status":{"code":2}}]}]}]}
            """)
        let arrived = Date()
        let appeared = await waitUntil(2) { model.services.contains { $0.name == "inventory" } }
        let elapsed = Date().timeIntervalSince(arrived)
        check("a new service appears in the sidebar when its first span arrives",
              posted == 200 && appeared && elapsed < 1, "posted \(posted), \(String(format: "%.2f", elapsed)) s")
        check("it takes its alphabetical place",
              model.services.map(\.name) == ["checkout-api", "inventory", "orders", "web"], "\(model.services.map(\.name))")
        let inventory = model.services.first { $0.name == "inventory" }
        check("its count is the traces in which it has an Error span",
              inventory?.errorCount == 1 && inventory?.errorCountText == "1 trace with errors",
              "\(inventory?.errorCount ?? -1)")
        check("it gets its own color", Set(model.services.map { model.serviceColors.slot(for: $0.name) }).count == 4)

        model.sidebar = .service("inventory")
        await model.reload()
        check("its scope lists the traces with a span from it, rooted elsewhere",
              model.traces.map(\.id) == [trace.id] && model.traces.first?.rootService == "web"
                && model.title == "inventory" && model.subtitle == "1 trace",
              "\(model.traces.map(\.rootService)), title \(model.title), subtitle \(model.subtitle)")
        model.sidebar = .allTraces
        await model.reload()
        check("All Services lists every trace again", model.title == "All Services" && model.traces.count == 1
              && model.subtitle == "1 trace")
        await model.stopHelperAndWait()
    }
}
