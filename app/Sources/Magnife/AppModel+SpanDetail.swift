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
        guard old?.span.spanID != spanDetail?.span.spanID || old?.span.traceID != spanDetail?.span.traceID else { return }
        expandedValues = []
        valueLayouts = [:]
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

/// Ids for the span detail's expandable values, unique within one span.
enum SpanDetailValueID {
    static func attribute(_ key: String) -> String { "attribute:\(key)" }
    static func event(_ index: Int, _ key: String) -> String { "event:\(index):\(key)" }
    static func resource(_ key: String) -> String { "resource:\(key)" }
    static let statusMessage = "status-message"
}
