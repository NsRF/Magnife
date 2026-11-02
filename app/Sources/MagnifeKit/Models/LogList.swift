import Foundation

// The Logs view's live list (S-013): every log in scope, newest first by
// time, paged from the database, holding still while you are scrolled away
// from the top, the same rules as the trace list (design decision 6).
// Logs never change once stored, so a held list only counts the logs that
// arrived after its rows were read (`logs.id` grows with every insert).

/// What narrows the Logs list: the sidebar's service (S-013), and the
/// filter bar's levels and "Body contains" text (S-014).
public struct LogFilter: Sendable, Hashable {
    /// The sidebar's service, nil for all services. The filter bar's Service
    /// pop-up is the same setting.
    public var service: String?
    /// The level chips that are on. None on means every log, those with no
    /// level (severity 0) included; any on keeps their OTel ranges only.
    public var levels: Set<SeverityLevel>
    /// Kept when the body contains it, ignoring the case of A to Z (as
    /// SQLite's lower() does); empty keeps every body.
    public var bodyContains: String

    public init(service: String? = nil, levels: Set<SeverityLevel> = [], bodyContains: String = "") {
        self.service = service
        self.levels = levels
        self.bodyContains = bodyContains
    }

    /// The filter bar's own filters are on (levels or body): the list may
    /// hide logs of the scope, so the subtitle reads "312 of 1,204 logs".
    public var narrowsScope: Bool { !levels.isEmpty || !bodyText.isEmpty }

    /// Any filter is on, the service included: Clear Filters has something to clear.
    public var isActive: Bool { service != nil || narrowsScope }

    /// The body text as matched: surrounding spaces do not count.
    public var bodyText: String { bodyContains.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The severity ranges the levels keep, merged where they touch and in
    /// order: ERROR and FATAL are one range, 17-24.
    public var severityRanges: [ClosedRange<Int>] {
        var ranges: [ClosedRange<Int>] = []
        for level in levels.sorted() {
            if let last = ranges.last, last.upperBound + 1 == level.range.lowerBound {
                ranges[ranges.count - 1] = last.lowerBound...level.range.upperBound
            } else {
                ranges.append(level.range)
            }
        }
        return ranges
    }

    /// True when the filter keeps this log (the rule the SQL applies).
    public func keeps(_ log: LogRecord) -> Bool {
        if let service, log.serviceName != service { return false }
        if !levels.isEmpty, !severityRanges.contains(where: { $0.contains(log.severityNumber) }) { return false }
        let text = bodyText
        return text.isEmpty || Self.asciiLowercased(log.body).contains(Self.asciiLowercased(text))
    }

    /// A to Z made lower case, nothing else: SQLite's lower() without ICU.
    static func asciiLowercased(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            (65...90).contains(scalar.value) ? Unicode.Scalar(scalar.value + 32)! : scalar
        }))
    }

    /// A click on a level chip shows only that level; clicking the only
    /// chip on shows every level again. ⌘-click or Space (`adding`) turns
    /// one chip on or off and leaves the others (docs/ux.md, Filter bar).
    public func clicking(_ level: SeverityLevel, adding: Bool) -> LogFilter {
        var next = self
        if adding {
            if next.levels.contains(level) { next.levels.remove(level) } else { next.levels.insert(level) }
        } else {
            next.levels = levels == [level] ? [] : [level]
        }
        return next
    }

    /// Clear Filters: every level, any body, All Services.
    public static let cleared = LogFilter()
}

extension SeverityLevel {
    /// A level chip's tooltip: "Show only ERROR logs, ERROR to ERROR4".
    public var chipHelp: String { "Show only \(title) logs, \(title) to \(title)4" }
}

/// One row of the Logs list: the log, ready to show, and whether Magnife
/// has spans for its trace (Open Trace needs them).
public struct LogListItem: Sendable, Hashable, Identifiable {
    public let line: LogLine
    public let hasStoredTrace: Bool

    public init(line: LogLine, hasStoredTrace: Bool) {
        self.line = line
        self.hasStoredTrace = hasStoredTrace
    }

    public var id: Int64 { line.id }
    public var record: LogRecord { line.record }
    /// The log carries a trace id: its row shows the arrow.
    public var hasTrace: Bool { !(record.traceID ?? "").isEmpty }
    /// Open Trace can show it: a trace id with stored spans.
    public var canOpenTrace: Bool { hasTrace && hasStoredTrace }

