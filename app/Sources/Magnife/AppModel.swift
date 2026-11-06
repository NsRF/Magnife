import AppKit
import SwiftUI
import MagnifeKit

/// The sidebar's selection.
enum SidebarSelection: Hashable {
    case allTraces
    case service(String)
    /// A saved filter (S-021): its scope and filters, by id.
    case savedFilter(SavedFilter.ID)

    var serviceName: String? {
        if case .service(let name) = self { return name }
        return nil
    }

    var savedFilterID: SavedFilter.ID? {
        if case .savedFilter(let id) = self { return id }
        return nil
    }
}

/// Where the database is open, or why it is not.
enum StoreState: Equatable {
    case opening
    case waiting(StoreError)
    case ready
    case failed(StoreError)
}

/// App-wide state that menus, toolbars, and views share. Reads run off the
/// main actor in TelemetryReader; this model only holds their results.
@Observable
final class AppModel {
    /// Batches arriving within this window share one refresh.
    static let refreshDelay: Duration = .milliseconds(150)

    let storeURL: URL
    private(set) var storeState: StoreState = .opening
    private(set) var reader: TelemetryReader?

    var receiver: ReceiverStatus = .starting
    /// True once the receiver has been starting for half a second (S-001):
    /// before that the toolbar shows nothing.
    var quietStartOver = false
    /// The helper crashed and was restarted (S-008 banner). Clears on the next trace.
    var receiverRestarted = false
    /// Why the helper could not start (banner with a close button).
    var helperMessage: String?
    /// The helper's last "error" line (banner with Try Again).
    var helperProblem: String?

