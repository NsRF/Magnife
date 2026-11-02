import Foundation
import MagnifeKit

/// S-015: pruning end to end, with the real bundled helper on free ports and
/// a 3-second retention (the APP_RETENTION_SECONDS test hook's path: any
/// number of seconds), on a fresh database in /tmp. The window's model reads
/// that database, so the real list, sidebar and detail column are checked.
extension SelfTest {
    private static var retentionRoot: URL { TestRun.directory.appending(path: "retention") }
    private static let shortRetention = 3

    static func checkRetention(_ model: AppModel) async {
        try? FileManager.default.removeItem(at: retentionRoot)
        guard let helperURL = AppModel.helperExecutable(environment: [:]),
              FileManager.default.isExecutableFile(atPath: helperURL.path),
              let sender = ProcessInfo.processInfo.environment["APP_SAMPLE_SENDER"].map(URL.init(fileURLWithPath:)) else {
            return check("the bundled helper and the sample sender exist (tools/selftest.sh)", false)
        }
        let store = retentionRoot.appending(path: "magnife.sqlite")
        let helper = AppModel(storeURL: store)
        helper.retentionSeconds = shortRetention
        let ports = (grpc: freePort(), http: freePort())
        helper.startReceiver(executable: helperURL, ports: ports)
        _ = await waitUntil(5) { helper.receiver.isReceiving && helper.storeState == .ready }
        let flag = helper.supervisor?.configuration.arguments.split(separator: "--retention").last?.first
        check("the helper starts with --retention \(shortRetention)", flag == String(shortRetention), "\(flag ?? "none")")
        check("the helper applied it (meta.retention_s)",
              (try? await helper.reader?.retentionSeconds()) == shortRetention)

        // The window reads the same file; the helper's batch and pruned lines reach it.
        let keptRetention = model.retentionSeconds
        model.retentionSeconds = shortRetention
        await model.useStore(at: store)
        model.sidebar = .allTraces
        model.showContentMode(.traces)
        var batches: [Date] = []
        var pruned: [Date] = []
        helper.onHelperEvent = { [weak model] event in
            switch event {
            case .helper(.batch): batches.append(Date()); model?.handle(event)
            case .helper(.pruned): pruned.append(Date()); model?.handle(event)
            default: break
            }
        }
        func send(_ arguments: [String]) async -> (status: Int32, output: String) {
            await run(sender, ["--protocol", "http-protobuf", "--grpc", "127.0.0.1:\(ports.grpc)",
                               "--http", "127.0.0.1:\(ports.http)"] + arguments)
        }

        await checkSelectedTracePruned(model, send: send, pruned: { pruned.count })
        await checkPausedListPruned(model, send: send, pruned: { pruned.count })
        await checkHeldListsPruned(model, send: send, pruned: { pruned.count })
        await checkPruningUnderLoad(model, send: send, batches: { batches }, pruned: { pruned })

        helper.onHelperEvent = nil
        await helper.stopHelperAndWait()
        model.retentionSeconds = keptRetention
        model.selectedTraceID = nil
        model.showContentMode(.traces)
        await model.useStore(at: model.storeURL)
        await checkRetentionChange(model)
        try? FileManager.default.removeItem(at: retentionRoot)
    }

    /// The open trace is deleted on the helper's own schedule: the detail
    /// column says so, the list and the sidebar counts drop with the data.
    private static func checkSelectedTracePruned(_ model: AppModel, send: ([String]) async -> (status: Int32, output: String),
                                                 pruned: () -> Int) async {
        let sentAt = Date()
        let sent = await send(["--scenarios", "healthy,http-500,logs"])
        let listed = await waitUntil(3) { model.traces.contains { $0.route == "POST /checkout/pay" } }
        check("traces sent to the helper reach the list", sent.status == 0 && listed, sent.output)
        model.selectedTraceID = model.traces.first { $0.route == "POST /checkout/pay" }?.id
        let opened = await waitUntil(2) { !model.waterfall.isEmpty }
        let errorsBefore = model.services.map(\.errorCount).reduce(0, +)
        check("the HTTP 500 trace opens before its retention runs out", opened && errorsBefore > 0, "errors \(errorsBefore)")
        let before = pruned()
        let gone = await waitUntil(Double(shortRetention) * 2 + 3) {
            pruned() > before && model.traces.isEmpty && model.showsTraceNoLongerStored
        }
        print("INFO pruned \(String(format: "%.1f", Date().timeIntervalSince(sentAt))) s after sending, retention \(shortRetention) s")
        check("the helper prunes on its own once the retention runs out (no prune command)", gone,
              "pruned events \(pruned() - before), \(model.traces.count) rows")
        check("the selected trace closes to \"Trace No Longer Stored\" and stays selected",
              model.showsTraceNoLongerStored && model.selectedTraceID != nil && model.waterfall.isEmpty
                && model.spanDetail == nil && model.traceLogs.isEmpty && model.openTrace == nil)
        check("it says how long Magnife keeps data",
              Retention.keepsText(seconds: model.retentionSeconds) == "Magnife keeps traces and logs for 3 seconds.")
        check("the sidebar counts drop with the data", model.services.allSatisfy { $0.errorCount == 0 },
              "\(model.services.map(\.errorCount))")
        let logs = (try? await model.reader?.latestLogs()) ?? [LogRecord]()
        let traces = (try? await model.reader?.traceCount()) ?? -1
        check("traces, spans and logs are deleted together", logs.isEmpty && traces == 0, "\(logs.count) logs, \(traces) traces")
        // Choosing another trace leaves the state.
        model.selectedTraceID = nil
        check("no selection leaves the state", !model.showsTraceNoLongerStored)
    }

