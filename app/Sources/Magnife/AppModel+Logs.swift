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
        updateTraceIDMenu()
        updateLogMenu()
        updateFilterMenu()
        // The list that shows now starts at its top.
        isListHeld = false
        isLogListHeld = false
        refreshNow()
    }

    var logFilter: LogFilter { LogFilter(service: scopeService, levels: logLevels, bodyContains: logBodyFilter) }

    /// The list's rows and ids as one value, for `LogListState.applying`.
    var logListState: LogListState {
        LogListState(filter: logFilter, items: logs, baseID: logBaseID, appliedSeq: logAppliedSeq,
                     isHeld: isLogListHeld, newCount: newLogCount, hasMore: hasMoreLogs, logCount: logCount,
                     scopeCount: logScopeCount, pausedID: logPausedID, isLoaded: logsLoaded)
    }

    /// At the top: the newest page replaces the rows. Held or paused: the
    /// rows stay and the logs that arrived are counted. Until Resume has
    /// revealed the selection, page reads ask for `resumeLogRows`.
    func reloadLogs(_ reader: TelemetryReader) async throws {
        let limit = resumeLogRows ?? LogList.pageSize
        let state = logListState
        let read: LogListRead
        if state.readsHeld {
            read = .held(try await reader.heldLogs(base: state.baseID, filter: state.filter,
                                                   shown: state.isPaused ? [] : state.items.map(\.id)),
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
        if logScopeCount != state.scopeCount { logScopeCount = state.scopeCount }
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
        logScopeCount = 0
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
        // The Logs list is read only while it shows: rows from an earlier
        // visit are stale, so pausing elsewhere starts from the newest log.
        if contentMode != .logs { resetLogList() }
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
        let selectedRow = selectedLogID.flatMap { id in logs.firstIndex { $0.id == id } }
        let limit = TraceList.resumeLimit(selectedRow: selectedRow, newCount: newLogCount, pageSize: LogList.pageSize)
        logPausedID = nil
        isLogListHeld = false
        guard contentMode == .logs, let reader else { return }
        resumeLogRows = limit
        defer { if resumeLogRows == limit { resumeLogRows = nil } }
        do {
            try await reloadLogs(reader)
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

/// The Logs filter bar (S-014): Service pop-up (the sidebar's setting),
/// level chips and "Body contains"; View > Show Filter Bar (⌘F) and Clear
/// Filters, which is undoable. Any change reads the list again from the top.
extension AppModel {
    /// A filter changed: the list starts empty (diffing one filter's rows into
    /// another's trips AppKit's reentrancy warning) and is read again.
    func logFilterChanged() {
        resetLogList()
        updateFilterMenu()
        refreshNow()
    }

    /// Typing waits a moment, so each key does not read the list again.
    func applyLogBodyText() {
        logBodyTask?.cancel()
        logBodyTask = Task { [weak self] in
            try? await Task.sleep(for: Self.bodyTypingDelay)
            guard let self, !Task.isCancelled else { return }
            self.logBodyFilter = self.logBodyText
        }
    }

    static let bodyTypingDelay: Duration = .milliseconds(250)

    /// A level chip: a click shows only that level, ⌘-click or Space adds or removes it.
    func clickLevelChip(_ level: SeverityLevel, adding: Bool) {
        let next = logFilter.clicking(level, adding: adding).levels
        if logLevels != next { logLevels = next }
    }

    /// The filter bar's own filters (levels, body) are on: the Filter button is filled.
    var hasLogBarFilters: Bool { !logLevels.isEmpty || !logBodyText.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Clear Filters has something to clear: a level, a body or a service.
    var hasLogFilters: Bool { hasLogBarFilters || scopeService != nil }

    /// View > Show Filter Bar (⌘F) and the Filter button. Shown from the
    /// menu, the "Body contains" field takes the focus.
    func toggleLogFilterBar(focusField: Bool = false) {
        guard contentMode == .logs else { return }
        showsLogFilterBar.toggle()
        if showsLogFilterBar && focusField { focusesLogFilterField = true }
    }

    /// Esc and the bar's close button: the bar hides, the filters stay on.
    func hideLogFilterBar() {
        if showsLogFilterBar { showsLogFilterBar = false }
    }

    /// Clear Filters: every level, any body, All Services, at once. Undo
    /// ("Undo Clear Filters") puts them back.
    func clearLogFilters(undoManager: UndoManager?) {
        let before = (levels: logLevels, body: logBodyText, scope: sidebar)
        guard hasLogFilters else { return }
        logBodyTask?.cancel()
        logLevels = []
        logBodyText = ""
        logBodyFilter = ""
        sidebar = .allTraces
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.restoreLogFilters(levels: before.levels, body: before.body, scope: before.scope, undoManager: undoManager)
            }
        }
        undoManager?.setActionName("Clear Filters")
    }

    private func restoreLogFilters(levels: Set<SeverityLevel>, body: String, scope: SidebarSelection?, undoManager: UndoManager?) {
        logBodyTask?.cancel()
        logLevels = levels
        logBodyText = body
        logBodyFilter = body
        sidebar = scope
        // Redo clears them again.
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.clearLogFilters(undoManager: undoManager) }
        }
        undoManager?.setActionName("Clear Filters")
    }

    func updateFilterMenu() {
        switch contentMode {
        case .logs:
            MenuState.shared.update(filterBar: showsLogFilterBar ? .shown : .hidden, hasFilters: hasLogFilters)
        case .traces:
            MenuState.shared.update(filterBar: showsTraceFilterBar ? .shown : .hidden, hasFilters: hasTraceFilters)
        }
        updateSavedFilterMenu()
    }
}
