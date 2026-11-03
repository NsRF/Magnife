import Foundation

/// APP_DEBUG_STALLS=1: prints each main run loop turn that takes over 100 ms,
/// with the app's own work that ran in it (`measure`), to find what a
/// stall under load is made of (S-030), and each main-thread hang over
/// 100 ms ("HANG", a 5 ms heartbeat, App Nap off as in the self-test, so a
/// hidden or locked screen's timer deferral is not counted). Off otherwise:
/// `measure` just runs.
@MainActor
enum StallLog {
    static let enabled = ProcessInfo.processInfo.environment["APP_DEBUG_STALLS"] == "1"
    private static var turnStart: CFAbsoluteTime = 0
    private static var parts: [(String, Double)] = []
    private static var observer: CFRunLoopObserver?

    static func install() {
        guard enabled, observer == nil else { return }
        watchHangs()
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { _, activity in
            MainActor.assumeIsolated {
                let now = CFAbsoluteTimeGetCurrent()
                if activity == .afterWaiting {
                    turnStart = now
                    parts = []
                } else if turnStart > 0 {
                    let ms = (now - turnStart) * 1_000
                    if ms > 100 {
                        let mine = parts.sorted { $0.1 > $1.1 }.prefix(6).map { "\($0.0) \(Int($0.1))" }.joined(separator: ", ")
                        FileHandle.standardError.write(Data("STALL \(Int(ms)) ms: \(mine)\n".utf8))
                    }
                    turnStart = 0
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    /// A main-actor heartbeat every 5 ms: each gap over 100 ms is a hang
    /// people would feel (input waits that long), printed as "HANG <ms> ms".
    /// A long run loop turn above is not one by itself: a turn can run many
    /// short jobs back to back while input still gets through between them.
    private static var activity: NSObjectProtocol?

    private static func watchHangs() {
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                         reason: "APP_DEBUG_STALLS measures main-thread hangs")
        Task { @MainActor in
            var last = CFAbsoluteTimeGetCurrent()
            while true {
                try? await Task.sleep(for: .milliseconds(5))
                let now = CFAbsoluteTimeGetCurrent()
                let gap = (now - last) * 1_000
                if gap > 100 { FileHandle.standardError.write(Data("HANG \(Int(gap)) ms\n".utf8)) }
                last = now
            }
        }
    }

    static func measure<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        guard enabled else { return try body() }
        let start = CFAbsoluteTimeGetCurrent()
        defer { parts.append((name, (CFAbsoluteTimeGetCurrent() - start) * 1_000)) }
        return try body()
    }
}