    /// A paused list keeps pruned rows; opening one shows the same state, and Resume drops them.
    private static func checkPausedListPruned(_ model: AppModel, send: ([String]) async -> (status: Int32, output: String),
                                              pruned: () -> Int) async {
        _ = await send(["--scenarios", "healthy"])
        guard await waitUntil(3, { !model.traces.isEmpty }) else { return check("the paused check has rows", false) }
        model.togglePause()
        let rows = model.traces
        let before = pruned()
        let deleted = await waitUntil(Double(shortRetention) * 2 + 3) { pruned() > before }
        try? await Task.sleep(for: .milliseconds(300))
        check("a paused list still shows the pruned rows", deleted && model.traces == rows, "\(model.traces.count) rows")
        model.selectedTraceID = rows.first?.id
        let state = await waitUntil(2) { model.showsTraceNoLongerStored }
        check("a pruned row of a paused list opens to \"Trace No Longer Stored\"", state)
        model.togglePause()
        check("Resume drops the pruned rows", await waitUntil(2) { model.traces.isEmpty }, "\(model.traces.count) rows")
        model.selectedTraceID = nil
    }

    /// Scrolled away from the top, rows hold still, but pruned ones leave
    /// (they are the oldest, at the bottom); the Logs list does the same.
    private static func checkHeldListsPruned(_ model: AppModel, send: ([String]) async -> (status: Int32, output: String),
                                             pruned: () -> Int) async {
        model.showContentMode(.logs)
        _ = await send(["--scenarios", "healthy,logs"])
        guard await waitUntil(3, { !model.traces.isEmpty && !model.logs.isEmpty }) else {
            return check("the held check has traces and logs", false, "\(model.traces.count), \(model.logs.count)")
        }
        model.isListHeld = true
        model.isLogListHeld = true
        let before = pruned()
        let gone = await waitUntil(Double(shortRetention) * 2 + 3) {
            pruned() > before && model.traces.isEmpty && model.logs.isEmpty
        }
        check("pruned rows leave held trace and log lists, which stay held",
              gone && model.isListHeld && model.isLogListHeld, "\(model.traces.count) traces, \(model.logs.count) logs")
        model.isListHeld = false
        model.isLogListHeld = false
        model.showContentMode(.traces)
    }

    /// Pruning never blocks ingestion or the interface: traces stream in
    /// while the helper prunes every 3 seconds; batches keep committing and
    /// the main thread keeps answering.
    private static func checkPruningUnderLoad(_ model: AppModel, send: @escaping ([String]) async -> (status: Int32, output: String),
                                              batches: () -> [Date], pruned: () -> [Date]) async {
        let started = Date()
        let load = Task { await send(["--rate", "4000", "--duration", "9s"]) }
        var stall: TimeInterval = 0
        while Date().timeIntervalSince(started) < 9 {
            let tick = Date()
            try? await Task.sleep(for: .milliseconds(10))
            stall = max(stall, Date().timeIntervalSince(tick) - 0.01)
        }
        let result = await load.value
        let during = batches().filter { $0 > started.addingTimeInterval(0.5) && $0 < started.addingTimeInterval(9) }
        let gaps = zip(during.dropFirst(), during).map { $0.timeIntervalSince($1) }
        let maxGap = gaps.max() ?? .infinity
        let passes = pruned().filter { $0 > started }.count
        print("INFO under 4,000 spans/s: \(passes) pruning passes, \(during.count) batches, longest gap between batches "
              + "\(Int(maxGap * 1000)) ms, longest main-thread stall \(Int(stall * 1000)) ms")
        check("the sender's exports are all accepted while pruning", result.status == 0, result.output)
        check("pruning ran during the load", passes >= 2, "\(passes)")
        checkTiming("batches keep committing while pruning (no gap over 500 ms)", ms: maxGap * 1000, budget: 500)
        // 250 ms is where macOS counts a hang; the reads run off the main actor and the helper prunes in its own process.
        checkTiming("the interface keeps answering while pruning (no main-thread hang over 250 ms)", ms: stall * 1000, budget: 250)
        let rows = (try? await model.reader?.traceCount()) ?? 0
        check("the store keeps only the last few seconds", rows > 0 && rows < 4_000 * 9, "\(rows) traces")
    }

