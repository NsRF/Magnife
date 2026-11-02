import AppKit
import MagnifeKit

/// The span detail's two tabs (docs/ux.md, Window): Span (S-006, S-007,
/// S-011) and Trace Logs (S-012). View > Span ⌥⌘1, View > Trace Logs ⌥⌘2.
enum SpanDetailTab: String, CaseIterable, Identifiable {
    case span
    case traceLogs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .span: "Span"
        case .traceLogs: "Trace Logs"
        }
    }

    static let defaultsKey = "detail.spanDetailTab"

    /// The last tab picked; test and snapshot runs start on Span.
    static var stored: SpanDetailTab {
        guard !StoreLocation.isOverridden() else { return .span }
        return SpanDetailTab(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .span
    }
}

/// Trace Logs (S-012): every log of the open trace, read off the main actor
/// when the trace opens and whenever a log joins it. Selecting a log selects
/// its span in the waterfall, opening its collapsed parents.
extension AppModel {
    /// Reads the open trace's logs. The rows on screen stay until the new
    /// read arrives, unless another trace opened.
    func loadTraceLogs() {
        traceLogsTask?.cancel()
        guard let traceID = selectedTraceID, let reader else {
            traceLogs = TraceLogs()
            selectedTraceLogID = nil
            return
        }
        if traceLogs.traceID != traceID {
            traceLogs = TraceLogs()
            selectedTraceLogID = nil
        }
        traceLogsTask = Task { [weak self] in
            guard let logs = try? await reader.traceLogs(traceID: traceID) else { return }
            guard let self, !Task.isCancelled, self.selectedTraceID == traceID else { return }
            if logs != self.traceLogs { self.traceLogs = logs }
            if let id = self.selectedTraceLogID, !logs.lines.contains(where: { $0.id == id }) {
                self.selectedTraceLogID = nil
            }
        }
    }

    /// What the Span column shows for a log, from the open waterfall.
    func traceLogSpan(_ log: LogLine) -> TraceLogSpan {
        TraceLogSpan(spanID: log.record.spanID, in: waterfall)
    }

    var selectedTraceLog: LogLine? {
        guard let id = selectedTraceLogID else { return nil }
        return traceLogs.lines.first { $0.id == id }
    }

    /// A click or arrow key on a Trace Logs row: its span is selected and
    /// scrolled into view, collapsed parents open. A log with no span id,
    /// or one this trace has not received, leaves the waterfall alone.
    func selectTraceLog(_ id: LogLine.ID?) {
        if selectedTraceLogID != id { selectedTraceLogID = id }
        guard let log = selectedTraceLog, let spanID = traceLogSpan(log).spanID else { return }
        let closed = collapsedSpans.intersection(waterfall.ancestors(of: spanID))
        if !closed.isEmpty { collapsedSpans.subtract(closed) }
        if selectedSpanID != spanID { selectedSpanID = spanID }
    }

    /// Return on a Trace Logs row: select its span, then move focus to the waterfall.
    func openTraceLogSpan(_ id: LogLine.ID?) {
        selectTraceLog(id)
        guard let log = selectedTraceLog, traceLogSpan(log).spanID != nil, let outline = waterfallOutline else { return }
        // After the outline has applied the new selection.
        Task { @MainActor in outline.window?.makeFirstResponder(outline) }
    }

    /// View > Span (⌥⌘1) and View > Trace Logs (⌥⌘2), and the picker. Picking
    /// a tab shows the span detail if it was hidden.
    func showSpanDetailTab(_ tab: SpanDetailTab) {
        if spanDetailTab != tab { spanDetailTab = tab }
        if !showsSpanDetail { showsSpanDetail = true }
    }

    /// Edit > Copy Body and ⌘C in Trace Logs: the selected log's body as stored.
    func copySelectedLogBody(to pasteboard: NSPasteboard = .general) {
        guard let log = selectedTraceLog else { return }
        copyBody(log.record.body, to: pasteboard)
    }

    /// The Trace Logs row's Copy Trace ID.
    func copyTraceID(_ traceID: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(traceID, forType: .string)
    }
}
