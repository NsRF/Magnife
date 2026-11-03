import AppKit
import MagnifeKit

/// S-029's launch timing. With APP_LAUNCH_PROBE=<file in /tmp>, this launch
/// writes one JSON line there once the window shows stored rows: the time
/// of each step since the process started (the kernel's start time, so
/// loading the executable counts), and what the window shows (scope, rows,
/// selected trace, focus). The self-test launches copies of Magnife with it
/// (SelfTest+Launch.swift). Without it, nothing here runs.
@MainActor
enum LaunchProbe {
    private static let path: String? = {
        guard let path = ProcessInfo.processInfo.environment["APP_LAUNCH_PROBE"], !path.isEmpty,
              StoreLocation.isTestLocation(URL(fileURLWithPath: path)) else { return nil }
        return path
    }()
    private static var marks: [String: Double] = [:]

    /// Milliseconds since this process started.
    static func sinceProcessStart() -> Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return -1 }
        let start = info.kp_proc.p_starttime
        let started = Double(start.tv_sec) + Double(start.tv_usec) / 1e6
        return (Date().timeIntervalSince1970 - started) * 1_000
    }

    static func mark(_ name: String) {
        guard path != nil, marks[name] == nil else { return }
        marks[name] = sinceProcessStart()
    }

    /// Waits, a turn of the run loop at a time, until the window is on
    /// screen with the list's rows drawn, then writes the line.
    static func watch(model: AppModel) {
        guard let path else { return }
        Task {
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                if let window = shownWindow(model) {
                    window.displayIfNeeded()
                    mark("rows_shown")
                    // The focus moves to the list right after the rows (AppModel.finishLaunch).
                    // So does the restored trace's first read (or S-015's state when it is gone).
                    for _ in 0..<100 where !listHasFocus(model, in: window) || model.isOpeningTrace {
                        try? await Task.sleep(for: .milliseconds(10))
                    }
                    write(model, window: window, to: path)
                    return
                }
                try? await Task.sleep(for: .milliseconds(2))
            }
            write(model, window: nil, to: path)
        }
    }

    /// The main window, visible, with the list's table showing rows (or an empty store's state).
    private static func shownWindow(_ model: AppModel) -> NSWindow? {
        guard model.storeState == .ready, let table = model.listScroller.tableView,
              let window = table.window, window.isVisible else { return nil }
        return table.numberOfRows > 0 || model.traces.isEmpty ? window : nil
    }

    private static func listHasFocus(_ model: AppModel, in window: NSWindow) -> Bool {
        window.firstResponder === model.listScroller.tableView
    }

    private static func write(_ model: AppModel, window: NSWindow?, to path: String) {
        var line: [String: Any] = marks
        line["rows"] = model.listScroller.rowCount
        line["title"] = model.title
        line["selected"] = model.selectedTraceID ?? NSNull()
        line["selected_row"] = model.selectedTraceID.flatMap { id in model.traces.firstIndex { $0.id == id } } ?? NSNull()
        line["pruned"] = model.prunedTraceID ?? NSNull()
        line["focus_in_list"] = window.map { listHasFocus(model, in: $0) } ?? false
        line["filter"] = TraceQuery.format(model.traceFilter)
        line["shows_filter_bar"] = model.showsTraceFilterBar
        line["receiver"] = model.receiverStatusText ?? NSNull()
        line["windows"] = NSApp.windows.map { "\($0.className) visible \($0.isVisible)" }
        guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        FileManager.default.createFile(atPath: path, contents: data + Data("\n".utf8))
    }
}
