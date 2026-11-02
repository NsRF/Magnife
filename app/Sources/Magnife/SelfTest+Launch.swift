import AppKit
import MagnifeKit

/// S-029: from launch to a window showing stored traces in under a second.
/// Copies of Magnife are launched with the real helper on free ports, on a
/// copy of the 100,000-span store (APP_SEARCH_STORE) and of any store in
/// APP_LAUNCH_STORES (tools/launch-time.sh: 12,000 and 300,000 spans);
/// each writes its timings through LaunchProbe. Then the restore: scope,
/// filters, selected trace and focus, a pruned selection, and the state a
/// quit keeps.
extension SelfTest {
    static func checkLaunch(_ model: AppModel) async {
        let env = ProcessInfo.processInfo.environment
        let stores = ([env["APP_SEARCH_STORE"]] + (env["APP_LAUNCH_STORES"] ?? "").split(separator: ",").map(String.init))
            .compactMap { $0 }.filter { !$0.isEmpty }.map { URL(fileURLWithPath: $0) }
        guard let primary = stores.first else {
            return check("APP_SEARCH_STORE names the 100,000-span store (tools/selftest.sh)", false)
        }
        for (index, store) in stores.enumerated() {
            await checkLaunchTime(of: store, name: "launch-\(index)", restores: store == primary)
        }
    }

    private static func checkLaunchTime(of source: URL, name: String, restores: Bool) async {
        let root = TestRun.scratch(name)
        let store = root.appending(path: "magnife.sqlite")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: source.path + suffix) {
                try FileManager.default.copyItem(atPath: source.path + suffix, toPath: store.path + suffix)
            }
        } catch {
            return check("the store to launch on is copied", false, "\(error)")
        }
        guard let reader = try? await TelemetryReader.open(at: store),
              let traces = try? await reader.latestTraces(limit: 1_000_000) else {
            return check("the store to launch on reads", false)
        }
        let spans = traces.reduce(0) { $0 + $1.spanCount }
        let label = "\(spans.formatted()) spans"

        // Three launches with nothing to restore: the first rows, timed from the process start.
        var times: [Double] = []
        var last: [String: Any] = [:]
        for attempt in 0..<3 {
            guard let probe = await launchWithProbe(store: store, root: root, run: "\(attempt)", state: nil) else {
                return check("a copy of Magnife on \(label) reports its launch", false)
            }
            times.append(probe["rows_shown"] as? Double ?? .infinity)
            last = probe
        }
        let steps = ["will_finish_launching", "did_finish_launching", "store_open", "first_read", "rows_shown"]
            .map { "\($0) \(Int((last[$0] as? Double) ?? -1))" }.joined(separator: ", ")
        print("INFO launch on \(label): rows shown at \(times.map { "\(Int($0)) ms" }.joined(separator: ", ")) "
              + "since the process started (last: \(steps))")
        let median = times.sorted()[1]
        checkTiming("from launch to a window showing stored traces on \(label) (median of 3)", ms: median, budget: 1_000,
                    ok: (last["rows"] as? Int ?? 0) >= min(traces.count, TraceList.pageSize))
        check("at launch the focus is in the trace list on \(label)", last["focus_in_list"] as? Bool == true)
        guard restores else { return }

        // The last quit's scope, filters and selected trace come back, the trace selected in the list.
        let scoped = (try? await reader.latestTraces(limit: TraceList.pageSize,
                                                     filter: TraceQuery("service:orders status:error").filter)) ?? []
        guard !scoped.isEmpty else { return check("the store has error traces from orders", false) }
        let pick = scoped[min(2, scoped.count - 1)]
        let state = LaunchState(scope: .service("orders"), traceQuery: "service:orders status:error",
                                showsTraceFilterBar: true, selectedTraceID: pick.id)
        let restored = await launchWithProbe(store: store, root: root, run: "restore", state: state)
        check("a launch restores the scope, the filters and the selected trace",
              restored?["title"] as? String == "orders" && restored?["filter"] as? String == "service:orders status:error"
                && restored?["shows_filter_bar"] as? Bool == true && restored?["selected"] as? String == pick.id
                && restored?["selected_row"] as? Int == scoped.firstIndex { $0.id == pick.id },
              "\(restored ?? [:])")
        check("the focus starts in the list on the selected row", restored?["focus_in_list"] as? Bool == true)

        // A selected trace that retention deleted shows S-015's state; the quit then keeps no selection.
        let gone = "0000000000000000000000000000dead"
        let suite = TestRun.suiteName + ".launch-pruned"
        let pruned = await launchWithProbe(store: store, root: root, run: "pruned", state: LaunchState(selectedTraceID: gone),
                                           suite: suite)
        check("a restored selection that was pruned shows \"Trace No Longer Stored\"",
              pruned?["pruned"] as? String == gone, "\(pruned ?? [:])")
        CFPreferencesAppSynchronize(suite as CFString)
        let kept = UserDefaults(suiteName: suite).flatMap(LaunchState.stored(in:))
        check("Quit keeps the window's state for the next launch", kept != nil && kept?.selectedTraceID == nil,
              "\(String(describing: kept))")
        UserDefaults().removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    /// Launches a copy of Magnife on `store` with `state` to restore, waits
    /// for its probe line, quits it, and returns the line.
    private static func launchWithProbe(store: URL, root: URL, run: String, state: LaunchState?,
                                        suite: String? = nil) async -> [String: Any]? {
        let keepsSuite = suite != nil
        let suite = suite ?? TestRun.suiteName + ".launch-\(run)"
        let defaults = UserDefaults(suiteName: suite)
        UserDefaults().removePersistentDomain(forName: suite)
        if let state, let defaults { state.store(in: defaults) }
        CFPreferencesAppSynchronize(suite as CFString)
        let probe = root.appending(path: "probe-\(run).json")
        try? FileManager.default.removeItem(at: probe)
        let ports = (grpc: freePort(), http: freePort())
        guard let app = launchCopy(store: store, ports: ports,
                                   environment: ["APP_LAUNCH_PROBE": probe.path, "APP_DEFAULTS_SUITE": suite]) else { return nil }
        _ = await waitUntil(20, every: .milliseconds(20)) { FileManager.default.fileExists(atPath: probe.path) || !app.isRunning }
        let line = (try? Data(contentsOf: probe)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        // Quit it the way ⌘Q does, so the helper stops and the state is kept.
        NSRunningApplication(processIdentifier: app.processIdentifier)?.terminate()
        if !(await waitUntil(5) { !app.isRunning }) { app.terminate() }
        if !keepsSuite { UserDefaults().removePersistentDomain(forName: suite) }
        return line
    }
}
