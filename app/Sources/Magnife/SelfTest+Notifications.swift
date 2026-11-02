import AppKit
import MagnifeKit
import UserNotifications

/// S-028: batch lines' `error_traces` become notifications through the
/// fake poster (self-test runs never ask macOS): permission on the first
/// failure, the words, one thread per service, a burst coalesced into one
/// follow-up (a 1 s window here instead of 10 s), paused, the setting off,
/// permission denied, and a click opening the trace with the window closed.
extension SelfTest {
    static func checkNotifications(_ model: AppModel) async {
        let notifier = model.failureNotifier
        guard let fake = notifier.fake, let reader = model.reader else {
            return check("self-test runs post notifications through the fake poster", false)
        }
        let suite = "com.nasserfarhat.magnife.selftest.notifier"
        UserDefaults().removePersistentDomain(forName: suite)
        if let defaults = UserDefaults(suiteName: suite) {
            check("\"Notify me when a trace has an error\" is on by default",
                  FailureNotifier(poster: FakeNotificationPoster(), defaults: defaults).isEnabled)
            UserDefaults().removePersistentDomain(forName: suite)
        }
        notifier.isEnabled = true
        fake.status = .notDetermined
        fake.grants = true
        fake.clear()
        notifier.reset(window: 1)
        model.applyTraceFilter(.cleared)
        await model.reload()

        let all = (try? await reader.latestTraces(limit: 100_000)) ?? []
        guard let pay = all.first(where: { $0.route == "POST /checkout/pay" && $0.status == .error }),
              let other = all.first(where: { $0.status == .error && $0.rootService != pay.rootService }) else {
            return check("the seed set has traces with errors from two services", false)
        }
        await notifier.refreshPermission()
        check("not yet asked, Settings says when Magnife asks",
              notifier.permission?.statusLine == "Magnife asks for permission when the first trace with an error arrives.")
        let asksBefore = fake.requestCount

        func batch(_ ids: [String]) {
            model.handle(.helper(.batch(BatchEvent(seq: 0, spans: ids.count, logs: 0, traces: ids, errorTraces: ids))))
        }
        batch([pay.traceID])
        let first = await waitUntil(3) { fake.notices.count == 1 }
        check("the first trace with an error asks for permission", fake.requestCount == asksBefore + 1)
        check("then its banner posts at once", first, "\(fake.notices.count) posted")
        let spans = (try? await reader.spans(traceID: pay.traceID)) ?? []
        let exception = spans.filter { $0.status == .error }.sorted { $0.startNs < $1.startNs }.flatMap(\.exceptions).first
        let notice = fake.notices.first
        check("the banner reads route, service and the first exception (docs/ux.md)",
              notice?.title == pay.route && notice?.subtitle == pay.rootService
                && exception.map { notice?.body == "\($0.type): \($0.message)" } == true,
              "\(notice?.title ?? "") | \(notice?.subtitle ?? "") | \(notice?.body ?? "")")
        let request = fake.requests.first
        check("its request is in the service's thread and carries the trace id",
              request?.content.threadIdentifier == pay.rootService && request?.identifier == notice?.id
                && request?.content.userInfo[FailureNotificationRequest.traceIDKey] as? String == pay.traceID)
        check("banners show while Magnife is frontmost (platform decision 9)",
              NotificationRouter.presentationOptions.contains(.banner) && NotificationRouter.presentationOptions.contains(.list))

        batch([other.traceID])
        let grouped = await waitUntil(3) { fake.notices.count == 2 }
        check("another service's trace posts its own banner in its own thread",
              grouped && fake.notices.last?.threadID == other.rootService && fake.notices.last?.id != notice?.id,
              fake.notices.map(\.threadID).joined(separator: ", "))
        check("asking happens once", fake.requestCount == asksBefore + 1)
        _ = await waitUntil(3) { notifier.drainTask == nil }
        try? await Task.sleep(for: .seconds(1.2))

        await checkNotificationBurst(model, fake: fake, reader: reader)
        await checkNotificationsOff(model, fake: fake, traceID: pay.traceID)
        await checkNotificationClick(model, trace: pay)
        notifier.reset()
        fake.clear()
    }

