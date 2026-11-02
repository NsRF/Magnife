import Foundation

// What a launch brings back (docs/ux.md, App-wide states: "Launch | Last
// view, scope, filters and selected trace restored"; S-029). The view
// (Traces | Logs) and the span detail's tab keep their own keys; this is
// the rest, kept by the app in UserDefaults when it quits, never in the
// database. Pause is never kept: it is always off at launch.

/// The scope, filters and selected trace a launch restores.
public struct LaunchState: Codable, Sendable, Equatable {
    public static let defaultsKey = "launch.state"

    /// The sidebar's row.
    public enum Scope: Codable, Sendable, Equatable {
        case allServices
        case service(String)
        case savedFilter(UUID)
    }

    public var scope: Scope
    /// The trace list's filters, service included, as `TraceQuery.format`
    /// writes them; a saved filter's edits come back through it.
    public var traceQuery: String
    public var showsTraceFilterBar: Bool
    /// The Logs filter bar's level chips (OTel severity numbers) and "Body contains".
    public var logLevels: [Int]
    public var logBody: String
    public var showsLogFilterBar: Bool
    public var selectedTraceID: String?

    public init(scope: Scope = .allServices, traceQuery: String = "", showsTraceFilterBar: Bool = false,
                logLevels: [Int] = [], logBody: String = "", showsLogFilterBar: Bool = false,
                selectedTraceID: String? = nil) {
        self.scope = scope
        self.traceQuery = traceQuery
        self.showsTraceFilterBar = showsTraceFilterBar
        self.logLevels = logLevels
        self.logBody = logBody
        self.showsLogFilterBar = showsLogFilterBar
        self.selectedTraceID = selectedTraceID
    }

    /// The trace list's filters the query means.
    public var traceFilter: TraceFilter { TraceQuery(traceQuery).filter }

    /// The log level chips, unknown numbers dropped.
    public var levels: Set<SeverityLevel> { Set(logLevels.compactMap(SeverityLevel.init(rawValue:))) }

    /// A saved filter deleted since the state was kept falls back to its
    /// query's service (or All Services), with the same filters.
    public func resolved(savedFilters: SavedFilters) -> LaunchState {
        guard case .savedFilter(let id) = scope, savedFilters[id] == nil else { return self }
        var state = self
        state.scope = traceFilter.service.map { .service($0) } ?? .allServices
        return state
    }

    /// The state kept at the last quit, nil when there is none or it does not decode.
    public static func stored(in defaults: UserDefaults) -> LaunchState? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(LaunchState.self, from: data)
    }

    public func store(in defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
