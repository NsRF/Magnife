import Foundation
import MagnifeKit

/// The live trace list (S-004): the first page at the top, older pages as you
/// scroll, and a list that holds still while you are scrolled away from the
/// top, with a count of the traces that arrived meanwhile (design decision 6).
extension AppModel {
    /// The "12 new traces" button shows while the list holds and traces wait.
    var showsNewTracesButton: Bool { isListHeld && newTraceCount > 0 }

    /// At the top: the newest page replaces the rows. Held: only the rows
    /// shown are updated in place, and new traces are counted.
    func reloadList(_ reader: TelemetryReader) async throws {
        let service = sidebar?.serviceName
        if isListHeld && !traces.isEmpty {
            let base = listBaseSeq
            let applied = listAppliedSeq
            let held = try await reader.heldTraces(base: base, applied: applied, shown: traces.map(\.id), service: service)
            // A scope change, a return to the top, or a newer page while reading reads again itself;
            // an older read that finishes last never puts older rows back.
            guard service == sidebar?.serviceName, reader === self.reader, isListHeld, listBaseSeq == base,
                  held.lastSeq >= listAppliedSeq else { return }
            services = held.services
            let rows = TraceList.applying(held.updated, to: traces)
            if rows != traces { traces = rows }
            listAppliedSeq = held.lastSeq
            if newTraceCount != held.newCount { newTraceCount = held.newCount }
        } else {
            let page = try await reader.tracePage(service: service)
            // Scrolled away while reading: inserting now would move the rows under the pointer.
            // Two reads can overlap (a batch and a return to the top): the older never wins.
            guard service == sidebar?.serviceName, reader === self.reader, !isListHeld || traces.isEmpty,
                  page.lastSeq >= listAppliedSeq else { return }
            services = page.services
            // Equal results leave the table alone.
            if traces != page.traces { traces = page.traces }
            hasMoreTraces = page.traces.count == TraceList.pageSize
            listBaseSeq = page.lastSeq
            listAppliedSeq = page.lastSeq
            if newTraceCount != 0 { newTraceCount = 0 }
            isLoadingScope = false
        }
    }

    /// The table's last row appeared: read the next page below it. Only
    /// while scrolled down: AppKit can prepare rows outside the view, and at
    /// the top the first page is all the list needs.
    func loadMoreTraces() {
        guard hasMoreTraces, isListHeld, !isLoadingMore, let reader, let last = traces.last else { return }
        isLoadingMore = true
        let service = sidebar?.serviceName
        Task {
            defer { isLoadingMore = false }
            let page = (try? await reader.latestTraces(limit: TraceList.pageSize, after: last.cursor, service: service)) ?? []
            guard service == sidebar?.serviceName, reader === self.reader, traces.last?.id == last.id else { return }
            traces = TraceList.appending(page, to: traces)
            hasMoreTraces = page.count == TraceList.pageSize
        }
    }

    /// The scroller saw the list leave or reach the top. Back at the top,
    /// the waiting traces are inserted.
    func listScrolled(awayFromTop away: Bool) {
        guard away != isListHeld else { return }
        isListHeld = away
        MenuState.shared.update(newTraceCount: 0)
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
