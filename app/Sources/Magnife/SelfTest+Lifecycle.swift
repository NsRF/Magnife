import AppKit
import MagnifeKit

/// Persistence and lifecycle checks (S-008) with the real bundled helper on
/// free ports and fresh databases in /tmp: relaunch, a helper crash, and a
/// second copy of this app that is quit and killed with `kill -9`.
/// Timings print as INFO lines (docs/PROGRESS.md records them).
extension SelfTest {
    private static let lifecycleRoot = URL(fileURLWithPath: "/tmp/Magnife-selftest-lifecycle")

    static func checkLifecycle() async {
        try? FileManager.default.removeItem(at: lifecycleRoot)
        guard let helper = AppModel.helperExecutable(environment: [:]),
              FileManager.default.isExecutableFile(atPath: helper.path) else {
            check("the bundled helper exists", false, "build with ./build.sh")
            return
        }
        await checkRelaunch(helper)
        await checkHelperCrash(helper)
        await checkAppProcess()
        try? FileManager.default.removeItem(at: lifecycleRoot)
    }

    /// After a quit the stored traces show at once, in the same order, before the helper is up.
    private static func checkRelaunch(_ helper: URL) async {
        let store = lifecycleRoot.appending(path: "relaunch/magnife.sqlite")
        let ports = (grpc: freePort(), http: freePort())
        let first = AppModel(storeURL: store)
        first.startReceiver(executable: helper, ports: ports)
        _ = await waitUntil(3) { first.receiver.isReceiving && first.storeState == .ready }
        guard let sender = ProcessInfo.processInfo.environment["APP_SAMPLE_SENDER"].map(URL.init(fileURLWithPath:)) else {
            return check("APP_SAMPLE_SENDER names the sample sender (tools/selftest.sh)", false)
        }
        let sent = await run(sender, ["--grpc", "127.0.0.1:\(ports.grpc)", "--http", "127.0.0.1:\(ports.http)"])
        let stored = await waitUntil(3) { first.traces.count == 5 }
        let before = first.traces.map(\.traceID)
        check("the seed set reaches the list before the quit", sent.status == 0 && stored, "\(first.traces.count) traces")
        await first.stopHelperAndWait()
        check("after the helper exits, its -wal file stays (persistent WAL)",
              FileManager.default.fileExists(atPath: store.path + "-wal"))

        // A launch with no helper running yet: the database opens read-only at once.
        let second = AppModel(storeURL: store)
        let blankWhileOpening = !second.showsEmptyState && second.traces.isEmpty
        let opening = ContinuousClock.now
        await second.openStore()
        let opened = ContinuousClock.now - opening
        info("relaunch: stored traces read in \(opened.milliseconds) ms with no helper running")
        check("while the database opens, the list is blank: no empty state, no spinner", blankWhileOpening)
        check("after quit and relaunch the list shows the same traces in the same order",
              second.storeState == .ready && second.traces.map(\.traceID) == before,
              "\(second.storeState), \(second.traces.count) traces")
        check("the stored traces show within 250 ms of opening", opened < .milliseconds(250), "\(opened.milliseconds) ms")

        // The launch path (AppModel.start): open the database and start the helper together.
        let third = AppModel(storeURL: store)
        let launched = ContinuousClock.now
        Task { await third.openStore() }
        third.startReceiver(executable: helper, ports: ports)
        var rowsAt: Duration?, portsAt: Duration?
        _ = await waitUntil(3, every: .milliseconds(5)) {
            if rowsAt == nil, third.traces.count == before.count { rowsAt = ContinuousClock.now - launched }
            if portsAt == nil, third.receiver.isReceiving { portsAt = ContinuousClock.now - launched }
            return rowsAt != nil && portsAt != nil
        }
        info("relaunch: rows at \(rowsAt?.milliseconds ?? -1) ms, helper ports at \(portsAt?.milliseconds ?? -1) ms")
        check("on relaunch the rows show before the helper reports its ports",
              (rowsAt ?? .seconds(9)) < (portsAt ?? .zero), "rows \(rowsAt?.milliseconds ?? -1) ms, ports \(portsAt?.milliseconds ?? -1) ms")
        check("the relaunched helper binds both ports at once (no busy banner)",
              third.receiver.busyBanner == nil && third.receiver.isReceiving, third.receiverStatusText ?? "nil")
        await third.stopHelperAndWait()
    }

