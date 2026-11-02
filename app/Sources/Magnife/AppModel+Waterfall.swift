import Foundation
import MagnifeKit

/// The open trace's waterfall (S-005). Spans are read and the tree is built
/// off the main actor; the main actor only swaps the finished tree in.
extension AppModel {
    /// A new selection in the trace list: read its spans, build the tree,
    /// collapse deep subtrees above 500 spans, select the root span.
    func openSelectedTrace() {
        waterfallTask?.cancel()
        isOpeningTrace = false
        waterfall = Waterfall()
        openTraceFindings = TraceFindings()
        showsAllFindings = false
        waterfallGeneration += 1
        MenuState.shared.update(hasWaterfall: false)
        collapsedSpans = []
        selectedSpanID = nil
        openTraceLogStamp = nil
        prunedTraceID = nil
        loadTraceLogs()
        guard let id = selectedTraceID, let reader else {
            openTrace = nil
            return
        }
        openTrace = traces.first { $0.id == id }
        waterfallRequestedAt = .now
        lastWaterfallOpen = nil
        startOpening(id, reader: reader)
    }

    /// Reads the trace that opens. A failed read (a busy or failing disk)
    /// leaves the waterfall empty, and the next batch's refresh tries again.
    private func startOpening(_ id: String, reader: TelemetryReader) {
        isOpeningTrace = true
        waterfallTask = Task { [weak self] in
            let result = try? await Self.readWaterfall(reader, traceID: id, after: nil)
            guard let self, !Task.isCancelled, self.selectedTraceID == id else { return }
            self.isOpeningTrace = false
            guard let result else { return }
            // A paused list can still show a trace that retention deleted (S-015).
            guard result.trace != nil || !result.tree.isEmpty else { return self.traceNoLongerStored(id) }
            self.show(result.tree, of: result.trace, findings: result.findings, collapsing: result.collapsed,
                      opening: true)
        }
    }

    /// After a batch: rebuild the waterfall when the open trace changed, so
    /// late spans join under their parent. Collapsed spans and the
    /// selection stay as they were; spans that became parents collapse as
    /// they would have if the trace had opened that big.
    func refreshOpenTrace(_ reader: TelemetryReader) async throws {
        guard let id = selectedTraceID, prunedTraceID != id else { return }
        guard !waterfall.isEmpty else {
            // While a trace opens, its own read is the fresh one; after a failed one, read again.
            if !isOpeningTrace { startOpening(id, reader: reader) }
            return
        }
        guard let trace = try await reader.trace(id: id) else {
            // Retention deleted it while it was open (S-015).
            if selectedTraceID == id { traceNoLongerStored(id) }
            return
        }
        guard selectedTraceID == id else { return }
        guard trace.updatedSeq != openTrace?.updatedSeq || trace.spanCount != waterfall.count else {
            if openTrace != trace { openTrace = trace }
            return
        }
        let previous = waterfall
        let result = try await Self.readWaterfall(reader, traceID: id, after: previous)
        // Two refreshes can overlap: the older read never replaces a newer tree.
        guard selectedTraceID == id, (result.trace?.updatedSeq ?? .max) >= (openTrace?.updatedSeq ?? 0) else { return }
        show(result.tree, of: result.trace ?? trace, findings: result.findings, collapsing: result.collapsed,
             opening: false)
    }

    /// `collapsing`: the spans `Waterfall.autoCollapsed` closes, worked out off the main actor.
    private func show(_ tree: Waterfall, of trace: TraceSummary?, findings: TraceFindings, collapsing added: Set<String>,
                      opening: Bool) {
        if let trace { openTrace = trace }
        if opening {
            collapsedSpans = added
            selectedSpanID = tree.rootSpanID
        } else {
            collapsedSpans = tree.collapsed(keeping: collapsedSpans, adding: added)
            if selectedSpanID.flatMap(tree.index(of:)) == nil { selectedSpanID = tree.rootSpanID }
            // A resent span replaces the stored row: read the selected one again.
            loadSpanDetail()
        }
        waterfall = tree
        // With the tree, so the outline draws the rows' icons in the same reload.
        if openTraceFindings != findings { openTraceFindings = findings }
        waterfallGeneration += 1
        MenuState.shared.update(hasWaterfall: !tree.isEmpty)
        // Open Trace from a log (S-013): its span, with its parents open.
        if opening, let pending = pendingSpan, pending.traceID == selectedTraceID {
            pendingSpan = nil
            selectSpanOpeningParents(pending.spanID)
        }
        // A Recent Errors item (S-027): its earliest Error span.
        // Another trace opening first drops it.
        if opening, let pending = pendingFailedTrace {
            pendingFailedTrace = nil
            if pending == selectedTraceID { showFirstErrorSpan() }
        }
    }

    /// The trace's row, its tree, its findings and the spans to collapse in it, off the main actor.
    @concurrent
    nonisolated private static func readWaterfall(_ reader: TelemetryReader, traceID: String, after previous: Waterfall?)
        async throws -> (trace: TraceSummary?, tree: Waterfall, findings: TraceFindings, collapsed: Set<String>) {
        let trace = try await reader.trace(id: traceID)
        let spans = try await reader.waterfallSpans(traceID: traceID)
        let findings = try await reader.traceFindings(traceID: traceID)
        let tree = await Waterfall.build(spans)
        return (trace, tree, findings, tree.autoCollapsed(after: previous))
    }

    /// The outline shows `generation`: the self-test's open time ends here.
    func waterfallShown(generation: Int) {
        shownWaterfallGeneration = generation
        if generation == waterfallGeneration, !waterfall.isEmpty, let started = waterfallRequestedAt {
            lastWaterfallOpen = started.duration(to: .now)
            waterfallRequestedAt = nil
        }
    }

    var hasOpenWaterfall: Bool { !waterfall.isEmpty }

    /// The selected trace is gone (S-015): its waterfall, span detail and
    /// Trace Logs close, and the detail column says why. The selection stays,
    /// so the message stays until another trace is chosen.
    func traceNoLongerStored(_ id: String) {
        guard selectedTraceID == id else { return }
        waterfallTask?.cancel()
        isOpeningTrace = false
        prunedTraceID = id
        if pendingFailedTrace == id { pendingFailedTrace = nil }
        openTrace = nil
        waterfall = Waterfall()
        openTraceFindings = TraceFindings()
        waterfallGeneration += 1
        MenuState.shared.update(hasWaterfall: false)
        collapsedSpans = []
        selectedSpanID = nil
        traceLogsTask?.cancel()
        traceLogs = TraceLogs()
        selectedTraceLogID = nil
    }

    /// True while the detail column shows "Trace No Longer Stored".
    var showsTraceNoLongerStored: Bool { prunedTraceID != nil && prunedTraceID == selectedTraceID }

    /// Trace > Expand All Spans.
    func expandAllSpans() {
        collapsedSpans = []
    }

    /// Trace > Collapse All Spans: only the root rows stay; a hidden
    /// selection moves to its root.
    func collapseAllSpans() {
        collapsedSpans = waterfall.parentSpanIDs
        if let id = selectedSpanID, var index = waterfall.index(of: id) {
            while let parent = waterfall.nodes[index].parent { index = parent }
            selectedSpanID = waterfall.nodes[index].span.spanID
        }
    }
}
