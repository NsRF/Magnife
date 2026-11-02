import AppKit
import MagnifeKit

/// Self-test for agents: runs the app's real functions on the seeded store,
/// prints PASS or FAIL per check, and quits with exit code 0 or 1.
///   APP_STORE=/tmp/Magnife-self.sqlite APP_HELPER=none ~/Applications/Magnife.app/Contents/MacOS/Magnife --selftest
/// (tools/selftest.sh seeds the store through the real helper and runs this.)
/// Add a check for every story with logic.
@MainActor
enum SelfTest {
    static var requested: Bool { CommandLine.arguments.contains("--selftest") }
    /// Read by AppDelegate.applicationWillTerminate.
    static var exitCode: Int32 = 0
    private static var failures = 0
    private static var count = 0
    private static var started = false

    static func runIfRequested(model: AppModel) {
        guard requested, !started else { return }
        started = true
        // Print each line at once, so a crash keeps the lines before it.
        setvbuf(stdout, nil, _IOLBF, 0)
        guard StoreLocation.isOverridden(), StoreLocation.isTestLocation(model.storeURL) else {
            print("SELFTEST refused: set APP_STORE to a file in /tmp")
            finish(code: 1)
            return
        }
        Task {
            await model.openStore()
            await checkReader(model)
            await checkModel(model)
            // APP_SELFTEST_ONLY=waterfall runs one story's checks, for quick rounds.
            let only = ProcessInfo.processInfo.environment["APP_SELFTEST_ONLY"]
            if only == "waterfall" {
                await checkWaterfall(model)
            } else if only == "lifecycle" {
                await checkLifecycle()
            } else if only == "trace-list" {
                await checkTraceList(model)
            } else if only == "sidebar" {
                await checkSidebar()
            } else if only == "pause" {
                await checkPause(model)
            } else if only == "logs" {
                await checkLogs(model)
                await checkLogFilters(model)
            } else if only == "search" {
                await checkSearch(model)
                await checkTraceFilters(model)
            } else if only == "saved-filters" {
                await checkSavedFilters(model)
            } else if only == "keyboard" {
                await checkKeyboard(model)
            } else if only == "findings" {
                await checkFindings(model)
            } else if only == "menu-bar" {
                await checkMenuBar(model)
            } else if only == "notifications" {
                await checkNotifications(model)
            } else if only == "launch" {
                await checkLaunch(model)
            } else if only == "retention" {
                await checkRetention(model)
            } else if only == "span-detail" {
                await checkSpanDetail(model)
                await checkExceptions(model)
                await checkSpanLogs(model)
                await checkTraceLogs(model)
            } else {
                await checkEnvironment(model)
                // Before the live list checks send more traces: it counts the seed set's.
                await checkSearch(model)
                await checkTraceFilters(model)
                await checkSavedFilters(model)
                await checkKeyboard(model)
                await checkTraceList(model)
                await checkSidebar()
                await checkPause(model)
                await checkWaterfall(model)
                await checkSpanDetail(model)
                await checkExceptions(model)
                await checkSpanLogs(model)
                await checkTraceLogs(model)
                await checkFindings(model)
                await checkLogs(model)
                await checkLogFilters(model)
                await checkRetention(model)
                await checkSupervisor()
                await checkReceiver()
                checkApp()
                await checkWindowClose()
                // With the window closed: a Recent Errors item brings it back (S-027).
                await checkMenuBar(model)
                await checkNotifications(model)
                // Last: they start other copies of Magnife, which take the focus.
                await checkLaunch(model)
                await checkLifecycle()
            }
            if timingWarnings > 0 { print("INFO \(timingWarnings) timings over budget but under their regression limit (WARN lines)") }
            print(failures == 0 ? "SELFTEST PASS \(count) checks" : "SELFTEST FAIL \(failures) of \(count) checks")
            finish(code: failures == 0 ? 0 : 1)
        }
    }

