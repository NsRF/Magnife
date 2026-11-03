import Foundation

/// APP_DEBUG_STALLS=1: prints each main run loop turn that takes over 100 ms,
/// with the app's own work that ran in it (`measure`), to find what a
/// stall under load is made of (S-030). Off otherwise: `measure` just runs.
@MainActor
enum StallLog {
    static let enabled = ProcessInfo.processInfo.environment["APP_DEBUG_STALLS"] == "1"
    private static var turnStart: CFAbsoluteTime = 0
    private static var parts: [(String, Double)] = []
    private static var observer: CFRunLoopObserver?

    static func install() {
        guard enabled, observer == nil else { return }
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

    static func measure<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        guard enabled else { return try body() }
        let start = CFAbsoluteTimeGetCurrent()
        defer { parts.append((name, (CFAbsoluteTimeGetCurrent() - start) * 1_000)) }
        return try body()
    }
}
