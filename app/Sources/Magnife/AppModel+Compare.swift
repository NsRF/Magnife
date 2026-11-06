import AppKit
import MagnifeKit
import SwiftUI

/// The Compare Traces window's state (S-036). Its own observable object, so
/// a flood that redraws the main window never touches the comparison, and
/// the comparison's changes never redraw the main window (S-030).
@MainActor
@Observable
final class CompareModel {
    struct Pair: Equatable, Sendable {
        var a: String
        var b: String
    }

    /// The two traces, A the baseline; nil before the first comparison.
    var pair: Pair?
    var comparison: TraceComparison?
    /// Bumped with each new comparison: the outline rebuilds on it.
    var generation = 0
    var isLoading = false
    /// Collapsed rows, by row id (stable across live re-reads).
    var collapsed: Set<Int> = []
    var selectedRow: Int?
    /// View > Show Only Differences (⇧⌘D), on at first.
    var showsOnlyDifferences = true
    var showsAllDifferences = false
    @ObservationIgnored var task: Task<Void, Never>?
    /// Each side's `updated_seq` when read: a live trace re-reads when it moves.
    @ObservationIgnored var stamp: (a: Int64?, b: Int64?) = (nil, nil)
    @ObservationIgnored var lastRead = ContinuousClock.now
    /// How long the last comparison took from the request to the built tree (self-test).
    @ObservationIgnored var lastBuild: Duration?
    @ObservationIgnored weak var outline: NSOutlineView?

    var hasComparison: Bool { comparison != nil }

    /// The rows on screen, in order (self-test).
    var visibleRows: [Int] { comparison?.visibleRows(collapsed: collapsed) ?? [] }
}

/// Opening, swapping and refreshing a comparison (S-036, docs/ux.md).
extension AppModel {
    /// Compare with Selected Trace (a trace row's context menu): the
    /// selected trace is A, the clicked one B.
    func compareWithSelectedTrace(_ clickedID: String) {
        guard let selected = selectedTraceID, selected != clickedID else { return NSSound.beep() }
        compare(a: selected, b: clickedID)
    }

    /// Whether a row's Compare with Selected Trace applies.
    func canCompareWithSelectedTrace(_ clickedID: String) -> Bool {
        selectedTraceID != nil && selectedTraceID != clickedID
    }

    /// Opens the Compare Traces window on A and B and reads them.
    func compare(a: String, b: String) {
        let pair = CompareModel.Pair(a: a, b: b)
        if compare.pair != pair {
            compare.pair = pair
            compare.comparison = nil
            compare.collapsed = []
            compare.selectedRow = nil
            compare.showsAllDifferences = false
        }
        CompareWindow.show()
        readComparison(rebuilding: true)
        MenuState.shared.update(hasComparison: true)
    }

    /// Trace > Swap Traces (⌥⌘K): A becomes B and B becomes A.
    func swapComparedTraces() {
        guard let pair = compare.pair else { return }
        compare(a: pair.b, b: pair.a)
    }

    /// View > Show Only Differences (⇧⌘D): collapses the subtrees with no
    /// difference, or opens the tree like a waterfall.
    func toggleOnlyDifferences() {
        compare.showsOnlyDifferences.toggle()
        MenuState.shared.update(showsOnlyDifferences: compare.showsOnlyDifferences)
        guard let comparison = compare.comparison else { return }
        compare.collapsed = comparison.defaultCollapsed(onlyDifferences: compare.showsOnlyDifferences)
        revealComparedRow()
    }

    /// Reads both traces and builds the comparison off the main actor. A new
    /// pair collapses as Show Only Differences says; a live re-read keeps
    /// the rows people opened and closed.
    func readComparison(rebuilding: Bool) {
        guard let pair = compare.pair, let reader else { return }
        compare.task?.cancel()
        compare.isLoading = true
        let started = ContinuousClock.now
        compare.task = Task { [weak self] in
            guard let read = try? await reader.comparison(traceA: pair.a, traceB: pair.b) else { return }
            let built = await TraceComparison.build(read)
            guard let self, !Task.isCancelled, self.compare.pair == pair else { return }
            self.showComparison(built, read: read, rebuilding: rebuilding)
            self.compare.lastBuild = started.duration(to: .now)
        }
    }

    private func showComparison(_ built: TraceComparison, read: ComparisonRead, rebuilding: Bool) {
        let previous = compare.comparison
        compare.isLoading = false
        compare.stamp = (read.traceA?.updatedSeq, read.traceB?.updatedSeq)
        compare.lastRead = .now
        let fresh = built.defaultCollapsed(onlyDifferences: compare.showsOnlyDifferences)
        if rebuilding || previous == nil {
            compare.collapsed = fresh
        } else if let previous {
            // Rows people left as they were follow the new tree; new rows collapse as they would have.
            let known = Set(previous.rows.map(\.id))
            compare.collapsed = compare.collapsed.filter { built.row(id: $0) != nil }
                .union(fresh.filter { !known.contains($0) })
        }
        compare.comparison = built
        compare.generation += 1
        if compare.selectedRow.flatMap(built.index(ofRow:)) == nil {
            compare.selectedRow = built.roots.first.map { built.rows[$0].id }
        }
    }