    var services: [ServiceSummary] = [] {
        didSet { if services != oldValue { serviceColors = ServiceColors(services: services) } }
    }
    /// The subtitle and the sidebar's services as shown, at most once a second under load (AppModel+Counts.swift).
    var shownSubtitle = ""
    var shownServices: [ServiceSummary] = []
    @ObservationIgnored var countThrottle = Throttle()
    @ObservationIgnored var countTask: Task<Void, Never>?
    /// The menus' update after a Traces | Logs switch (AppModel+Logs.swift).
    @ObservationIgnored var menuModeTask: Task<Void, Never>?
    /// True while a refresh started by the helper's batches applies its read
    /// (a task-local value: overlapping refreshes each keep their own, M3 review 6).
    var isBatchRefresh: Bool { RefreshPacing.isBatch }
    /// One color slot per service, in the order first seen (S-004).
    private(set) var serviceColors = ServiceColors()
    /// The list's rows: pages from the database, newest first (S-004).
    var traces: [TraceSummary] = [] {
        didSet { if traces != oldValue { updateTraceFindings() } }
    }
    /// The rows' finding badges (S-023+), read off the main actor and kept
    /// per trace until its `updated_seq` changes.
    var findingCache = FindingCache()
    @ObservationIgnored var findingCacheReader: ObjectIdentifier?
    @ObservationIgnored var findingsTask: Task<Void, Never>?
    @ObservationIgnored var findingsAgain = false
    /// The seq the shown rows were read at, and the last seq applied to them
    /// while the list holds still.
    var listBaseSeq: Int64 = 0
    var listAppliedSeq: Int64 = 0
    /// True while the list is scrolled away from the top: rows stay where
    /// they are and new traces are counted instead (design decision 6).
    var isListHeld = false
    /// Traces newer than the shown rows while the list holds still.
    var newTraceCount = 0 {
        didSet { updateNewRowsMenu() }
    }
    /// A full page came back, so there may be older rows to read.
    var hasMoreTraces = false
    /// Every trace the filters keep when the rows were read: the window's subtitle (S-009).
    var listTraceCount = 0
    /// Every trace of the service scope, the filter bar aside ("312 of 1,204 traces").
    var listScopeCount = 0
    /// The trace list's own filters (S-017 to S-020): status chips, "Slower
    /// than" and condition rows; the sidebar holds the service. Any change
    /// reads the list again from the top (AppModel+TraceFilter.swift).
    var traceStatuses: Set<SpanStatus> = [] {
        didSet { if traceStatuses != oldValue { traceFilterChanged() } }
    }
    var traceSlowerThanNs: Int64? {
        didSet { if traceSlowerThanNs != oldValue { traceFilterChanged() } }
    }
    /// "Slower than" as typed (S-019); it becomes `traceSlowerThanNs` a moment
    /// after the last key, when it parses. Text that does not parse keeps the last rule.
    var traceSlowerThanText = "" {
        didSet { if traceSlowerThanText != oldValue { applySlowerThanText() } }
    }
    @ObservationIgnored var slowerThanTask: Task<Void, Never>?
    /// The condition rows as typed (S-020); they become `traceConditions` a
    /// moment after the last change. One empty row while there are none.
    var conditionRows: [ConditionDraft] = [ConditionDraft()] {
        didSet { if conditionRows != oldValue { applyConditionRows() } }
    }
    @ObservationIgnored var conditionTask: Task<Void, Never>?
    /// The row whose key field is being edited, the highlighted suggestion,
    /// and whether Esc put the suggestions away until the next key.
    var editingConditionKey: ConditionDraft.ID?
    var conditionSuggestionIndex = 0
    var conditionSuggestionsDismissed = false
    /// Attribute keys received, for the key field's suggestions.
    var conditionKeys: [AttributeKey] = []
    var traceConditions: [TraceCondition] = [] {
        didSet { if traceConditions.filter(\.isActive) != oldValue.filter(\.isActive) { traceFilterChanged() } }
    }
    /// The Traces filter bar (S-018), shown with ⌘F or the Filter button.
    var showsTraceFilterBar = false {
        didSet { updateFilterMenu() }
    }
    /// Set by View > Show Filter Bar (⌘F): the bar's first field takes the focus once.
    var focusesTraceFilterField = false
    /// Search (S-017, ⌘K): whether it shows, what is typed, what it found,
    /// and the highlighted row (suggestions first, then traces).
    var showsSearch = false
    var searchText = "" {
        didSet { if searchText != oldValue { searchTextChanged() } }
    }
    var searchResult: TraceSearchResult?
    var searchSelection = 0
    /// Attribute keys received, for `has:` (read when Search opens).
    var searchAttributeKeys: [String] = []
    @ObservationIgnored var searchTask: Task<Void, Never>?
    @ObservationIgnored var searchAnnouncement: Task<Void, Never>?
    /// Bumped to put the focus in the field with its text selected (⌘K while Search shows).
    var searchFocusRequest = 0
    /// Another store for Search only: the self-test times it on 100,000 spans.
    @ObservationIgnored var searchReader: TelemetryReader?
    /// When the last result was shown, after how long since its key (self-test timing).
    @ObservationIgnored var searchTypedAt: ContinuousClock.Instant?
    @ObservationIgnored var lastSearchLatency: Duration?
    /// Compare With… (S-036): Search picks B for this trace, A; nil in plain Search.
    var searchCompareBase: TraceSummary?
    /// The newest other traces of A's route, listed first under "Same Route".
    var searchSameRoute: [TraceSummary] = []
    /// The Compare Traces window (S-036), observed apart from the main window.
    @ObservationIgnored let compare = CompareModel()
    /// While paused (S-010), the seq the list paused at; nil when live.
    /// Never restored at launch: Pause is always off then (docs/ux.md).
    var pausedSeq: Int64? {
        didSet {
            MenuState.shared.update(isPaused: isPaused)
            updateNewRowsMenu()
        }
    }
    /// While Resume is in flight, every page read of the trace list asks for
    /// this many rows, so a refresh in between cannot drop the selection (S-010).
    @ObservationIgnored var resumeRows: Int?
    @ObservationIgnored var isLoadingMore = false
    /// Reports scrolling in the trace list's table.
    @ObservationIgnored lazy var listScroller: TraceListScroller = {
        let scroller = TraceListScroller()
        scroller.onChange = { [weak self] away in self?.listScrolled(awayFromTop: away) }
        return scroller
    }()
    /// The open trace's waterfall (S-005), built off the main actor; a new
    /// generation each time it is rebuilt, so the outline reloads only then.
    var waterfall = Waterfall()
    var waterfallGeneration = 0
    /// The open trace's row, read with its spans (it may not be in the list).
    var openTrace: TraceSummary?
    /// The open trace's findings, read with its waterfall (S-023+): the
    /// strip under the header, the rows' icons, the span detail's Findings.
    var openTraceFindings = TraceFindings()
    /// The strip shows every finding, not the first three.
    var showsAllFindings = false
    /// The selected trace that retention deleted (S-015): the detail column
    /// shows "Trace No Longer Stored" while it stays selected.
    var prunedTraceID: String?
    /// Spans whose subtree is closed in the waterfall, by span id.
    var collapsedSpans: Set<String> = []
    /// The selected waterfall row (the span detail reads it, S-006).
    var selectedSpanID: String? {
        didSet { if selectedSpanID != oldValue { loadSpanDetail() } }
    }
    /// The selected span with its resource, read off the main actor (S-006).
    var spanDetail: SpanDetail? {
        didSet { if spanDetail != oldValue { spanDetailChanged(from: oldValue) } }
    }
    @ObservationIgnored var spanDetailTask: Task<Void, Never>?
    /// The open trace's logs when last checked; a new one re-reads the span detail (S-011).
    @ObservationIgnored var openTraceLogStamp: LogStamp?
    /// Every log of the open trace (S-012), and the selected one.
    var traceLogs = TraceLogs()
    var selectedTraceLogID: LogLine.ID? {
        didSet { updateLogMenu() }
    }
    @ObservationIgnored var traceLogsTask: Task<Void, Never>?
    /// The span detail's tab, Span or Trace Logs; remembered across launches.
    var spanDetailTab: SpanDetailTab = .stored {
        didSet {
            if !StoreLocation.isOverridden() { UserDefaults.standard.set(spanDetailTab.rawValue, forKey: SpanDetailTab.defaultsKey) }
            updateLogMenu()
            loadTraceLogsIfStale()
        }
    }
    /// The exception whose Copy Stack Trace reads "Copied" for 2 seconds (S-007), by index.
    var copiedStackTrace: Int?
    @ObservationIgnored var stackTraceCopiedTask: Task<Void, Never>?
    /// A section to scroll the span detail to; the pane clears it once scrolled.
    var spanDetailScrollTarget: SpanDetail.Section?
    /// Where the target lands: its top at the top, or its bottom at the bottom.
    @ObservationIgnored var spanDetailScrollAnchor: UnitPoint = .top
    /// Values and stack traces opened with Show All, by `SpanDetailValueID`;
    /// cleared when another span is selected.
    var expandedValues: Set<String> = []
    /// How each long value lays out (full and shown height), for the self-test.
    @ObservationIgnored var valueLayouts: [String: ValueLayout] = [:]
    /// The lower pane of the detail column (View > Show Span Detail ⌃⌘I).
    /// Remembered across launches; test and snapshot runs start shown.
    var showsSpanDetail: Bool = StoreLocation.isOverridden() || UserDefaults.standard.object(forKey: "detail.showsSpanDetail") as? Bool ?? true {
        didSet {
            if !StoreLocation.isOverridden() { UserDefaults.standard.set(showsSpanDetail, forKey: "detail.showsSpanDetail") }
            MenuState.shared.update(showsSpanDetail: showsSpanDetail)
            loadTraceLogsIfStale()
        }
    }
    @ObservationIgnored var waterfallTask: Task<Void, Never>?
    /// When the open waterfall was last rebuilt, and the rebuild waiting for its 500 ms (S-030).
    @ObservationIgnored var lastWaterfallRebuild: ContinuousClock.Instant?
    @ObservationIgnored var waterfallRefreshTask: Task<Void, Never>?
    /// True while the selected trace's first read is in flight.
    @ObservationIgnored var isOpeningTrace = false
    /// The generation the outline shows, and when a trace was selected (self-test timing).
    @ObservationIgnored var shownWaterfallGeneration = 0
    @ObservationIgnored var waterfallRequestedAt: ContinuousClock.Instant?
    @ObservationIgnored var lastWaterfallOpen: Duration?
    /// The waterfall's outline, for the self-test.
    @ObservationIgnored weak var waterfallOutline: NSOutlineView?
    /// Traces or Logs in the content and detail columns (docs/ux.md, Traces
    /// vs Logs; View ⌘1 / ⌘2). Remembered across launches; test runs start on Traces.
    var contentMode: ContentMode = .stored {
        didSet { if contentMode != oldValue { contentModeChanged() } }
    }
    /// The Logs list (S-013): its rows, newest first, and what
    /// `LogListState.applying` keeps beside them (AppModel+Logs.swift).
    var logs: [LogListItem] = []
    @ObservationIgnored var logBaseID: Int64 = 0
    @ObservationIgnored var logAppliedSeq: Int64 = 0
    var isLogListHeld = false
    var newLogCount = 0 {
        didSet { updateNewRowsMenu() }
    }
    var hasMoreLogs = false
    var logCount = 0
    /// Every log of the service scope, the filter bar aside ("312 of 1,204 logs").
    var logScopeCount = 0
    /// The Logs filter bar (S-014): its level chips, its "Body contains"
    /// text as typed and as applied (a moment later), and whether it shows.
    /// Log filters are not saved (docs/ux.md, Filter bar).
    var logLevels: Set<SeverityLevel> = [] {
        didSet { if logLevels != oldValue { logFilterChanged() } }
    }
    var logBodyText = "" {
        didSet { if logBodyText != oldValue { applyLogBodyText() } }
    }
    var logBodyFilter = "" {
        didSet { if logBodyFilter != oldValue { logFilterChanged() } }
    }
    @ObservationIgnored var logBodyTask: Task<Void, Never>?
    var showsLogFilterBar = false {
        didSet { updateFilterMenu() }
    }
    /// Set by View > Show Filter Bar (⌘F): the bar's field takes the focus once.
    var focusesLogFilterField = false
    /// A page for the current filter has been shown: the empty state waits for it.
    var logsLoaded = false
    /// While paused, the log id the Logs list paused at (S-010).
    var logPausedID: Int64?
    /// The Logs list's `resumeRows`.
    @ObservationIgnored var resumeLogRows: Int?
    @ObservationIgnored var isLoadingMoreLogs = false
    /// The Logs counts as last read, so a refresh counts only newer logs (S-030).
    @ObservationIgnored var logCountMark: LogCountMark?
    @ObservationIgnored lazy var logScroller: TraceListScroller = {
        let scroller = TraceListScroller()
        scroller.onChange = { [weak self] away in self?.logListScrolled(awayFromTop: away) }
        return scroller
    }()
    var selectedLogID: LogListItem.ID? {
        didSet {
            guard selectedLogID != oldValue else { return }
            loadLogDetail()
            updateTraceIDMenu()
        }
    }
    /// The selected log with its resource (the Log Detail), read off the main actor.
    var logDetail: LogDetail? {
        didSet { updateLogMenu() }
    }
    @ObservationIgnored var logDetailTask: Task<Void, Never>?
    /// The span Open Trace selects once that trace's waterfall is built
    /// (nil span: the root, which opening selects anyway).
    @ObservationIgnored var pendingSpan: (traceID: String, spanID: String?)?
    /// The trace whose earliest Error span opens once its waterfall is built
    /// (S-027, a Recent Errors item).
    @ObservationIgnored var pendingFailedTrace: String?
    /// The selected trace of the last quit, selected after the first read (S-029).
    @ObservationIgnored var launchSelection: String?
    /// The menu bar extra's Recent Errors and the icon's count (S-026). Not
    /// observed: its seqs change with every batch; the menu and the icon
    /// read the two copies below, set only when what they show changes.
    @ObservationIgnored var recentErrors = RecentErrors() {
        didSet { publishRecentErrors() }
    }
    var recentErrorTraces: [TraceSummary] = []
    @ObservationIgnored var recentErrorsThrottle = Throttle()
    @ObservationIgnored var recentErrorsTask: Task<Void, Never>?
    /// Notifications for traces with errors (S-028), with their setting.
    let failureNotifier = FailureNotifier()
    var newErrorCount = 0
    /// The items' times count from when the menu last opened (docs/ux.md, S-026).
    var recentErrorsOpenedAt = Date()
    /// The Time column counts from this; it ticks every 15 seconds.
    private(set) var now = Date()