    // MARK: S-016

    /// Settings > General's pop-up through the model the window binds to:
    /// a longer period applies at once, a shorter one waits for Delete,
    /// Cancel changes nothing, and Delete prunes right away.
    static func checkRetentionChange(_ model: AppModel) async {
        let root = retentionRoot.appending(path: "change")
        try? FileManager.default.removeItem(at: root)
        guard let helperURL = AppModel.helperExecutable(environment: [:]),
              let sender = ProcessInfo.processInfo.environment["APP_SAMPLE_SENDER"].map(URL.init(fileURLWithPath:)) else {
            return check("the bundled helper and the sample sender exist (tools/selftest.sh)", false)
        }
        let store = root.appending(path: "magnife.sqlite")
        let helper = AppModel(storeURL: store)
        helper.retentionSeconds = Retention.defaultSeconds
        let ports = (grpc: freePort(), http: freePort())
        helper.startReceiver(executable: helperURL, ports: ports)
        _ = await waitUntil(5) { helper.receiver.isReceiving && helper.storeState == .ready }
        // The window's list reads the same file.
        await model.useStore(at: store)
        model.sidebar = .allTraces
        model.showContentMode(.traces)
        helper.onHelperEvent = { [weak model] event in
            if case .helper(.batch) = event { model?.handle(event) }
            if case .helper(.pruned) = event { model?.handle(event) }
        }
        let sent = await run(sender, ["--protocol", "http-protobuf", "--scenarios", "healthy,http-500,logs",
                                      "--grpc", "127.0.0.1:\(ports.grpc)", "--http", "127.0.0.1:\(ports.http)"])
        let listed = await waitUntil(3) { model.traces.count >= 2 && helper.traces.count >= 2 }
        check("the list has traces before the change", sent.status == 0 && listed, "\(model.traces.count)")
        func applied(_ expected: Int) async -> Int? {
            var value: Int?
            for _ in 0..<40 {
                value = try? await helper.reader?.retentionSeconds()
                if value == expected { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return value
        }

        helper.requestRetention(604_800)
        let longer = await waitUntil(2, every: .milliseconds(50)) { helper.pendingRetention == nil && helper.retentionSeconds == 604_800 }
        let week = await applied(604_800)
        check("a longer period applies at once, with no dialog", longer && week == 604_800, "\(String(describing: week))")
        check("and deletes nothing", !model.traces.isEmpty)

        // A crash restart launches with the period chosen since, not the launch one.
        if let pid = helper.helperPID {
            kill(pid, SIGKILL)
            _ = await waitUntil(5) { helper.helperPID != nil && helper.helperPID != pid && helper.receiver.isReceiving }
        }
        try? await Task.sleep(for: .milliseconds(300))
        let restarted = await applied(604_800)
        check("a helper restarted after a crash keeps the chosen period (meta.retention_s)",
              restarted == 604_800 && helper.supervisor?.launchArguments.suffix(1) == ["604800"],
              "\(String(describing: restarted))")

        helper.requestRetention(3_600)
        check("a shorter period asks first", helper.pendingRetention == 3_600 && helper.retentionSeconds == 604_800)
        helper.cancelRetention()
        try? await Task.sleep(for: .milliseconds(500))
        let kept = try? await helper.reader?.retentionSeconds()
        check("Cancel keeps the previous choice and tells the helper nothing",
              helper.pendingRetention == nil && helper.retentionSeconds == 604_800 && kept == 604_800)

        // A period shorter than the data's age (the test hook's seconds) so Delete has something to delete.
        try? await Task.sleep(for: .seconds(1.2))
        let sizeBefore = DatabaseSize.bytes(of: store)
        helper.requestRetention(1)
        check("shortening to 1 second asks first too", helper.pendingRetention == 1)
        let confirmed = Date()
        helper.confirmRetention()
        let emptied = await waitUntil(3) { model.traces.isEmpty && helper.traces.isEmpty }
        let elapsed = Date().timeIntervalSince(confirmed)
        print("INFO Delete emptied the list in \(Int(elapsed * 1000)) ms")
        check("Delete prunes right away and the list updates (under 800 ms, before any pruning tick)",
              emptied && elapsed < 0.8, "\(Int(elapsed * 1000)) ms, \(model.traces.count) rows")
        let second = await applied(1)
        check("the helper applied the new period", second == 1)
        _ = await waitUntil(2) { helper.databaseSize == DatabaseSize.bytes(of: store) }
        check("Database size is read again after the pruning (database plus WAL)",
              helper.databaseSize == DatabaseSize.bytes(of: store) && (helper.databaseSize ?? 0) > 0,
              "\(helper.databaseSize ?? -1) vs \(DatabaseSize.bytes(of: store)), before \(sizeBefore)")

        helper.onHelperEvent = nil
        await helper.stopHelperAndWait()
        await model.useStore(at: model.storeURL)
        try? FileManager.default.removeItem(at: root)
    }
}