    /// After a batch, not paused (S-010): re-read when either trace moved, at
    /// most every 500 ms, like a growing waterfall.
    func refreshComparison(_ reader: TelemetryReader) async throws {
        guard let pair = compare.pair, compare.comparison != nil, !compare.isLoading,
              compare.lastRead.duration(to: .now) >= .milliseconds(500) else { return }
        let a = try await reader.trace(id: pair.a)?.updatedSeq
        let b = try await reader.trace(id: pair.b)?.updatedSeq
        guard a != compare.stamp.a || b != compare.stamp.b else { return }
        readComparison(rebuilding: false)
    }

    /// A strip line: its row is selected, its collapsed parents open.
    func selectDifference(_ difference: TraceComparison.Difference) {
        guard let comparison = compare.comparison else { return }
        compare.collapsed.subtract(comparison.ancestors(of: difference.row))
        compare.selectedRow = comparison.rows[difference.row].id
        revealComparedRow()
    }

    /// Scrolls the selected row into view once the outline shows it.
    func revealComparedRow() {
        Task { @MainActor [weak self] in
            guard let outline = self?.compare.outline, outline.selectedRow >= 0 else { return }
            outline.scrollRowToVisible(outline.selectedRow)
        }
    }

    /// Open Span in A / Open Span in B, Return or a double-click: the span
    /// in the main window's waterfall, its trace open, its parents expanded.
    func openComparedSpan(row index: Int, inA: Bool) {
        guard let comparison = compare.comparison, let pair = compare.pair,
              let spanID = comparison.spanID(of: index, inA: inA) else { return NSSound.beep() }
        openTrace(inA ? pair.a : pair.b, span: spanID)
    }

    /// Return or a double-click: B's span, or A's for a Missing row.
    func openComparedSpan(row index: Int) {
        guard let row = compare.comparison?.rows[safe: index] else { return }
        openComparedSpan(row: index, inA: row.b.isEmpty)
    }

    /// Open Trace in the header: the trace in the main window.
    func openComparedTrace(inA: Bool) {
        guard let pair = compare.pair else { return }
        openTrace(inA ? pair.a : pair.b, span: nil)
    }

    private func openTrace(_ traceID: String, span spanID: String?) {
        MainWindow.bringForward()
        showContentMode(.traces)
        if selectedTraceID == traceID, !waterfall.isEmpty {
            selectSpanOpeningParents(spanID ?? waterfall.rootSpanID)
        } else {
            pendingSpan = (traceID, spanID)
            selectedTraceID = traceID
        }
        Task { await revealSelectedTrace() }
    }

    /// Copy Span ID on a compared row: B's, else A's.
    func copyComparedSpanID(row index: Int, to pasteboard: NSPasteboard = .general) {
        guard let comparison = compare.comparison,
              let id = comparison.spanID(of: index, inA: false) ?? comparison.spanID(of: index, inA: true) else { return }
        pasteboard.clearContents()
        pasteboard.setString(id, forType: .string)
    }

    // MARK: Compare With… (Search in compare mode)

    /// Trace > Compare With… (⇧⌘K), the waterfall header's button and a
    /// row's Compare With…: Search opens to pick B for `traceID` (A),
    /// listing the newest traces of its route first.
    func showCompareSearch(for traceID: String? = nil) {
        guard let id = traceID ?? selectedTraceID, let reader else { return NSSound.beep() }
        let known = traces.first { $0.id == id } ?? (openTrace?.id == id ? openTrace : nil)
        closeSearch()
        searchCompareBase = known
        searchSameRoute = []
        Task { [weak self] in
            var found = known
            if found == nil { found = try? await reader.trace(id: id) }
            guard let self, let base = found else { return }
            self.searchCompareBase = base
            if !self.showsSearch {
                MainWindow.bringForward()
                self.showSearch()
            }
            let same = (try? await reader.sameRoute(as: base, limit: 10)) ?? []
            guard self.searchCompareBase?.id == base.id else { return }
            self.searchSameRoute = same
        }
    }

    /// The chip before Search's field in compare mode: "Compare with GET /account/orders · 64 ms".
    var searchCompareTitle: String? {
        searchCompareBase.map { "Compare with \($0.route) · \(DurationFormat.string(nanoseconds: $0.durationNs))" }
    }

    /// Return on a trace, or a click, in compare mode: compares A with it.
    func compareFromSearch(_ traceID: String) {
        guard let base = searchCompareBase else { return }
        closeSearch()
        guard base.traceID != traceID else { return NSSound.beep() }
        compare(a: base.traceID, b: traceID)
    }
}

/// The Compare Traces window (a `Window` scene, id "compare").
@MainActor
enum CompareWindow {
    static let id = "compare"

    static var window: NSWindow? {
        NSApp.windows.first { ($0.identifier?.rawValue.hasPrefix(id) ?? false) && ($0.isVisible || $0.isMiniaturized) }
    }

    static func show() {
        NSApp.activate()
        if let window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            MainWindow.openAction?(id: id)
        }
    }

    static func close() { window?.close() }
}
