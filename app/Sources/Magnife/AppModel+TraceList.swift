import Foundation
import MagnifeKit

/// The live trace list (S-004): the first page at the top, older pages as you
/// scroll, and a list that holds still while you are scrolled away from the
/// top, with a count of the traces that arrived meanwhile (design decision 6).
extension AppModel {
    /// The "12 new traces" button shows while the list holds and traces wait;
    /// while paused the pause bar counts them instead (S-010).
    var showsNewTracesButton: Bool { isListHeld && !isPaused && newTraceCount > 0 }

    /// At the top: the newest page replaces the rows. Held: only the rows
    /// shown are updated in place, and new traces are counted. What a read
    /// may change is `TraceListState.applying`'s to decide.
    /// Until Resume has revealed the selection, every page read asks for
    /// `resumeRows`, so the selected trace stays in the list (S-010).
    func reloadList(_ reader: TelemetryReader) async throws {
        let limit = resumeRows ?? TraceList.pageSize
        let state = listState
        let read: TraceListRead
        if state.readsHeld {
            // Paused, no shown row may change, so none is read.
            read = .held(try await reader.heldTraces(base: state.baseSeq, applied: state.appliedSeq,
                                                     shown: state.isPaused ? [] : state.traces.map(\.id),
                                                     filter: state.scope),
                         scope: state.scope, base: state.baseSeq)
        } else {
            read = .page(try await reader.tracePage(limit: limit, filter: state.scope, upTo: state.pausedSeq),
                         scope: state.scope)
        }
        // The state may have moved on while reading (a scope change, scrolling, another read).
        guard reader === self.reader, let next = listState.applying(read) else { return }
        services = read.services
        show(next)
        if case .page = read { isLoadingScope = false }
    }

    /// The list's rows and seqs as one value, for `TraceListState.applying`.
    var listState: TraceListState {
        TraceListState(scope: traceFilter.normalized, traces: traces, baseSeq: listBaseSeq, appliedSeq: listAppliedSeq,
                       isHeld: isListHeld, newCount: newTraceCount, hasMore: hasMoreTraces,
                       traceCount: listTraceCount, scopeCount: listScopeCount, pausedSeq: pausedSeq)
    }

    /// Takes a new list state, setting only what changed, so equal rows leave the table alone.
    private func show(_ state: TraceListState) {
        if traces != state.traces { traces = state.traces }
        listBaseSeq = state.baseSeq
        listAppliedSeq = state.appliedSeq
        if newTraceCount != state.newCount { newTraceCount = state.newCount }
        if hasMoreTraces != state.hasMore { hasMoreTraces = state.hasMore }
        if listTraceCount != state.traceCount { listTraceCount = state.traceCount }
        if listScopeCount != state.scopeCount { listScopeCount = state.scopeCount }
    }

    /// A new scope or filter starts from an empty list. Diffing one scope's
    /// rows into another's makes AppKit re-enter its row height cache
    /// ("reentrant operation in its NSTableView delegate").
    func resetTraceList() {
        traces = []
        isListHeld = false
        newTraceCount = 0
        hasMoreTraces = false
        listTraceCount = 0
        listScopeCount = 0
        isLoadingScope = true
    }

    /// The table's last row appeared: read the next page below it. Only
    /// while scrolled down: AppKit can prepare rows outside the view, and at
    /// the top the first page is all the list needs.
    func loadMoreTraces() {
        guard hasMoreTraces, isListHeld, !isLoadingMore, let reader, let last = traces.last else { return }
        isLoadingMore = true
        let filter = traceFilter.normalized
        let upTo = pausedSeq
        Task {
            defer { isLoadingMore = false }
            let page = (try? await reader.latestTraces(limit: TraceList.pageSize, after: last.cursor, filter: filter,
                                                       upTo: upTo)) ?? []
            guard filter == traceFilter.normalized, upTo == pausedSeq, reader === self.reader,
                  traces.last?.id == last.id else { return }
            traces = TraceList.appending(page, to: traces)
            hasMoreTraces = page.count == TraceList.pageSize
        }
    }

    /// The scroller saw the list leave or reach the top. Back at the top,
    /// the waiting traces are inserted.
    func listScrolled(awayFromTop away: Bool) {
        guard away != isListHeld else { return }
        isListHeld = away
        updateNewRowsMenu()
        if !away { refreshNow() }
    }

    /// The "12 new traces" button and Trace > Show Newest Traces.
    func showNewestTraces() {
        listScroller.scrollToTop()
        listScrolled(awayFromTop: false)
    }

    /// Snapshot pages show the button without scrolling: the seed set's five traces fit the window.
    func holdListForSnapshot(newTraces: Int) {
        isListHeld = newTraces > 0
        newTraceCount = newTraces
    }
}