    /// Several traces with errors from one service within the window: one
    /// banner, then one follow-up that replaces it with the count; paused too.
    private static func checkNotificationBurst(_ model: AppModel, fake: FakeNotificationPoster, reader: TelemetryReader) async {
        let env = ProcessInfo.processInfo.environment
        guard let sender = env["APP_SAMPLE_SENDER"].map(URL.init(fileURLWithPath:)),
              let grpc = env["APP_SEED_GRPC"], let http = env["APP_SEED_HTTP"] else {
            return check("APP_SEED_GRPC and APP_SEED_HTTP name the seed helper (tools/selftest.sh)", false)
        }
        let before = Set(((try? await reader.latestTraces(limit: 100_000)) ?? []).map(\.traceID))
        _ = await run(sender, ["--protocol", "http-protobuf", "--scenarios", "exception", "--volume", "12",
                               "--grpc", grpc, "--http", http])
        var burst: [TraceSummary] = []
        for _ in 0..<50 {
            burst = ((try? await reader.latestTraces(limit: 100_000)) ?? [])
                .filter { !before.contains($0.traceID) && $0.status == .error }
            if burst.count >= 3 { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let service = burst.first?.rootService
        burst = Array(burst.filter { $0.rootService == service }.sorted { $0.startNs < $1.startNs }.prefix(3))
        guard burst.count == 3, let newest = burst.last else {
            return check("the sender's traces with errors arrive", false, "\(burst.count)")
        }
        fake.clear()
        model.failureNotifier.reset(window: 1)
        model.pause()
        for trace in burst {
            model.handle(.helper(.batch(BatchEvent(seq: 0, spans: 1, logs: 0, traces: [trace.traceID],
                                                   errorTraces: [trace.traceID]))))
            _ = await waitUntil(2) { model.failureNotifier.drainTask == nil }
        }
        check("a burst posts one banner at once, while paused too", fake.notices.count == 1, "\(fake.notices.count)")
        let followed = await waitUntil(3) { fake.notices.count == 2 }
        let last = fake.notices.last
        check("at the window's end one follow-up names the count (docs/ux.md)",
              followed && last?.title == "3 traces with errors" && last?.subtitle == service
                && last?.body == "Newest: \(newest.route)", "\(fake.notices.map(\.title))")
        check("the follow-up replaces the banner, so Notification Center keeps one per burst",
              last?.id == fake.notices.first?.id && fake.requests.last?.identifier == fake.requests.first?.identifier)
        check("clicking a burst opens its newest trace", last?.traceID == newest.traceID)
        try? await Task.sleep(for: .seconds(1.5))
        check("a quiet window ends the burst with nothing more", fake.notices.count == 2, "\(fake.notices.count)")
        model.resume()
    }

    /// The setting off posts nothing; permission denied (in System Settings
    /// or at the prompt) posts nothing and asks no more; turning the setting
    /// on asks when nobody has.
    private static func checkNotificationsOff(_ model: AppModel, fake: FakeNotificationPoster, traceID: String) async {
        let notifier = model.failureNotifier
        func send() async {
            model.handle(.helper(.batch(BatchEvent(seq: 0, spans: 1, logs: 0, traces: [traceID], errorTraces: [traceID]))))
            _ = await waitUntil(2) { notifier.drainTask == nil }
            try? await Task.sleep(for: .milliseconds(300))
        }
        fake.clear()
        notifier.reset(window: 1)
        notifier.isEnabled = false
        await send()
        check("with the setting off nothing posts", fake.notices.isEmpty)
        let asks = fake.requestCount
        notifier.isEnabled = true

        fake.status = .denied
        notifier.reset(window: 1)
        await send()
        check("permission denied in System Settings: nothing posts and nothing asks",
              fake.notices.isEmpty && fake.requestCount == asks)
        check("Settings says notifications are off in System Settings",
              notifier.permission?.statusLine == "Notifications for Magnife are off in System Settings.")

        fake.status = .notDetermined
        fake.grants = false
        notifier.reset(window: 1)
        let selected = model.selectedTraceID
        await send()
        await send()
        check("denying at the prompt asks once and posts nothing",
              fake.requestCount == asks + 1 && fake.notices.isEmpty && notifier.permission == .denied)
        check("denying changes nothing else", model.selectedTraceID == selected && notifier.isEnabled)

        fake.status = .notDetermined
        fake.grants = true
        notifier.reset(window: 1)
        notifier.isEnabled = false
        notifier.isEnabled = true
        check("turning the setting on asks for permission", await waitUntil(2) { fake.requestCount == asks + 2 })
        check("allowed, Settings shows no status line", await waitUntil(2) { notifier.permission?.statusLine == nil })
    }

    /// A click, with the main window closed: the trace opens as from Recent Errors (S-027).
    private static func checkNotificationClick(_ model: AppModel, trace: TraceSummary) async {
        model.selectedTraceID = nil
        for window in NSApp.windows where window.canBecomeMain { window.close() }
        _ = await waitUntil(2) { MainWindow.window == nil }
        await NotificationRouter.open(trace.traceID, model: model, justLaunched: false)
        let opened = await waitUntil(5) {
            model.openTrace?.traceID == trace.traceID && model.selectedSpanID != nil
                && model.selectedSpanID == model.waterfall.firstErrorSpanID
        }
        check("clicking a notification brings the closed main window back", MainWindow.window?.isVisible == true)
        check("and opens the trace on its earliest Error span, as from Recent Errors", opened,
              "\(model.openTrace?.route ?? "nil") \(model.selectedSpanID ?? "nil")")
        check("the span detail shows on Span", model.showsSpanDetail && model.spanDetailTab == .span)
        model.selectedTraceID = nil
    }
}