    var sidebar: SidebarSelection? = .allTraces {
        didSet {
            guard sidebar != oldValue else { return }
            // A saved filter brings back its scope and filters, in the Traces view (docs/ux.md).
            if let id = sidebar?.savedFilterID, let saved = savedFilters[id] { loadSavedFilter(saved) }
            resetTraceList()
            resetLogList()
            updateFilterMenu()
            refreshNow()
        }
    }
    /// The saved filters in the sidebar (S-021), in the order created; kept
    /// in UserDefaults (AppDefaults.shared), never in the database.
    var savedFilters: SavedFilters = .stored(in: AppDefaults.shared) {
        didSet {
            guard savedFilters != oldValue else { return }
            savedFilters.store(in: AppDefaults.shared)
            updateFilterMenu()
        }
    }
    /// While a saved filter is selected, the service its scope has now
    /// (the Service pop-up changes it, and the title then reads "— Edited").
    var savedFilterService: String? {
        didSet {
            guard savedFilterService != oldValue, sidebar?.savedFilterID != nil, !holdsFilterChanges else { return }
            resetLogList()
            traceFilterChanged()
        }
    }
    /// True while several filters change as one: one read follows, not one per filter.
    @ObservationIgnored var holdsFilterChanges = false
    /// The Save Filter sheet (S-021): shown, and the name typed.
    var showsSaveFilterSheet = false
    var saveFilterName = ""
    /// The saved filter whose name is being edited in place in the sidebar.
    var renamingFilterID: SavedFilter.ID?
    /// The sidebar has the keyboard focus: Delete Filter (⌘⌫) works only then,
    /// so ⌘⌫ still edits text fields.
    var sidebarHasFocus = false {
        didSet { if sidebarHasFocus != oldValue { updateFilterMenu() } }
    }
    /// True between a scope change and its first read, so the empty state waits.
    var isLoadingScope = false
    var selectedTraceID: TraceSummary.ID? {
        didSet {
            guard selectedTraceID != oldValue else { return }
            openSelectedTrace()
            updateTraceIDMenu()
        }
    }
    /// The column the keyboard focus was last sent to (S-022); the SwiftUI
    /// columns (sidebar, span detail) take it when it names them.
    var focusRequest: FocusRequest?
    @ObservationIgnored var unconsumedFocus: FocusColumn?
    /// The span detail has the keyboard focus (self-test).
    @ObservationIgnored var spanDetailHasFocus = false
    /// Settings reopens on the last tab. Test and snapshot runs leave it alone.
    var settingsTab: SettingsTab = SettingsTab(rawValue: UserDefaults.standard.string(forKey: "settings.tab") ?? "") ?? .general {
        didSet { if !StoreLocation.isOverridden() { UserDefaults.standard.set(settingsTab.rawValue, forKey: "settings.tab") } }
    }
    /// The language tab of the environment variables (S-003). Test and
    /// snapshot runs start on .NET and remember nothing.
    var environmentLanguage: EnvironmentLanguage = StoreLocation.isOverridden() ? .defaultLanguage : .stored(in: .standard) {
        didSet { if !StoreLocation.isOverridden() { environmentLanguage.store(in: .standard) } }
    }
    /// True for 2 seconds after a copy: the button reads "Copied".
    var environmentCopied = false
    /// Set by the first copy: the empty state then reads "Waiting for the first trace…".
    var hasCopiedEnvironment = false
    /// The toolbar's Copy Environment Variables popover.
    var showsEnvironmentPopover = false
    @ObservationIgnored var copiedResetTask: Task<Void, Never>?
    /// The agent tab of Settings > Agents (S-035), in AppDefaults.shared (the
    /// test suite in snapshot and self-test runs).
    var agentClient: AgentClient = .stored(in: AppDefaults.shared) {
        didSet { agentClient.store(in: AppDefaults.shared) }
    }
    /// True for 2 seconds after Copy Command / Copy Configuration.
    var agentSetupCopied = false
    @ObservationIgnored var agentCopiedResetTask: Task<Void, Never>?
    /// How long the helper keeps data, in seconds (S-015, S-016): 24 hours
    /// on first launch, APP_RETENTION_SECONDS in test runs (which never read
    /// the owner's choice: `Retention.atLaunch`). Sent to the
    /// helper with --retention at every launch (restarts too) and
    /// `retention <s>` on change (`HelperSupervisor.setRetention`).
    var retentionSeconds: Int = Retention.atLaunch(in: .standard) {
        didSet {
            guard retentionSeconds != oldValue else { return }
            if !StoreLocation.isOverridden() { UserDefaults.standard.set(retentionSeconds, forKey: Retention.defaultsKey) }
            supervisor?.setRetention(seconds: retentionSeconds)
        }
    }

