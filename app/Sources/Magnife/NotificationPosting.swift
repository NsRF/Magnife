import AppKit
import MagnifeKit
import UserNotifications

/// Where failure notifications go (S-028): macOS's notification center in
/// real runs, a fake that records them in snapshot and self-test runs, which
/// never ask for permission.
protocol NotificationPosting: AnyObject {
    func permission() async -> NotificationPermission
    /// Shows macOS's permission prompt; true when notifications are allowed.
    func requestPermission() async -> Bool
    func post(_ notice: FailureNotice)
}

/// The request a notice becomes: one thread per service, the trace id to
/// open, and the notice's id, so a burst's follow-up replaces its banner.
enum FailureNotificationRequest {
    nonisolated static let traceIDKey = "traceID"

    static func make(_ notice: FailureNotice) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.subtitle = notice.subtitle
        content.body = notice.body
        content.threadIdentifier = notice.threadID
        content.userInfo = [traceIDKey: notice.traceID]
        return UNNotificationRequest(identifier: notice.id, content: content, trigger: nil)
    }
}

/// macOS's notification center.
final class SystemNotificationPoster: NotificationPosting {
    func permission() async -> NotificationPermission {
        switch await Self.authorizationStatus() {
        case .notDetermined: .notDetermined
        case .denied: .denied
        default: .authorized
        }
    }

    func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])) ?? false
    }

    func post(_ notice: FailureNotice) {
        let request = FailureNotificationRequest.make(notice)
        Task {
            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                FileHandle.standardError.write(Data("magnife: notification not posted: \(error)\n".utf8))
            }
        }
    }

    nonisolated private static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}

/// Snapshot and self-test runs: records what would be posted, and answers
/// the permission prompt as `grants` says, without macOS.
final class FakeNotificationPoster: NotificationPosting {
    var status: NotificationPermission = .notDetermined
    var grants = true
    private(set) var requestCount = 0
    private(set) var notices: [FailureNotice] = []
    private(set) var requests: [UNNotificationRequest] = []

    func permission() async -> NotificationPermission { status }

    func requestPermission() async -> Bool {
        requestCount += 1
        status = grants ? .authorized : .denied
        return grants
    }

    func post(_ notice: FailureNotice) {
        notices.append(notice)
        requests.append(FailureNotificationRequest.make(notice))
    }

    func clear() {
        notices = []
        requests = []
    }
}

/// Banners while Magnife is frontmost, and a click that opens the trace
/// (S-028). Set as the center's delegate in applicationWillFinishLaunching,
/// so the click that launched Magnife is not lost (platform decision 9).
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    /// Without `.banner` nothing shows while Magnife is frontmost.
    nonisolated static let presentationOptions: UNNotificationPresentationOptions = [.banner, .list]
    private static var shared: NotificationRouter?
    private let model: AppModel
    private let launchedAt = Date()

    private init(model: AppModel) {
        self.model = model
    }

    /// Real runs only: test runs never touch the notification center.
    static func install(model: AppModel) {
        guard shared == nil, !AppDefaults.isTestRun else { return }
        let router = NotificationRouter(model: model)
        shared = router
        UNUserNotificationCenter.current().delegate = router
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        Self.presentationOptions
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let traceID = response.notification.request.content.userInfo[FailureNotificationRequest.traceIDKey] as? String
        else { return }
        await Self.open(traceID, model: model, justLaunched: Date().timeIntervalSince(launchedAt) < 5)
    }

    /// A click (and the self-test's): like a Recent Errors item (S-027).
    /// When the click launched Magnife, its window is still being made: wait
    /// for it rather than open a second one.
    static func open(_ traceID: String, model: AppModel, justLaunched: Bool) async {
        for _ in 0..<50 where justLaunched && MainWindow.window == nil {
            try? await Task.sleep(for: .milliseconds(40))
        }
        MainWindow.bringForward()
        model.openFailedTrace(traceID)
    }
}
