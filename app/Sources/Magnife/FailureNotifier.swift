import AppKit
import MagnifeKit

/// Notifications for traces with errors (S-028): the setting, macOS's
/// permission, and `FailureCoalescer`'s banners and follow-ups, posted
/// through `poster`. AppModel feeds it the helper's `error_traces`
/// (`AppModel+Notifications.swift`); it keeps going while paused.
@Observable
final class FailureNotifier {
    static let enabledKey = "notifications.failedTraces"

    let poster: any NotificationPosting
    @ObservationIgnored private let defaults: UserDefaults
    /// Settings > Notifications, "Notify me when a trace has an error" (on by
    /// default). Turning it on asks for permission when nobody has asked yet.
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled {
                Task { await askIfNeeded() }
            } else {
                coalescer.reset()
                flushTask?.cancel()
                flushTask = nil
                pendingIDs = []
            }
        }
    }
    /// What macOS allows, once read (Settings' status line).
    private(set) var permission: NotificationPermission?
    /// macOS's prompt was shown in this run; it is never shown twice.
    @ObservationIgnored private(set) var askedThisRun = false
    @ObservationIgnored private var coalescer: FailureCoalescer
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    /// Trace ids from batch lines not yet read (AppModel+Notifications).
    @ObservationIgnored var pendingIDs: [String] = []
    @ObservationIgnored var drainTask: Task<Void, Never>?

    init(poster: any NotificationPosting = AppDefaults.usesFakeNotifications ? FakeNotificationPoster() : SystemNotificationPoster(),
         defaults: UserDefaults = AppDefaults.shared, window: TimeInterval = FailureCoalescer.defaultWindow) {
        self.poster = poster
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        coalescer = Self.coalescer(window: window)
    }

    /// One run's request ids never replace another run's notifications.
    private static func coalescer(window: TimeInterval) -> FailureCoalescer {
        FailureCoalescer(window: window, idPrefix: "failure-\(UUID().uuidString.prefix(8))")
    }

    /// The fake poster of snapshot and self-test runs.
    var fake: FakeNotificationPoster? { poster as? FakeNotificationPoster }

    /// Starts over with another window (self-test: seconds, not 10).
    func reset(window: TimeInterval = FailureCoalescer.defaultWindow) {
        flushTask?.cancel()
        flushTask = nil
        pendingIDs = []
        askedThisRun = false
        coalescer = Self.coalescer(window: window)
    }

    func refreshPermission() async {
        let current = await poster.permission()
        if permission != current { permission = current }
    }

    /// Whether a trace with an error may post now; asks macOS first when
    /// nobody has (the first failure, docs/ux.md). A denial changes nothing else.
    func mayPost() async -> Bool {
        await refreshPermission()
        switch (permission ?? .notDetermined).action(isEnabled: isEnabled, askedThisRun: askedThisRun) {
        case .post: return true
        case .drop: return false
        case .ask:
            askedThisRun = true
            let granted = await poster.requestPermission()
            await refreshPermission()
            return granted && isEnabled
        }
    }

    /// The setting was turned on: ask when nobody has asked yet.
    private func askIfNeeded() async {
        await refreshPermission()
        guard isEnabled, permission == .notDetermined, !askedThisRun else { return }
        askedThisRun = true
        _ = await poster.requestPermission()
        await refreshPermission()
    }

    /// Posts what the traces' arrival (oldest first) makes due now, and
    /// waits for the next window to end.
    func post(_ traces: [FailedTrace], at now: Date = Date()) {
        guard isEnabled else { return }
        for trace in traces {
            for notice in coalescer.add(trace, at: now) { poster.post(notice) }
        }
        scheduleFlush()
    }

    private func scheduleFlush() {
        flushTask?.cancel()
        guard let deadline = coalescer.nextDeadline else { return flushTask = nil }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
            guard let self, !Task.isCancelled else { return }
            for notice in self.coalescer.flush(at: Date()) where self.isEnabled { self.poster.post(notice) }
            self.scheduleFlush()
        }
    }

    /// Settings' "Open System Settings": Notifications > Magnife.
    func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? "com.nasserfarhat.magnife"
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }
}