    /// A helper crash: restarted after 0.5, 1 and 2 s, the banner says so and closes on the next trace.
    private static func checkHelperCrash(_ helper: URL) async {
        let model = AppModel(storeURL: lifecycleRoot.appending(path: "crash/magnife.sqlite"))
        let ports = (grpc: freePort(), http: freePort())
        model.startReceiver(executable: helper, ports: ports)
        _ = await waitUntil(3) { model.receiver.isReceiving && model.storeState == .ready }
        _ = await post(port: ports.http, path: "/v1/traces", body: ReceiverPayload.trace)
        _ = await waitUntil(2) { !model.traces.isEmpty }
        check("no restart banner before a crash", !model.receiverRestarted)

        var waits: [Duration] = []
        for _ in 0..<3 {
            guard let pid = model.helperPID else { break }
            let killed = ContinuousClock.now
            kill(pid, SIGKILL)
            _ = await waitUntil(5, every: .milliseconds(5)) { (model.helperPID ?? pid) != pid }
            waits.append(ContinuousClock.now - killed)
        }
        info("helper crash: restarted after \(waits.map { "\($0.milliseconds) ms" }.joined(separator: ", "))")
        let expected: [Double] = [0.5, 1, 2]
        check("a crashed helper is restarted with backoff 0.5 s, 1 s, 2 s",
              waits.count == 3 && zip(waits, expected).allSatisfy { $0.seconds >= $1 - 0.02 && $0.seconds < $1 + 0.4 },
              waits.map { "\($0.milliseconds) ms" }.joined(separator: ", "))
        check("the window says so: the S-008 banner", model.receiverRestarted
              && ReceiverStatus.restartedBanner == "The receiver stopped and was restarted. Spans sent in the last few seconds may be missing.")
        let back = await waitUntil(3) { model.receiver.isReceiving }
        check("the restarted helper listens on the same ports", back
              && model.receiverStatusText == "Receiving on \(ports.grpc) and \(ports.http)", model.receiverStatusText ?? "nil")
        check("the stored traces stay in the list through the crashes", model.traces.contains { $0.route == ReceiverPayload.route })
        let accepted = await post(port: ports.http, path: "/v1/traces", body: ReceiverPayload.trace)
        let closed = await waitUntil(2) { !model.receiverRestarted }
        check("the banner closes itself after the next trace arrives", accepted == 200 && closed, "HTTP \(accepted)")
        await model.stopHelperAndWait()
    }

    /// Another copy of Magnife with the real helper: Quit waits for the helper
    /// and frees the ports, a relaunch binds them at once, kill -9 ends the helper within 1 s.
    private static func checkAppProcess() async {
        let ports = (grpc: freePort(), http: freePort())
        let store = lifecycleRoot.appending(path: "app/magnife.sqlite")
        guard let app = launchCopy(store: store, ports: ports) else { return check("launch a second Magnife", false) }
        let (helper, listening) = await waitForHelper(of: app, httpPort: ports.http)
        info("app launch: helper accepts traces after \(listening.milliseconds) ms")
        check("a second Magnife starts its helper", helper != nil && app.isRunning)

        // Quit Magnife: the same quit Apple event as ⌘Q.
        let running = NSRunningApplication(processIdentifier: app.processIdentifier)
        let quitAt = ContinuousClock.now
        let asked = running?.terminate() ?? false
        var helperGone: Duration?, appGone: Duration?
        var portsFreeAtExit = false
        _ = await waitUntil(5, every: .milliseconds(2)) {
            if helperGone == nil, let helper, !isAlive(helper) { helperGone = ContinuousClock.now - quitAt }
            if appGone == nil, !app.isRunning {
                appGone = ContinuousClock.now - quitAt
                portsFreeAtExit = portIsFree(ports.http) && portIsFree(ports.grpc)
            }
            return appGone != nil
        }
        info("quit: helper gone after \(helperGone?.milliseconds ?? -1) ms, app gone after \(appGone?.milliseconds ?? -1) ms")
        check("Quit Magnife ends the app", asked && appGone != nil, "terminate \(asked)")
        check("on Quit the app waits for the helper to exit first",
              helperGone != nil && appGone != nil && helperGone! <= appGone!)
        check("after Quit no Magnife process holds the ports", portsFreeAtExit && helper.map { !isAlive($0) } ?? false)

        // A relaunch right away binds the same ports.
        guard let again = launchCopy(store: store, ports: ports) else { return check("relaunch Magnife", false) }
        let (relaunchedHelper, rebound) = await waitForHelper(of: again, httpPort: ports.http)
        info("relaunch after quit: helper accepts traces after \(rebound.milliseconds) ms")
        let sockets = listeningSockets(pid: relaunchedHelper)
        check("a relaunch right after Quit binds both ports",
              relaunchedHelper != nil && sockets.contains("127.0.0.1:\(ports.grpc)") && sockets.contains("127.0.0.1:\(ports.http)"),
              "\(sockets)")

        // kill -9 of the app: the helper's stdin closes and it exits.
        let killedAt = ContinuousClock.now
        kill(again.processIdentifier, SIGKILL)
        var orphanGone: Duration?
        _ = await waitUntil(3, every: .milliseconds(2)) {
            guard let relaunchedHelper, !isAlive(relaunchedHelper) else { return false }
            orphanGone = ContinuousClock.now - killedAt
            return true
        }
        info("kill -9 of the app: helper gone after \(orphanGone?.milliseconds ?? -1) ms")
        check("after kill -9 of the app the helper exits within 1 s",
              (orphanGone ?? .seconds(9)) < .seconds(1), "\(orphanGone?.milliseconds ?? -1) ms")
        _ = await waitUntil(2) { !again.isRunning }
        check("then the ports are free", portIsFree(ports.http) && portIsFree(ports.grpc))
        // A killed copy leaves window state that would ask to reopen windows on the next launch.
        let saved = URL.libraryDirectory.appending(path: "Saved Application State/\(Bundle.main.bundleIdentifier ?? "").savedState")
        try? FileManager.default.removeItem(at: saved)
    }