    /// A shorter period waiting for its "Delete Data Older Than …?" dialog (S-016).
    var pendingRetention: Int?
    /// The database files' size on disk, for Settings > General (S-016); nil until first read.
    var databaseSize: Int64?
    @ObservationIgnored var databaseSizeTask: Task<Void, Never>?

    var supervisor: HelperSupervisor?
    /// Files this model asked the helper to import (AppModel+Sharing.swift):
    /// only their answers open a trace or show an alert.
    @ObservationIgnored var pendingImports: Set<String> = []
    /// Sees every helper event before the model handles it (self-test timing).
    @ObservationIgnored var onHelperEvent: ((SupervisorEvent) -> Void)?
    var quietStartTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var refreshAgain = false
    private var openTask: Task<Void, Never>?
    private var openRetry: Task<Void, Never>?

    init(storeURL: URL = StoreLocation.url()) {
        self.storeURL = storeURL
    }

    var selectedTrace: TraceSummary? {
        traces.first { $0.id == selectedTraceID }
    }

    /// The window's title: the sidebar scope (docs/ux.md, Window), or the
    /// saved filter's name, "Checkout errors — Edited" once its filters changed.
    var title: String {
        if let saved = selectedSavedFilter { return saved.title(edited: isSavedFilterEdited) }
        return sidebar?.serviceName ?? "All Services"
    }

