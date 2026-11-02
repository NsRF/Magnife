import AppKit
import SwiftUI
import MagnifeKit

/// The sidebar's selection.
enum SidebarSelection: Hashable {
    case allTraces
    case service(String)

    var serviceName: String? {
        if case .service(let name) = self { return name }
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
    /// One color slot per service, in the order first seen (S-004).
    private(set) var serviceColors = ServiceColors()
    /// The list's rows: pages from the database, newest first (S-004).
    var traces: [TraceSummary] = []
    /// The seq the shown rows were read at, and the last seq applied to them
    /// while the list holds still.
    var listBaseSeq: Int64 = 0
    var listAppliedSeq: Int64 = 0
    /// True while the list is scrolled away from the top: rows stay where
    /// they are and new traces are counted instead (design decision 6).
    var isListHeld = false
    /// Traces newer than the shown rows while the list holds still.
    var newTraceCount = 0 {
        didSet { MenuState.shared.update(newTraceCount: showsNewTracesButton ? newTraceCount : 0) }
    }
    /// A full page came back, so there may be older rows to read.
    var hasMoreTraces = false
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
        }
    }
    @ObservationIgnored var waterfallTask: Task<Void, Never>?
    /// The generation the outline shows, and when a trace was selected (self-test timing).
    @ObservationIgnored var shownWaterfallGeneration = 0
    @ObservationIgnored var waterfallRequestedAt: ContinuousClock.Instant?
    @ObservationIgnored var lastWaterfallOpen: Duration?
    /// The waterfall's outline, for the self-test.
    @ObservationIgnored weak var waterfallOutline: NSOutlineView?
    /// The Time column counts from this; it ticks every 15 seconds.
    private(set) var now = Date()

    var sidebar: SidebarSelection? = .allTraces {
        didSet {
            guard sidebar != oldValue else { return }
            // A new scope starts from an empty list. Diffing one scope's rows
            // into another's makes AppKit re-enter its row height cache
            // ("reentrant operation in its NSTableView delegate").
            traces = []
            isListHeld = false
            newTraceCount = 0
            hasMoreTraces = false
            isLoadingScope = true
            refreshNow()
        }
    }
    /// True between a scope change and its first read, so the empty state waits.
    var isLoadingScope = false
    var selectedTraceID: TraceSummary.ID? {
        didSet { if selectedTraceID != oldValue { openSelectedTrace() } }
    }
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
    /// How long the helper keeps data, in seconds (S-015, S-016).
    var retentionSeconds: Int = UserDefaults.standard.object(forKey: "retention.seconds") as? Int ?? HelperConfiguration.defaultRetention {
        didSet {
            guard retentionSeconds != oldValue else { return }
            if !StoreLocation.isOverridden() { UserDefaults.standard.set(retentionSeconds, forKey: "retention.seconds") }
            try? supervisor?.send(.retention(seconds: retentionSeconds))
        }
    }

    var supervisor: HelperSupervisor?
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

    var title: String {
        sidebar?.serviceName ?? "All Services"
    }

    /// Starts the clock for the Time column and opens the database.
    func start() {
        MenuState.shared.update(showsSpanDetail: showsSpanDetail)
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
            storeState = .ready
            await reload()
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
            await self?.reload()
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
    func reload() async {
        guard let reader else {
            services = []
            traces = []
            isLoadingScope = false
            return
        }
        do {
            try await reloadList(reader)
            now = Date()
            try await refreshOpenTrace(reader)
        } catch {
            isLoadingScope = false
            FileHandle.standardError.write(Data("magnife: read failed: \(error)\n".utf8))
        }
    }
}