    // MARK: Tools

    private static func info(_ line: String) {
        print("INFO \(line)")
    }

    /// Starts this executable as a second Magnife with the bundled helper, on
    /// `store` (in /tmp) and `ports`. Its output goes to a log next to the store.
    private static func launchCopy(store: URL, ports: (grpc: Int, http: Int)) -> Process? {
        guard let executable = Bundle.main.executableURL, StoreLocation.isTestLocation(store) else { return nil }
        try? FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
        var environment = ProcessInfo.processInfo.environment
        for key in ["APP_HELPER", "APP_SNAPSHOT", "APP_SNAPSHOT_PAGES", "APP_SELFTEST_ONLY"] { environment[key] = nil }
        environment["APP_STORE"] = store.path
        environment["APP_GRPC_PORT"] = String(ports.grpc)
        environment["APP_HTTP_PORT"] = String(ports.http)
        let log = store.deletingLastPathComponent().appending(path: "app.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let process = Process()
        process.executableURL = executable
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = try? FileHandle(forWritingTo: log)
        process.standardOutput = output ?? FileHandle.nullDevice
        process.standardError = output ?? FileHandle.nullDevice
        return (try? process.run()) == nil ? nil : process
    }

    /// Waits until the app's helper accepts a trace; its pid and how long it took.
    private static func waitForHelper(of app: Process, httpPort: Int) async -> (Int32?, Duration) {
        let started = ContinuousClock.now
        var accepted = false
        let deadline = started + .seconds(5)
        while !accepted, ContinuousClock.now < deadline, app.isRunning {
            accepted = await post(port: httpPort, path: "/v1/traces", body: ReceiverPayload.trace) == 200
            if !accepted { try? await Task.sleep(for: .milliseconds(20)) }
        }
        let elapsed = ContinuousClock.now - started
        return (accepted ? childPIDs(of: app.processIdentifier, named: "magnife-ingest").first : nil, elapsed)
    }

    /// True while `pid` runs (a zombie waiting to be reaped counts as gone).
    static func isAlive(_ pid: Int32) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return false }
        return info.kp_proc.p_stat != SZOMB
    }

    /// The pids of `parent`'s children with this process name (pgrep).
    private static func childPIDs(of parent: Int32, named name: String) -> [Int32] {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-P", String(parent), "-x", name]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        pgrep.standardError = FileHandle.nullDevice
        guard (try? pgrep.run()) != nil else { return [] }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        pgrep.waitUntilExit()
        return output.split(separator: "\n").compactMap { Int32($0) }
    }
}

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
    var milliseconds: Int { Int((seconds * 1000).rounded()) }
}
