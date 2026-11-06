import AppKit
import MagnifeKit

/// S-030: the window under a flood. The real helper on free ports writes a
/// fresh store the window reads (its batch lines go to the model, as the
/// app's own helper's do); the sample sender sends 5,000 spans/s for 60 s
/// (APP_LOAD_SECONDS shortens it) while the check scrolls, selects rows
/// with the keyboard, opens traces, and visits the Logs view. A heartbeat
/// on the main actor measures the longest stall.
extension SelfTest {
    static func checkLoad(_ model: AppModel) async {
        let env = ProcessInfo.processInfo.environment
        guard let helper = AppModel.helperExecutable(environment: [:]),
              let sender = env["APP_SAMPLE_SENDER"].map(URL.init(fileURLWithPath:)),
              let window = MainWindow.window, let original = model.reader?.url else {
            return check("the helper, APP_SAMPLE_SENDER and the window exist", false)
        }
        let seconds = Int(env["APP_LOAD_SECONDS"] ?? "") ?? 60
        let store = TestRun.scratch("load").appending(path: "magnife.sqlite")
        let ports = (grpc: freePort(), http: freePort())
        let supervisor = HelperSupervisor(configuration: HelperConfiguration(
            executableURL: helper, databaseURL: store, grpcPort: ports.grpc, httpPort: ports.http))
        var listening = false
        let events = Task { @MainActor in
            for await event in supervisor.events {
                switch event {
                case .helper(.ports): listening = true
                case .helper(.batch): model.handle(event)
                default: break
                }
            }
        }
        supervisor.start()
        guard await waitUntil(5, { listening }) else { return check("the load helper listens", false) }
        model.applyTraceFilter(.cleared)
        model.showContentMode(.traces)
        model.selectedTraceID = nil
        await model.useStore(at: store)
        await ensureKey(window)
        model.focus(.list)

        // Switching views before the flood, for comparison.
        var switches: [Int] = []
        let rounds = Int(env["APP_LOAD_SWITCHES"] ?? "") ?? 2
        for mode in (0..<rounds).flatMap({ _ in [ContentMode.logs, .traces] }) {
            let beat = Heartbeat()
            beat.start()
            model.showContentMode(mode)
            try? await Task.sleep(for: .milliseconds(400))
            switches.append(Int(beat.stop()))
        }
        print("INFO load: switching Traces and Logs with no load, longest stall each: \(switches.map { "\($0) ms" })")

        let heartbeat = Heartbeat()
        heartbeat.start()
        let started = ContinuousClock.now
        let load = Task {
            await run(sender, ["--rate", "5000", "--duration", "\(seconds)s", "--protocol", "grpc",
                               "--grpc", "127.0.0.1:\(ports.grpc)", "--http", "127.0.0.1:\(ports.http)"])
        }
        var steps: [String: Int] = [:]
        var step = 0
        // Each stall over 50 ms, with the step that ran last before it and
        // the main thread's CPU time during it: a stall the main thread spent
        // on a core is the app's work; the rest of it the thread waited.
        let current = StepName()
        var stalls: [(ms: Int, cpu: Int, step: String)] = []
        let watch = Task { @MainActor in
            var last = ContinuousClock.now
            var lastCPU = CPUTime.thread
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(5))
                let gap = (ContinuousClock.now - last).seconds * 1_000
                let cpu = CPUTime.thread - lastCPU
                if gap > 50 { stalls.append((Int(gap), Int(cpu), current.name)) }
                last = ContinuousClock.now
                lastCPU = CPUTime.thread
            }
        }
        while ContinuousClock.now - started < .seconds(seconds) {
            try? await Task.sleep(for: .milliseconds(250))
            step += 1
            // APP_LOAD_STEPS=<names> limits the steps (profiling); the others wait.
            let only = env["APP_LOAD_STEPS"].map { Set($0.split(separator: ",").map(String.init)) }
            current.name = only.map { names in
                let name = stepName(step)
                return names.contains(name) ? interact(model, window: window, step: step) : "wait"
            } ?? interact(model, window: window, step: step)
            steps[current.name, default: 0] += 1
        }
        watch.cancel()
        let result = await load.value
        // The last batches land and the list catches up.
        model.showContentMode(.traces)
        model.listScroller.scrollToTop()
        try? await Task.sleep(for: .seconds(1.5))
        let stall = heartbeat.stop()
        // Every stall counts against the acceptance's 100 ms (M3 review 1):
        // browsing (scrolling, keys, selecting) and switching Traces | Logs,
        // which rebuilds the content and detail columns and the toolbar items
        // in SwiftUI, are printed apart so a failure says which one it was.
        let switching: Set<String> = ["logs view", "traces view"]
        let browsing = stalls.filter { !switching.contains($0.step) }.max { $0.ms < $1.ms }
        let switchStall = stalls.filter { switching.contains($0.step) }.max { $0.ms < $1.ms }
        let stored = (try? await model.reader?.traceCount()) ?? 0
        let spans = result.output.firstMatch(of: /: (\d+) spans in/).flatMap { Int($0.1) } ?? 0
        print("INFO load: \(spans.formatted()) spans in \(seconds) s (\(stored.formatted()) traces stored), "
              + "longest main-thread stall \(Int(stall)) ms, \(model.traces.count) rows read, steps \(steps.sorted { $0.key < $1.key })")
        let worst = stalls.sorted { $0.ms > $1.ms }.prefix(8).map { "\($0.ms) ms (\($0.cpu) ms on CPU) after \($0.step)" }
        print("INFO load: \(stalls.count) stalls over 50 ms; longest: \(worst.joined(separator: ", "))")
        check("the sender's exports are all accepted (\(result.output.split(separator: "\n").last ?? ""))", result.status == 0)
        // The acceptance's number is the limit, and S-030 is blocked on both
        // parts (docs/STORIES.md): each prints BLOCKED while it is over, PASS
        // once it holds, never a quiet pass. Not the Mac's load: the main
        // thread is on a core for nearly all of every long stall, at rest
        // and under load alike (docs/PROGRESS.md, 2026-11-06), so the
        // printed CPU time is the app's own work.
        checkBlocked("S-030", "at 5,000 spans/s for \(seconds) s, while scrolling and selecting, no main-thread hang over 100 ms",
                     ms: Double(browsing?.ms ?? 0), limit: 100,
                     "\(browsing?.cpu ?? 0) ms on CPU, after \(browsing?.step ?? "none"), the whole run \(Int(stall)) ms")
        checkBlocked("S-030", "under that load, switching Traces and Logs has no main-thread hang over 100 ms",
                     ms: Double(switchStall?.ms ?? 0), limit: 100, "\(switchStall?.cpu ?? 0) ms on CPU")
        // Paging (S-004, S-030): at the top the list reads one page of 200 rows, never every trace.
        check("the list pages from the database: \(model.traces.count) rows read of \(stored.formatted()) traces",
              stored > 1_000 && model.traces.count <= 2 * TraceList.pageSize && model.listTraceCount >= stored - 1_000,
              "subtitle count \(model.listTraceCount)")
        events.cancel()
        await supervisor.stop()
        model.selectedTraceID = nil
        await model.useStore(at: original)
        try? FileManager.default.removeItem(at: store.deletingLastPathComponent())
    }

    /// One step of what people do while the flood runs, every 250 ms: arrow
    /// keys and Page Down in the list, a row opened, the list scrolled away
    /// and back, the Logs view for a while, the span detail's Trace Logs.
    private static func stepName(_ step: Int) -> String {
        switch step % 40 {
        case 0..<8: "down"
        case 8: "page down"
        case 9..<14: "scroll"
        case 14: "scroll to end"
        case 15..<18: "select"
        case 18: "newest"
        case 19: "trace logs"
        case 20: "span tab"
        case 21: "logs view"
        case 22..<28: "logs down"
        case 28: "logs scroll"
        case 29: "traces view"
        default: "wait"
        }
    }

    private static func interact(_ model: AppModel, window: NSWindow, step: Int) -> String {
        switch step % 40 {
        case 0..<8:
            if window.firstResponder !== model.listScroller.tableView { model.focus(.list) }
            _ = press(window, String(UnicodeScalar(NSDownArrowFunctionKey)!), keyCode: 125)
            return "down"
        case 8:
            _ = press(window, String(UnicodeScalar(NSPageDownFunctionKey)!), keyCode: 121)
            return "page down"
        case 9..<14:
            model.listScroller.scroll(toOffset: CGFloat(400 + 100 * (step % 5)))
            return "scroll"
        case 14:
            model.listScroller.scrollToBottom()
            return "scroll to end"
        case 15..<18:
            if let trace = model.traces.dropFirst(3).first { model.selectedTraceID = trace.id }
            return "select"
        case 18:
            model.showNewestTraces()
            return "newest"
        case 19:
            model.showSpanDetailTab(.traceLogs)
            return "trace logs"
        case 20:
            // One action per step, as people do them: back to the Span tab, then Logs.
            model.showSpanDetailTab(.span)
            return "span tab"
        case 21:
            model.showContentMode(.logs)
            return "logs view"
        case 22..<28:
            model.focus(.list)
            _ = press(window, String(UnicodeScalar(NSDownArrowFunctionKey)!), keyCode: 125)
            return "logs down"
        case 28:
            model.logScroller.scroll(toOffset: 600)
            return "logs scroll"
        case 29:
            model.showContentMode(.traces)
            return "traces view"
        default:
            return "wait"
        }
    }
}

/// The step the load check ran last, read by its stall watch.
@MainActor
private final class StepName {
    var name = "start"
}
