import Foundation
import MagnifeKit

/// The open trace's waterfall (S-005). Spans are read and the tree is built
/// off the main actor; the main actor only swaps the finished tree in.
extension AppModel {
    /// A new selection in the trace list: read its spans, build the tree,
    /// collapse deep subtrees above 500 spans, select the root span.
    func openSelectedTrace() {
        waterfallTask?.cancel()
        waterfall = Waterfall()
        waterfallGeneration += 1
        MenuState.shared.update(hasWaterfall: false)
        collapsedSpans = []
        selectedSpanID = nil
        guard let id = selectedTraceID, let reader else {
            openTrace = nil
            return
        }
        openTrace = traces.first { $0.id == id }
        waterfallRequestedAt = .now
        lastWaterfallOpen = nil
        waterfallTask = Task { [weak self] in
            guard let (trace, tree) = try? await Self.readWaterfall(reader, traceID: id) else { return }
            guard let self, !Task.isCancelled, self.selectedTraceID == id else { return }
            self.show(tree, of: trace, opening: true)
        }
    }

    /// After a batch: rebuild the waterfall when the open trace changed, so
    /// late spans join under their parent. Collapsed spans and the
    /// selection stay as they were.
    func refreshOpenTrace(_ reader: TelemetryReader) async throws {
        // While a trace opens, its own read is the fresh one.
        guard let id = selectedTraceID, !waterfall.isEmpty else { return }
        guard let trace = try await reader.trace(id: id) else { return }
        guard selectedTraceID == id else { return }
        guard trace.updatedSeq != openTrace?.updatedSeq || trace.spanCount != waterfall.count else {
            if openTrace != trace { openTrace = trace }
            return
        }
        let (fresh, tree) = try await Self.readWaterfall(reader, traceID: id)
        guard selectedTraceID == id else { return }
        show(tree, of: fresh ?? trace, opening: false)
    }

    private func show(_ tree: Waterfall, of trace: TraceSummary?, opening: Bool) {
        if let trace { openTrace = trace }
        if opening {
            collapsedSpans = tree.defaultCollapsed()
            selectedSpanID = tree.rootSpanID
        } else {
            // Spans that stopped having children cannot stay collapsed.
            collapsedSpans = collapsedSpans.intersection(tree.parentSpanIDs)
            if selectedSpanID.flatMap(tree.index(of:)) == nil { selectedSpanID = tree.rootSpanID }
        }
        waterfall = tree
        waterfallGeneration += 1
        MenuState.shared.update(hasWaterfall: !tree.isEmpty)
    }

    @concurrent
    nonisolated private static func readWaterfall(_ reader: TelemetryReader,
                                                  traceID: String) async throws -> (TraceSummary?, Waterfall) {
        let trace = try await reader.trace(id: traceID)
        let spans = try await reader.waterfallSpans(traceID: traceID)
        return (trace, await Waterfall.build(spans))
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