    /// The read layer against the seed set (tools/seed.zsh: the helper
    /// received scripts/send-sample-traces over gRPC and HTTP).
    private static func checkReader(_ model: AppModel) async {
        check("the seeded store opens read-only", model.storeState == .ready, "\(model.storeState)")
        guard let reader = model.reader else { return }
        do {
            let traces = try await reader.latestTraces()
            check("the seed set has 5 traces", traces.count == 5, "\(traces.count)")
            check("traces come newest first", traces.map(\.startNs) == traces.map(\.startNs).sorted(by: >))
            let page = try await reader.latestTraces(limit: 2)
            let next = try await reader.latestTraces(limit: 2, after: page.last?.cursor)
            check("the second page continues the first",
                  (page + next).map(\.traceID) == Array(traces.prefix(4)).map(\.traceID))

            let failed = traces.first { $0.route == "POST /checkout/pay" }
            check("the HTTP 500 trace reads as Error", failed?.status == .error)
            let spans = try await reader.spans(traceID: failed?.traceID ?? "")
            check("spans of the HTTP 500 trace", spans.count == 5, "\(spans.count)")
            check("its root span has no parent", spans.first?.isRoot == true)
            check("every other span's parent is in the trace",
                  spans.dropFirst().allSatisfy { span in spans.contains { $0.spanID == span.parentSpanID } })
            let exception = spans.flatMap(\.exceptions).first
            check("the exception has type and stack trace",
                  exception?.type == "Microsoft.EntityFrameworkCore.DbUpdateException" && exception?.stackTrace.isEmpty == false,
                  "\(exception?.type ?? "none")")

            let services = try await reader.services()
            check("services by name", services.map(\.name) == ["checkout-api", "orders", "web"], "\(services.map(\.name))")
            check("error counts derive from spans", services.map(\.errorCount) == [1, 1, 1], "\(services.map(\.errorCount))")
            let orders = try await reader.latestTraces(service: "orders")
            check("a service filter keeps traces with its spans", orders.count == 3, "\(orders.count)")

            let slowTrace = traces.first { $0.route == "GET /admin/reports" }
            let slow = try await reader.spans(traceID: slowTrace?.traceID ?? "")
            check("the slow SQL span reads its promoted columns",
                  slow.contains { $0.dbSystem == "postgresql" && $0.durationNs == 851_000_000 })
            check("the slow trace's duration reads 884 ms",
                  DurationFormat.string(nanoseconds: slowTrace?.durationNs ?? 0) == "884 ms")

            let traceLogs = try await reader.logs(traceID: failed?.traceID ?? "")
            // On spans, one with no span id, one from a span never received (S-012 seed).
            check("logs of the HTTP 500 trace", traceLogs.count == 5 && traceLogs.filter { $0.spanID == nil }.count == 1,
                  "\(traceLogs.count)")
            let errors = try await reader.latestLogs(level: .error)
            check("the Error level filter", errors.count == 3 && errors.allSatisfy { $0.level == .error }, "\(errors.count)")
            let all = try await reader.latestLogs()
            check("logs without a trace id still read", all.filter { $0.traceID == nil }.count == 8)
            let seq = try await reader.lastSeq()
            check("last seq counts the helper's batches", seq >= 1, "\(seq)")
            check("every trace was created after seq 0", try await reader.traceCount(createdAfter: 0) == 5)
            check("attribute keys for autocomplete", try await reader.attributeKeys(source: .span).contains { $0.key == "http.route" })
        } catch {
            check("the reader reads", false, "\(error)")
        }
    }

    /// The model's list follows the sidebar and the helper's events.
    private static func checkModel(_ model: AppModel) async {
        await model.reload()
        check("the list shows every trace", model.traces.count == 5, "\(model.traces.count)")
        check("the sidebar shows 3 services", model.services.count == 3)
        model.sidebar = .service("web")
        await model.reload()
        check("a service in the sidebar filters the list", model.traces.count == 4, "\(model.traces.count)")
        model.sidebar = .allTraces
        await model.reload()

        model.handle(.helper(.ports(ReceiverPorts(grpc: PortStatus(addr: "127.0.0.1:4317", state: .busy, owner: "otelcol-contrib"),
                                                  http: PortStatus(addr: "127.0.0.1:4318", state: .listening)))))
        check("one busy port reads \"Receiving on 4318 only\"", model.receiver.text == "Receiving on 4318 only", model.receiver.text)
        model.handle(.started(pid: 1, restart: true))
        check("a restart shows the receiver banner", model.receiverRestarted)
        model.handle(.helper(.batch(BatchEvent(seq: 11, spans: 1, logs: 0, traces: ["x"]))))
        check("the next trace closes the banner", !model.receiverRestarted)
        model.handle(.launchFailed("missing"))
        check("a helper that cannot start reads \"Not receiving\"", model.receiver.text == "Not receiving")
        model.helperMessage = nil
        model.showReceiverListening()
    }

