import AppKit
import MagnifeKit

/// How a long value lays out in the span detail: its full height and the
/// height it shows. Taller than shown means it is cut, and "Show All" shows.
struct ValueLayout: Equatable {
    var full: CGFloat
    var shown: CGFloat
    var isTruncated: Bool { full > shown + 1 }
}

/// The span detail (S-006): the selected span and its resource, read off
/// the main actor whenever the selection changes or the open trace is rebuilt.
extension AppModel {
    /// Reads the selected span. The previous span stays on screen until the
    /// new one arrives, so switching spans never flashes an empty pane.
    func loadSpanDetail() {
        spanDetailTask?.cancel()
        guard let traceID = selectedTraceID, let spanID = selectedSpanID, let reader else {
            spanDetail = nil
            return
        }
        if spanDetail?.span.traceID != traceID { spanDetail = nil }
        spanDetailTask = Task { [weak self] in
            guard let detail = try? await reader.spanDetail(traceID: traceID, spanID: spanID) else { return }
            guard let self, !Task.isCancelled, self.selectedTraceID == traceID, self.selectedSpanID == spanID else { return }
            self.spanDetail = detail
        }
    }

    /// Another span starts with every value collapsed again.
    func spanDetailChanged(from old: SpanDetail?) {
        MenuState.shared.update(hasStackTrace: spanDetail?.firstStackTrace != nil)
        guard old?.span.spanID != spanDetail?.span.spanID || old?.span.traceID != spanDetail?.span.traceID else { return }
        expandedValues = []
        valueLayouts = [:]
        stackTraceCopiedTask?.cancel()
        copiedStackTrace = nil
    }

    /// After a batch (not paused): when a log joined the open trace, read
    /// the selected span again, so its Logs section takes it in time order (S-011).
    func refreshOpenTraceLogs(_ reader: TelemetryReader) async throws {
        guard let traceID = selectedTraceID, selectedSpanID != nil else { return }
        let stamp = try await reader.logStamp(traceID: traceID)
        guard selectedTraceID == traceID, stamp != openTraceLogStamp else { return }
        openTraceLogStamp = stamp
        // Also on the trace's first stamp: a log may have joined since the
        // detail was read. An unchanged detail changes nothing on screen.
        loadSpanDetail()
    }

    /// True when the pane has nothing to show: a waterfall with no selected span.
    var showsNoSpanSelected: Bool {
        spanDetail == nil && selectedSpanID == nil && hasOpenWaterfall
    }

    func toggleExpanded(_ id: String) {
        if expandedValues.contains(id) { expandedValues.remove(id) } else { expandedValues.insert(id) }
    }

    /// View > Show Span Detail / Hide Span Detail (⌃⌘I).
    func toggleSpanDetail() {
        showsSpanDetail.toggle()
    }

    /// Edit > Copy Span ID and the waterfall row's context menu.
    func copySpanID(_ spanID: String? = nil, to pasteboard: NSPasteboard = .general) {
        guard let id = spanID ?? selectedSpanID else { return }
        pasteboard.clearContents()
        pasteboard.setString(id, forType: .string)
    }
}

extension AppModel {
    /// Copy Stack Trace (S-007): the whole stack trace of the selected span's
    /// exception at `index`, even while it shows only its first lines. The
    /// button reads "Copied" for 2 seconds and VoiceOver hears it. Edit >
    /// Copy Stack Trace passes no index: the first exception with one.
    func copyStackTrace(at index: Int? = nil, to pasteboard: NSPasteboard = .general) {
        guard let exceptions = spanDetail?.exceptions else { return }
        guard let index = index ?? exceptions.firstIndex(where: \.hasStackTrace), exceptions.indices.contains(index),
              exceptions[index].hasStackTrace else { return }
        pasteboard.clearContents()
        pasteboard.setString(exceptions[index].stackTrace, forType: .string)
        copiedStackTrace = index
        NSAccessibility.post(element: NSApp.mainWindow ?? NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: "Copied",
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
        stackTraceCopiedTask?.cancel()
        stackTraceCopiedTask = Task { [weak self] in
            try? await Task.sleep(for: Self.copiedFeedback)
            guard !Task.isCancelled else { return }
            self?.copiedStackTrace = nil
        }
    }
}

/// Ids for the span detail's expandable values, unique within one span.
enum SpanDetailValueID {
    /// The span itself: the detail's scroll view starts over for each.
    static func span(_ detail: SpanDetail) -> String { "\(detail.span.traceID)/\(detail.span.spanID)" }
    static func attribute(_ key: String) -> String { "attribute:\(key)" }
    static func event(_ index: Int, _ key: String) -> String { "event:\(index):\(key)" }
    static func resource(_ key: String) -> String { "resource:\(key)" }
    static let statusMessage = "status-message"
    static func exceptionMessage(_ index: Int) -> String { "exception:\(index):message" }
    static func exceptionAttribute(_ index: Int, _ key: String) -> String { "exception:\(index):\(key)" }
    static func stackTrace(_ index: Int) -> String { "stack-trace:\(index)" }
    /// The Logs section's "Show All (312)".
    static let allLogs = "logs:all"
    static func logBody(_ id: Int64) -> String { "log:\(id):body" }
    static func logAttributes(_ id: Int64) -> String { "log:\(id):attributes" }
    static func logAttribute(_ id: Int64, _ key: String) -> String { "log:\(id):attribute:\(key)" }
}
