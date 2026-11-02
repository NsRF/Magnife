import Foundation
import Testing
@testable import MagnifeKit

/// What a launch restores (S-029): scope, filters and selected trace kept
/// in UserDefaults at quit, and a deleted saved filter falling back to its service.
@Suite("Launch state (S-029)")
struct LaunchStateTests {
    private func defaults() -> UserDefaults {
        let name = "magnife.launchstate.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("a first launch has nothing to restore")
    func nothingStored() {
        #expect(LaunchState.stored(in: defaults()) == nil)
    }

    @Test("the state round-trips through UserDefaults, every scope")
    func roundTrip() {
        let store = defaults()
        let scopes: [LaunchState.Scope] = [.allServices, .service("checkout-api"), .savedFilter(UUID())]
        for scope in scopes {
            let state = LaunchState(scope: scope, traceQuery: "service:checkout-api status:error >200ms",
                                    showsTraceFilterBar: true, logLevels: [17, 13], logBody: "cart",
                                    showsLogFilterBar: true, selectedTraceID: "4bf92f3577b34da6a3ce929d0e0e4736")
            state.store(in: store)
            #expect(LaunchState.stored(in: store) == state)
        }
    }

    @Test("the query means the trace list's filters, service included")
    func filter() {
        let state = LaunchState(traceQuery: "service:orders status:error >100ms")
        #expect(state.traceFilter == TraceFilter(service: "orders", statuses: [.error], slowerThanNs: 100_000_000))
        #expect(LaunchState().traceFilter == TraceFilter())
    }

    @Test("level chips come back by their OTel numbers; unknown numbers are dropped")
    func levels() {
        #expect(LaunchState(logLevels: [17, 13]).levels == [.error, .warn])
        #expect(LaunchState(logLevels: [3, 9]).levels == [.info])
    }

    @Test("a saved filter deleted since the quit falls back to its query's service, filters kept")
    func deletedSavedFilter() {
        let saved = SavedFilter(name: "Checkout errors", query: "service:checkout-api status:error")
        let kept = LaunchState(scope: .savedFilter(saved.id), traceQuery: saved.query)
        #expect(kept.resolved(savedFilters: SavedFilters([saved])) == kept)
        let gone = kept.resolved(savedFilters: SavedFilters())
        #expect(gone.scope == .service("checkout-api"))
        #expect(gone.traceQuery == saved.query)
        let noService = LaunchState(scope: .savedFilter(UUID()), traceQuery: "status:error")
        #expect(noService.resolved(savedFilters: SavedFilters()).scope == .allServices)
    }

    @Test("a state that does not decode is no state")
    func garbage() {
        let store = defaults()
        store.set(Data("not json".utf8), forKey: LaunchState.defaultsKey)
        #expect(LaunchState.stored(in: store) == nil)
    }
}
