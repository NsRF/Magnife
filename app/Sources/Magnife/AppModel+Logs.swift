import AppKit
import MagnifeKit

/// What the content and detail columns show (docs/ux.md, Traces vs Logs).
enum ContentMode: String, CaseIterable, Identifiable {
    case traces
    case logs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .traces: "Traces"
        case .logs: "Logs"
        }
    }

    /// The segment's tooltip (docs/ux.md, Toolbar).
    var help: String {
        switch self {
        case .traces: "Show traces (⌘1)"
        case .logs: "Show logs (⌘2)"
        }
    }

    static let defaultsKey = "window.contentMode"

    /// The last view shown; test and snapshot runs start on Traces.
    static var stored: ContentMode {
        guard !StoreLocation.isOverridden() else { return .traces }
        return ContentMode(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .traces
    }
}

/// The Logs view (S-013): every log in the sidebar's scope, newest first,
/// live, holding still while scrolled away from the top and while paused,
/// as the trace list does. What a read may change is
/// `LogListState.applying`'s to decide (MagnifeKit, unit-tested).
extension AppModel {
    /// View > Traces (⌘1) and View > Logs (⌘2), and the toolbar's segments.
    func showContentMode(_ mode: ContentMode) {
        if contentMode != mode { contentMode = mode }
    }

    func contentModeChanged() {
        if !StoreLocation.isOverridden() { UserDefaults.standard.set(contentMode.rawValue, forKey: ContentMode.defaultsKey) }
        MenuState.shared.update(contentMode: contentMode)
        updateNewRowsMenu()
        updateLogMenu()
        // The list that shows now starts at its top.
        isListHeld = false
        isLogListHeld = false
        refreshNow()
    }

    var logFilter: LogFilter { LogFilter(service: sidebar?.serviceName) }

    /// The list's rows and ids as one value, for `LogListState.applying`.
    var logListState: LogListState {
        LogListState(filter: logFilter, items: logs, baseID: logBaseID, appliedSeq: logAppliedSeq,
                     isHeld: isLogListHeld, newCount: newLogCount, hasMore: hasMoreLogs, logCount: logCount,
                     pausedID: logPausedID, isLoaded: logsLoaded)
    }

    /// At the top: the newest page replaces the rows. Held or paused: the
    /// rows stay and the logs that arrived are counted. `limit` is larger
    /// after Resume, so the selected log stays in the list.
    func reloadLogs(_ reader: TelemetryReader, limit: Int = LogList.pageSize) async throws {
        let state = logListState
        let read: LogListRead
        if state.readsHeld {
            read = .held(try await reader.heldLogs(base: state.baseID, filter: state.filter),
                         filter: state.filter, base: state.baseID)
        } else {
            read = .page(try await reader.logPage(limit: limit, filter: state.filter, upTo: state.pausedID),
                         filter: state.filter)
        }
        guard reader === self.reader, let next = logListState.applying(read) else { return }
        show(next)
        // A trace's spans can arrive after its log: Open Trace turns on then.
        if case .page = read, let detail = logDetail, detail.item.hasTrace, !detail.item.hasStoredTrace {
            loadLogDetail()
        }
    }

    private func show(_ state: LogListState) {
        if logs != state.items { logs = state.items }
        logBaseID = state.baseID
        logAppliedSeq = state.appliedSeq
        if newLogCount != state.newCount { newLogCount = state.newCount }
        if hasMoreLogs != state.hasMore { hasMoreLogs = state.hasMore }
        if logCount != state.logCount { logCount = state.logCount }
        if logsLoaded != state.isLoaded { logsLoaded = state.isLoaded }
    }

    /// A new scope or store: the list starts empty and is read again.
    func resetLogList() {
        logs = []
        logBaseID = 0
        logAppliedSeq = 0
        isLogListHeld = false
        newLogCount = 0
        hasMoreLogs = false
        logCount = 0
        logsLoaded = false
        // Paused, a new scope still reads up to the pause point.
    }

    /// The last row appeared while scrolled down: read the next page below it.
    func loadMoreLogs() {
        guard hasMoreLogs, isLogListHeld, !isLoadingMoreLogs, let reader, let last = logs.last else { return }
        isLoadingMoreLogs = true
        let filter = logFilter
        let upTo = logPausedID
        Task {
            defer { isLoadingMoreLogs = false }
            let page = (try? await reader.logItems(after: last.record.cursor, filter: filter, upTo: upTo)) ?? []
            guard filter == logFilter, upTo == logPausedID, reader === self.reader, logs.last?.id == last.id else { return }
            logs = LogList.appending(page, to: logs)
            hasMoreLogs = page.count == LogList.pageSize
        }
    }

    /// The "12 new logs" button shows while the list holds and logs wait;
    /// while paused the pause bar counts them instead.
    var showsNewLogsButton: Bool { isLogListHeld && !isPaused && newLogCount > 0 }

    /// The scroller saw the Logs list leave or reach the top.
    func logListScrolled(awayFromTop away: Bool) {
        guard away != isLogListHeld else { return }
        isLogListHeld = away
        updateNewRowsMenu()
        if !away { refreshNow() }
    }

    /// The "12 new logs" button and Trace > Show Newest Logs.
    func showNewestLogs() {
        logScroller.scrollToTop()
        logListScrolled(awayFromTop: false)
    }