    /// The window's subtitle: the count in the list, "1,204 traces" or
    /// "8,310 logs"; blank while there is nothing to count.
    var subtitle: String {
        switch contentMode {
        case .traces:
            // "312 of 1,204 traces" while the filters hide some (S-018).
            traceFilter.narrowsScope ? (isLoadingScope ? "" : TraceList.subtitle(shown: listTraceCount, of: listScopeCount, isPaused: isPaused))
                : listTraceCount == 0 ? (isPaused ? "Paused" : "") : TraceList.subtitle(traceCount: listTraceCount, isPaused: isPaused)
        case .logs:
            // "312 of 1,204 logs" while the filter bar hides some (S-014).
            logFilter.narrowsScope ? (logsLoaded ? LogList.subtitle(shown: logCount, of: logScopeCount, isPaused: isPaused) : "")
                : logCount == 0 ? (isPaused ? "Paused" : "") : LogList.subtitle(logCount: logCount, isPaused: isPaused)
        }
    }

    /// Starts the clock for the Time column and opens the database.
    func start() {
        MenuState.shared.update(showsSpanDetail: showsSpanDetail)
        MenuState.shared.update(contentMode: contentMode)
        restoreLaunchState()
        followCounts()
        Task { await openStore() }
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                self?.now = Date()
            }
        }
        startReceiver()
    }

    // MARK: Reading

    /// Opens the database, or waits: a missing or not-ready file is retried
    /// on the helper's next event and every 2 seconds.
    func openStore() async {
        if let openTask { return await openTask.value }
        guard reader == nil else { return }
        let task = Task { await self.tryOpen() }
        openTask = task
        await task.value
        openTask = nil
    }

    private func tryOpen() async {
        do {
            reader = try await TelemetryReader.open(at: storeURL)
            LaunchProbe.mark("store_open")
            // Ready after the first read, so a relaunch never shows an empty list first (S-008).
            await reload()
            storeState = .ready
            LaunchProbe.mark("first_read")
            finishLaunch()
        } catch {
            storeState = error.isTransient ? .waiting(error) : .failed(error)
            // One retry timer at a time, however many events also retry.
            if error.isTransient, openRetry == nil {
                openRetry = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    self?.openRetry = nil
                    await self?.openStore()
                }
            }
        }
    }

    /// Switches to another database file (snapshot pages only).
    func useStore(at url: URL) async {
        reader = nil
        // Another file has its own seqs.
        listBaseSeq = 0
        listAppliedSeq = 0
        pausedSeq = nil
        logPausedID = nil
        resetLogList()
        recentErrors = RecentErrors()
        storeState = .opening
        do {
            reader = try await TelemetryReader.open(at: url)
            storeState = .ready
        } catch {
            storeState = .failed(error)
        }
        await reload()
    }

    /// Coalesces batch notifications: at most one refresh in flight, started
    /// `refreshDelay` after the first batch; batches during it cause one more.
    func requestRefresh() {
        guard refreshTask == nil else {
            refreshAgain = true
            return
        }
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: Self.refreshDelay)
            await self?.reload(fromBatches: true)
            guard let self else { return }
            self.refreshTask = nil
            if self.refreshAgain {
                self.refreshAgain = false
                self.requestRefresh()
            }
        }
    }

    /// A refresh with no delay, for a change people made (the sidebar).
    func refreshNow() {
        Task { await reload() }
    }

    /// Reads services and the list (S-004), and the selected trace's spans.
    /// From batches, the counts it changes show at most once a second.
    func reload(fromBatches: Bool = false) async {
        guard let reader else {
            services = []
            traces = []
            isLoadingScope = false
            resetLogList()
            return
        }
        refreshDatabaseSize()
        await RefreshPacing.$isBatch.withValue(fromBatches) {
            await applyRefresh(reader)
        }
    }

    /// One refresh's reads, paced as `RefreshPacing.isBatch` says.
    private func applyRefresh(_ reader: TelemetryReader) async {
        do {
            try await reloadList(reader)
            // The Logs list is read while it shows; switching to it reads it at once.
            if contentMode == .logs { try await reloadLogs(reader) }
            now = Date()
            // The menu bar extra keeps counting while paused (docs/ux.md, S-010 States).
            await refreshRecentErrors(reader)
            // Batch lines that came before the store opened (S-028).
            drainFailures()
            // Paused, the open waterfall holds still too (S-010).
            if !isPaused {
                try await refreshOpenTrace(reader)
                try await refreshOpenTraceLogs(reader)
                // A compared trace still receiving spans (S-036).
                try await refreshComparison(reader)
            }
        } catch {
            isLoadingScope = false
            FileHandle.standardError.write(Data("magnife: read failed: \(error)\n".utf8))
        }
    }
}