    /// What VoiceOver reads for the row (docs/ux.md, S-013): "14:02:31,
    /// ERROR, checkout-api, Payment declined, has trace".
    public var accessibilityLabel: String {
        let firstLine = record.body.prefix { !$0.isNewline }
        return [line.spokenTime, record.level?.title ?? "no level", record.serviceName, String(firstLine.prefix(200)),
                hasTrace ? "has trace" : ""]
            .filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// The first page of the Logs list with the count in scope, read in one
/// transaction: the newest log id and the last seq it reflects.
public struct LogPage: Sendable, Equatable {
    public var items: [LogListItem]
    /// The newest log id in the store when the page was read; while the list
    /// holds still, logs above it are new.
    public var lastID: Int64
    /// meta.last_seq: a read older than the rows shown is dropped.
    public var lastSeq: Int64
    /// Every log the filter keeps, for the window's subtitle.
    public var logCount: Int
    /// Every log of the service scope, the filter bar aside: "312 of 1,204 logs".
    public var scopeCount: Int
    /// Read while paused (S-010): only logs up to this id, and `newCount` above it.
    public var upTo: Int64?
    public var newCount: Int

    public init(items: [LogListItem], lastID: Int64, lastSeq: Int64, logCount: Int? = nil, scopeCount: Int? = nil,
                upTo: Int64? = nil, newCount: Int = 0) {
        self.items = items
        self.lastID = lastID
        self.lastSeq = lastSeq
        self.logCount = logCount ?? items.count
        self.scopeCount = scopeCount ?? logCount ?? items.count
        self.upTo = upTo
        self.newCount = newCount
    }
}

/// What changed while the Logs list holds still: how many logs in scope
/// arrived after its base id.
public struct HeldLogs: Sendable, Equatable {
    public var newCount: Int
    public var lastSeq: Int64

    public init(newCount: Int, lastSeq: Int64) {
        self.newCount = newCount
        self.lastSeq = lastSeq
    }
}

/// A read of the Logs list, with the filter it was made for.
public enum LogListRead: Sendable {
    case page(LogPage, filter: LogFilter)
    /// The count of new logs, read while the list held still at `base`.
    case held(HeldLogs, filter: LogFilter, base: Int64)

    public var filter: LogFilter {
        switch self {
        case .page(_, let filter), .held(_, let filter, _): filter
        }
    }

    public var lastSeq: Int64 {
        switch self {
        case .page(let page, _): page.lastSeq
        case .held(let held, _, _): held.lastSeq
        }
    }
}

/// What the Logs list shows, and what a read does to it: a page at the top
/// replaces the rows; held (scrolled away, or paused) nothing moves and the
/// logs that arrived are counted; a read for another filter, or older than
/// the rows shown, is dropped.
public struct LogListState: Sendable, Equatable {
    public var filter: LogFilter
    public var items: [LogListItem]
    /// The newest log id when the shown rows were read.
    public var baseID: Int64
    /// The last seq applied, so an older read never replaces a newer one.
    public var appliedSeq: Int64
    /// Scrolled away from the top: the rows hold still.
    public var isHeld: Bool
    /// Logs that arrived after `baseID` while the list holds still.
    public var newCount: Int
    /// A full page came back, so there may be older rows to read.
    public var hasMore: Bool
    /// Every log the filter keeps, and every log of its service scope, when
    /// the rows were read (the subtitle).
    public var logCount: Int
    public var scopeCount: Int
    /// While paused (S-010): the log id the list paused at.
    public var pausedID: Int64?
    /// A page for this filter has been applied (the empty state waits for it).
    public var isLoaded: Bool

    public init(filter: LogFilter = LogFilter(), items: [LogListItem] = [], baseID: Int64 = 0, appliedSeq: Int64 = 0,
                isHeld: Bool = false, newCount: Int = 0, hasMore: Bool = false, logCount: Int = 0,
                scopeCount: Int = 0, pausedID: Int64? = nil, isLoaded: Bool = false) {
        self.filter = filter
        self.items = items
        self.baseID = baseID
        self.appliedSeq = appliedSeq
        self.isHeld = isHeld
        self.newCount = newCount
        self.hasMore = hasMore
        self.logCount = logCount
        self.scopeCount = scopeCount
        self.pausedID = pausedID
        self.isLoaded = isLoaded
    }

    public var isPaused: Bool { pausedID != nil }

    /// The next read only counts: the list holds still and shows rows.
    public var readsHeld: Bool { (isHeld || isPaused) && !items.isEmpty }

    /// Paused at the id the shown rows were read at, so every log stored
    /// after it counts as new. A list never read pauses at `latestID`.
    public func paused(latestID: Int64) -> LogListState {
        var next = self
        if next.pausedID == nil { next.pausedID = isLoaded ? baseID : latestID }
        return next
    }

    /// The state after `read`, or nil when the read must be dropped.
    public func applying(_ read: LogListRead) -> LogListState? {
        guard read.filter == filter, read.lastSeq >= appliedSeq else { return nil }
        var next = self
        switch read {
        case .page(let page, _):
            // Scrolled away or paused while reading: inserting now would move the rows under the pointer.
            guard !readsHeld, page.upTo == pausedID else { return nil }
            next.items = page.items
            // A Resume read can ask for more than a page.
            next.hasMore = page.items.count >= LogList.pageSize
            next.baseID = pausedID ?? page.lastID
            next.appliedSeq = page.lastSeq
            next.newCount = page.newCount
            next.logCount = page.logCount
            next.scopeCount = page.scopeCount
            next.isLoaded = true
        case .held(let held, _, let base):
            guard isHeld || isPaused, base == baseID else { return nil }
            next.appliedSeq = held.lastSeq
            next.newCount = held.newCount
        }
        return next
    }
}

public enum LogList {
    /// Rows read per page, as in the trace list.
    public static let pageSize = 200

    /// The next page below the rows shown, without rows shown already.
    public static func appending(_ page: [LogListItem], to rows: [LogListItem]) -> [LogListItem] {
        let shown = Set(rows.map(\.id))
        return rows + page.filter { !shown.contains($0.id) }
    }

    /// "12 new logs", "1 new log" (docs/GLOSSARY.md).
    public static func newLogsTitle(_ count: Int) -> String {
        count == 1 ? "1 new log" : "\(count.formatted()) new logs"
    }

    /// The window's subtitle in the Logs view: "8,310 logs", "1 log",
    /// prefixed "Paused · " while paused (docs/ux.md, Window).
    public static func subtitle(logCount: Int, isPaused: Bool = false) -> String {
        (isPaused ? "Paused · " : "") + TraceLogs.countTitle(logCount)
    }

    /// The pause bar over the Logs list: "Paused. 12 new logs. Magnife is still receiving."
    public static func pausedText(newCount: Int) -> String {
        let count = newCount == 0 ? "" : " \(newLogsTitle(newCount))."
        return "Paused.\(count) Magnife is still receiving."
    }

    /// The window's subtitle while the filter bar hides some of the scope's
    /// logs: "312 of 1,204 logs" (docs/ux.md, Window).
    public static func subtitle(shown: Int, of total: Int, isPaused: Bool = false) -> String {
        guard shown != total else { return subtitle(logCount: total, isPaused: isPaused) }
        return (isPaused ? "Paused · " : "") + "\(shown.formatted()) of \(TraceLogs.countTitle(total))"
    }

    public static let noMatchesTitle = "No Matching Logs"
    public static let noMatchesDescription = "No logs match these filters."

    public static let emptyTitle = "No Logs Yet"
    public static let emptyDescription = "Logs your apps send over OTLP appear here."
    public static let noSelectionTitle = "No Log Selected"
    public static let noSelectionDescription = "Select a log to see its attributes."
    /// The arrow's tooltip, and Open Trace's while it cannot open the trace.
    public static let openTraceHelp = "Open this log's trace (⌘O)"
    public static let noSpansHelp = "Magnife has no spans for this trace"

    /// The empty state of a service scope: "No Logs from orders".
    public static func emptyTitle(service: String) -> String { "No Logs from \(service)" }
    public static func emptyDescription(service: String) -> String { "Logs from \(service) appear here." }
}

/// The Log Detail (S-013): the selected log with the resource it came from,
/// sections in order Body, Attributes, Resource, Trace; a section with
/// nothing in it is left out. Built off the main actor.
public struct LogDetail: Sendable, Hashable {
    public let item: LogListItem
    /// The resource's attributes, `service.*` first, then by key.
    public let resourceAttributes: [Attribute]
    public let sections: [Section]

    public init(item: LogListItem, resource: ResourceRecord?) {
        self.item = item
        resourceAttributes = SpanDetail.ordered(resource?.attributes.pairs ?? [], first: SpanDetail.resourcePrefixes)
        var sections: [Section] = [.body]
        if !item.line.attributes.isEmpty { sections.append(.attributes) }
        if !resourceAttributes.isEmpty { sections.append(.resource) }
        if item.hasTrace { sections.append(.trace) }
        self.sections = sections
    }

    public var line: LogLine { item.line }

    public enum Section: String, Sendable, CaseIterable, Identifiable {
        case body = "Body"
        case attributes = "Attributes"
        case resource = "Resource"
        case trace = "Trace"

        public var id: String { rawValue }
        public var title: String { rawValue }
    }
}