    /// The supervisor against the fake helper: events, commands, a crash, stop.
    private static func checkSupervisor() async {
        let dir = TestRun.scratch("helper")
        guard let executable = try? FakeHelper.write(to: dir) else {
            check("the fake helper is written", false)
            return
        }
        let supervisor = HelperSupervisor(configuration: HelperConfiguration(
            executableURL: executable, databaseURL: dir.appending(path: "magnife.sqlite"),
            backoff: RestartBackoff(initial: 0.2, maximum: 1, stableAfter: 60)))
        var events = supervisor.events.makeAsyncIterator()
        supervisor.start()

        func next(_ match: (SupervisorEvent) -> Bool) async -> SupervisorEvent? {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                guard let event = await events.next(isolation: #isolation) else { return nil }
                if match(event) { return event }
            }
            return nil
        }
        let ports = await next { if case .helper(.ports) = $0 { true } else { false } }
        check("the helper reports its ports", ports != nil)
        let batch = await next { if case .helper(.batch) = $0 { true } else { false } }
        check("a batch line split across writes reads as one", batch == .helper(.batch(BatchEvent(seq: 1, spans: 3, logs: 1, traces: ["t1"]))))
        check("a malformed line is reported", await next { $0 == .malformedLine("not json") } != nil)
        try? supervisor.send(.retry)
        check("retry sends ports again", await next { if case .helper(.ports) = $0 { true } else { false } } != nil)

        if let pid = supervisor.pid { kill(pid, SIGKILL) }
        check("a crash is reported", await next { if case .crashed = $0 { true } else { false } } != nil)
        check("the helper restarts after 0.2 s", await next { $0 == .restartScheduled(delay: 0.2) } != nil)
        check("the restart says so", await next { if case .started(_, true) = $0 { true } else { false } } != nil)

        _ = await next { if case .helper(.ports) = $0 { true } else { false } }
        let pid = supervisor.pid ?? 0
        let started = Date()
        await supervisor.stop()
        check("stop closes stdin and the helper exits within 3 s",
              Date().timeIntervalSince(started) < 3 && kill(pid, 0) != 0)
        try? FileManager.default.removeItem(at: dir)
    }

    private static func checkApp() {
        // AppKit writes this run's window frame and column widths to the user's defaults;
        // the copy taken at launch puts the user's back at the end (AppDefaults).
        let backup = UserDefaults(suiteName: AppDefaults.testSuiteName)?.dictionary(forKey: AppDefaults.layoutBackupKey)
        print("INFO layout keys written by this run: \(AppDefaults.savedLayout().keys.sorted()), kept aside: \(backup?.keys.sorted() ?? [])")
        check("a test run keeps the user's window layout aside, to put back when it ends", backup != nil)
        check("APP_HELPER=none starts no helper", AppModel.helperExecutable(environment: ["APP_HELPER": "none"]) == nil)
        check("the bundled helper path",
              AppModel.helperExecutable(environment: [:])?.path.hasSuffix("Contents/Helpers/magnife-ingest") == true)
    }

    /// Last: closes every window and checks the app is still running. A quit
    /// here would exit with 1, so it cannot pass by accident.
    private static func checkWindowClose() async {
        exitCode = 1
        for window in NSApp.windows where window.canBecomeMain { window.close() }
        try? await Task.sleep(for: .seconds(1))
        check("closing the last window keeps Magnife running",
              !NSApp.windows.contains { $0.isVisible && $0.canBecomeMain })
    }

    static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        count += 1
        if !ok { failures += 1 }
        print(ok ? "PASS \(name)" : "FAIL \(name)\(detail.isEmpty ? "" : ": \(detail)")")
    }

    /// A timing check that holds on a busy Mac (other runs, the screen saver):
    /// it always prints the measured value; within `budget` it passes, over
    /// it it still passes with a WARN line unless it is a clear regression
    /// (over `regression`, twice the budget by default). `ok` carries the
    /// check's other conditions, which fail as usual.
    static func checkTiming(_ name: String, ms: Double, budget: Double, regression: Double? = nil,
                            ok: Bool = true, _ detail: String = "") {
        let limit = regression ?? budget * 2
        let value = "\(String(format: ms < 10 ? "%.1f" : "%.0f", ms)) ms"
        let extra = detail.isEmpty ? "" : ", \(detail)"
        if ok && ms > budget && ms <= limit {
            timingWarnings += 1
            print("WARN \(name): \(value), over the \(Int(budget)) ms budget (load \(loadAverage))\(extra)")
        }
        check("\(name) (\(value), budget \(Int(budget)) ms)", ok && ms <= limit,
              "\(value), limit \(Int(limit)) ms (load \(loadAverage))\(extra)")
    }

    private static var timingWarnings = 0

    /// The 1-minute load average, printed with timings so a slow run explains itself.
    static var loadAverage: String {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) > 0 ? String(format: "%.1f", loads[0]) : "?"
    }

    /// Quits through NSApp.terminate, never exit(), and closes sheets first:
    /// an open sheet refuses terminate, and the run would wait forever.
    static func finish(code: Int32) {
        exitCode = code
        for window in NSApp.windows { if let sheet = window.attachedSheet { window.endSheet(sheet) } }
        NSApp.terminate(nil)
    }
}