    /// Trace > Show Newest Traces, or Show Newest Logs in the Logs view.
    func showNewestRows() {
        contentMode == .logs ? showNewestLogs() : showNewestTraces()
    }

    /// The Trace menu's Show Newest item is enabled while its list's button shows.
    func updateNewRowsMenu() {
        let count = switch contentMode {
        case .traces: showsNewTracesButton ? newTraceCount : 0
        case .logs: showsNewLogsButton ? newLogCount : 0
        }
        MenuState.shared.update(newTraceCount: count)
    }

    // MARK: Pause

    /// Holds the Logs list with the trace list (S-010): at the id its rows
    /// were read at, or, never read, at the newest log stored now.
    func pauseLogs() {
        guard logPausedID == nil else { return }
        if logsLoaded {
            logPausedID = logListState.paused(latestID: 0).pausedID
        } else if let reader {
            // Until the read answers, a Logs list that opens reads normally.
            Task {
                guard let latest = try? await reader.lastLogID(), isPaused, logPausedID == nil,
                      reader === self.reader else { return }
                logPausedID = logListState.paused(latestID: latest).pausedID
            }
        }
    }

    /// Resume: the logs that arrived are inserted; the selected log stays in
    /// the list and is brought into view.
    func resumeLogs() async {
        let limit = max(LogList.pageSize, logs.count + newLogCount)
        logPausedID = nil
        isLogListHeld = false
        guard contentMode == .logs, let reader else { return }
        do {
            try await reloadLogs(reader, limit: limit)
        } catch {
            FileHandle.standardError.write(Data("magnife: read failed: \(error)\n".utf8))
        }
        let scroller = logScroller
        for _ in 0..<50 where scroller.rowCount != logs.count {
            try? await Task.sleep(for: .milliseconds(20))
        }
        if let id = selectedLogID, let row = logs.firstIndex(where: { $0.id == id }) {
            scroller.reveal(row: row)
        } else {
            scroller.scrollToTop()
        }
        logListScrolled(awayFromTop: scroller.isAwayFromTop)
    }

    // MARK: Selection and Open Trace

    var selectedLog: LogListItem? {
        guard let id = selectedLogID else { return nil }
        return logs.first { $0.id == id } ?? (logDetail?.item.id == id ? logDetail?.item : nil)
    }

    /// Reads the selected log with its resource. The previous log stays on
    /// screen until the new one arrives.
    func loadLogDetail() {
        logDetailTask?.cancel()
        updateLogMenu()
        // Another log starts with every value collapsed again.
        if expandedValues.contains(where: { $0.hasPrefix(LogDetailValueID.prefix) }) {
            expandedValues = expandedValues.filter { !$0.hasPrefix(LogDetailValueID.prefix) }
        }
        guard let id = selectedLogID, let reader else {
            logDetail = nil
            return
        }
        logDetailTask = Task { [weak self] in
            guard let detail = try? await reader.logDetail(id: id) else { return }
            guard let self, !Task.isCancelled, self.selectedLogID == id else { return }
            if detail != self.logDetail { self.logDetail = detail }
        }
    }

    /// Edit > Copy Body and Trace > Open Trace follow the selected log of the view that shows.
    func updateLogMenu() {
        switch contentMode {
        case .traces:
            MenuState.shared.update(hasSelectedLog: selectedTraceLogID != nil)
            MenuState.shared.update(canOpenTrace: false)
        case .logs:
            MenuState.shared.update(hasSelectedLog: selectedLogID != nil)
            MenuState.shared.update(canOpenTrace: selectedLog?.canOpenTrace == true || logDetail?.item.canOpenTrace == true)
        }
    }

    /// Open Trace (⌘O, Return, double-click, the row's arrow, the Log Detail's
    /// button): the Traces view with the log's trace open and its span
    /// selected, or the root span when it has none. A log whose trace has no
    /// stored spans opens nothing.
    func openTrace(ofLog id: LogListItem.ID?) {
        guard let id, let item = logs.first(where: { $0.id == id }) ?? (logDetail?.item.id == id ? logDetail?.item : nil),
              let traceID = item.record.traceID, item.hasTrace else { return }
        guard item.canOpenTrace else { return NSSound.beep() }
        let spanID = item.record.spanID
        showContentMode(.traces)
        if selectedTraceID == traceID, !waterfall.isEmpty {
            selectSpanOpeningParents(spanID ?? waterfall.rootSpanID)
        } else {
            pendingSpan = (traceID, spanID)
            selectedTraceID = traceID
        }
        Task { await revealSelectedTrace() }
    }

    /// Trace > Open Trace and ⌘O: the selected log's trace.
    func openSelectedLogTrace() {
        openTrace(ofLog: selectedLogID)
    }

    /// Selects a span of the open waterfall, opening its collapsed parents
    /// (S-012, S-013); a span the trace does not have leaves it alone.
    func selectSpanOpeningParents(_ spanID: String?) {
        guard let spanID, waterfall.index(of: spanID) != nil else { return }
        let closed = collapsedSpans.intersection(waterfall.ancestors(of: spanID))
        if !closed.isEmpty { collapsedSpans.subtract(closed) }
        if selectedSpanID != spanID { selectedSpanID = spanID }
    }

    /// Edit > Copy Body and ⌘C in the Logs view: the selected log's body as stored.
    func copySelectedListLogBody(to pasteboard: NSPasteboard = .general) {
        guard let log = selectedLog else { return }
        copyBody(log.record.body, to: pasteboard)
    }
}
