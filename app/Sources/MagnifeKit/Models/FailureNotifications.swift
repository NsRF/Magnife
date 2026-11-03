import Foundation

/// A trace that turned Error (the helper's `error_traces`), with what its
/// notification says (S-028).
public struct FailedTrace: Sendable, Hashable {
    public var traceID: String
    public var route: String
    /// The root service: the notification's thread and subtitle.
    public var service: String
    public var startNs: Int64
    /// The first exception of the trace's Error spans, in start order.
    public var exceptionType: String
    public var exceptionMessage: String
    /// The earliest-starting Error span's name, for a trace without an exception.
    public var errorSpanName: String?

    public init(traceID: String, route: String, service: String, startNs: Int64 = 0,
                exceptionType: String = "", exceptionMessage: String = "", errorSpanName: String? = nil) {
        self.traceID = traceID
        self.route = route
        self.service = service
        self.startNs = startNs
        self.exceptionType = exceptionType
        self.exceptionMessage = exceptionMessage
        self.errorSpanName = errorSpanName
    }

    /// The single banner's body: "InvalidOperationException: Cart is empty",
    /// or "Error in span charge-card" when no exception was recorded.
    public var detail: String {
        switch (exceptionType.isEmpty, exceptionMessage.isEmpty) {
        case (false, false): "\(exceptionType): \(exceptionMessage)"
        case (false, true): exceptionType
        case (true, false): exceptionMessage
        case (true, true): errorSpanName.map { "Error in span \($0)" } ?? "Error"
        }
    }
}

/// One notification to post (or to replace, when its id was posted before).
public struct FailureNotice: Sendable, Hashable {
    /// The request identifier. A burst's follow-up reuses its banner's, so
    /// Notification Center keeps one per burst.
    public var id: String
    /// The root service: one thread per service (platform decision 9).
    public var threadID: String
    public var title: String
    public var subtitle: String
    public var body: String
    /// The trace a click opens: the banner's, or the burst's newest.
    public var traceID: String
    /// Traces with errors the notice stands for.
    public var count: Int

    public init(id: String, threadID: String, title: String, subtitle: String, body: String, traceID: String, count: Int) {
        self.id = id
        self.threadID = threadID
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.traceID = traceID
        self.count = count
    }

    /// One trace: title "POST /orders", subtitle "checkout-api", body the exception.
    public static func single(_ trace: FailedTrace, id: String) -> FailureNotice {
        FailureNotice(id: id, threadID: trace.service, title: trace.route, subtitle: trace.service,
                      body: trace.detail, traceID: trace.traceID, count: 1)
    }

    /// A burst: title "3 traces with errors", subtitle "checkout-api", body "Newest: POST /orders".
    public static func burst(count: Int, newest: FailedTrace, id: String) -> FailureNotice {
        FailureNotice(id: id, threadID: newest.service, title: "\(count) traces with errors", subtitle: newest.service,
                      body: "Newest: \(newest.route)", traceID: newest.traceID, count: count)
    }
}

/// Coalesces failure notifications per service (docs/ux.md, S-028).
///
/// The first trace with an error from a service posts a banner at once and
/// opens a 10 s window. More traces with errors from that service within the
/// window post nothing then; at its end one follow-up replaces the banner
/// (same request id) with the burst's count and its newest trace, and a new
/// window opens. A window that ends with nothing new ends the burst; the
/// next trace with an error starts a new one with a new id. So a steady
/// stream of failures posts at most one notification per service every 10 s.
/// Time is passed in, so the rules test without waiting.
public struct FailureCoalescer: Sendable {
    public static let defaultWindow: TimeInterval = 10

    private struct Burst: Sendable {
        var id: String
        var deadline: Date
        /// Every trace in the burst, the banner's included.
        var count: Int
        /// Traces added since the last notice for the burst.
        var unposted: Int
        var newest: FailedTrace
        var traceIDs: Set<String>
    }

    public let window: TimeInterval
    private let idPrefix: String
    private var bursts: [String: Burst] = [:]
    private var burstCount = 0

    /// `idPrefix` keeps one run's request ids apart from another's, so a
    /// relaunch never replaces notifications already in Notification Center.
    public init(window: TimeInterval = defaultWindow, idPrefix: String = "failure") {
        self.window = window
        self.idPrefix = idPrefix
    }

    /// A trace that turned Error at `now`: the banner to post at once, or nil
    /// while its service's window is open (or the trace is in it already).
    /// Follow-ups that are due go first.
    public mutating func add(_ trace: FailedTrace, at now: Date) -> [FailureNotice] {
        var notices = flush(at: now)
        if let seen = bursts[trace.service]?.traceIDs.contains(trace.traceID) {
            guard !seen else { return notices }
            // In place: a copy of the burst would copy its set of ids for every
            // failure, quadratic under a flood (S-030).
            bursts[trace.service]?.count += 1
            bursts[trace.service]?.unposted += 1
            bursts[trace.service]?.newest = trace
            bursts[trace.service]?.traceIDs.insert(trace.traceID)
            return notices
        }
        burstCount += 1
        let id = "\(idPrefix)-\(burstCount)"
        bursts[trace.service] = Burst(id: id, deadline: now.addingTimeInterval(window), count: 1, unposted: 0,
                                      newest: trace, traceIDs: [trace.traceID])
        notices.append(.single(trace, id: id))
        return notices
    }

    /// The follow-ups whose window ended by `now`, oldest deadline first.
    public mutating func flush(at now: Date) -> [FailureNotice] {
        var notices: [FailureNotice] = []
        for (service, var burst) in bursts.sorted(by: { $0.value.deadline < $1.value.deadline }) where burst.deadline <= now {
            guard burst.unposted > 0 else {
                bursts[service] = nil
                continue
            }
            notices.append(.burst(count: burst.count, newest: burst.newest, id: burst.id))
            burst.unposted = 0
            burst.deadline = now.addingTimeInterval(window)
            bursts[service] = burst
        }
        return notices
    }

    /// When the next window ends, nil with no burst open.
    public var nextDeadline: Date? { bursts.values.map(\.deadline).min() }

    /// Forgets every open burst (the setting was turned off).
    public mutating func reset() {
        bursts = [:]
    }
}

/// Whether macOS lets Magnife post notifications.
public enum NotificationPermission: Sendable, Equatable {
    case notDetermined
    case denied
    case authorized

    /// Settings > Notifications' status line under the toggle; nil once allowed.
    public var statusLine: String? {
        switch self {
        case .notDetermined: "Magnife asks for permission when the first trace with an error arrives."
        case .denied: "Notifications for Magnife are off in System Settings."
        case .authorized: nil
        }
    }

    /// What a trace with an error does: post, ask first (only when nobody
    /// has asked, and never twice in one run), or nothing.
    public func action(isEnabled: Bool, askedThisRun: Bool) -> FailureAction {
        guard isEnabled else { return .drop }
        switch self {
        case .authorized: return .post
        case .notDetermined: return askedThisRun ? .drop : .ask
        case .denied: return .drop
        }
    }
}

public enum FailureAction: Sendable, Equatable {
    case post, ask, drop
}
