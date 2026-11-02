import Foundation
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
    /// The newest traces the list shows. Paging further comes with S-030.
    static let pageSize = 500
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

    private(set) var services: [ServiceSummary] = []
    private(set) var traces: [TraceSummary] = []
    private(set) var lastSeq: Int64 = 0
    private(set) var selectedSpans: [SpanRecord] = []
    /// The Time column counts from this; it ticks every 15 seconds.
    private(set) var now = Date()

    var sidebar: SidebarSelection? = .allTraces {
        didSet {
            guard sidebar != oldValue else { return }
            // A new scope starts from an empty list. Diffing one scope's rows
            // into another's makes AppKit re-enter its row height cache
            // ("reentrant operation in its NSTableView delegate").
            traces = []
            isLoadingScope = true
            refreshNow()
        }
    }
    /// True between a scope change and its first read, so the empty state waits.
    private(set) var isLoadingScope = false
    var selectedTraceID: TraceSummary.ID? {
        didSet { if selectedTraceID != oldValue { loadSelectedSpans() } }
    }
    /// Settings reopens on the last tab. Test and snapshot runs leave it alone.
    var settingsTab: SettingsTab = SettingsTab(rawValue: UserDefaults.standard.string(forKey: "settings.tab") ?? "") ?? .general {
        didSet { if !StoreLocation.isOverridden() { UserDefaults.standard.set(settingsTab.rawValue, forKey: "settings.tab") } }
    }
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

    /// Reads services, the newest traces, and the selected trace's spans.
    func reload() async {
        guard let reader else {
            services = []
            traces = []
            isLoadingScope = false
            return
        }
        let service = sidebar?.serviceName
        do {
            async let services = reader.services()
            async let traces = reader.latestTraces(limit: Self.pageSize, service: service)
            async let seq = reader.lastSeq()
            let result = try await (services, traces, seq)
            // The sidebar changed while reading: that change reads again.
            guard service == sidebar?.serviceName, reader === self.reader else { return }
            // Equal results leave the views alone.
            if self.services != result.0 { self.services = result.0 }
            if self.traces != result.1 { self.traces = result.1 }
            isLoadingScope = false
            lastSeq = result.2
            now = Date()
            if let id = selectedTraceID {
                let spans = try await reader.spans(traceID: id)
                if selectedTraceID == id, spans != selectedSpans { selectedSpans = spans }
            }
        } catch {
            isLoadingScope = false
            FileHandle.standardError.write(Data("magnife: read failed: \(error)\n".utf8))
        }
    }

    private func loadSelectedSpans() {
        guard let id = selectedTraceID, let reader else {
            selectedSpans = []
            return
        }
        Task {
            let spans = (try? await reader.spans(traceID: id)) ?? []
            if selectedTraceID == id { selectedSpans = spans }
        }
    }
}
