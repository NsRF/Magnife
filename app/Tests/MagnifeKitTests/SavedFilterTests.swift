import Foundation
import Testing
@testable import MagnifeKit

/// Saved filters (S-021): the query they keep, "Edited", the name rules,
/// rename, delete with its undo, and the round trip through UserDefaults.
@Suite("Saved filters (S-021)")
struct SavedFilterTests {
    private func defaults() -> UserDefaults {
        let name = "magnife.savedfilters.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private let checkoutErrors = TraceFilter(service: "checkout-api", statuses: [.error])

    @Test("a saved filter keeps its scope and filters as a query")
    func query() {
        let saved = SavedFilter(name: "Checkout errors", filter: checkoutErrors)
        #expect(saved.query == "service:checkout-api status:error")
        #expect(saved.filter == checkoutErrors)
        let rich = TraceFilter(service: "web", statuses: [.ok, .error], slowerThanNs: 200_000_000,
                               conditions: [TraceCondition(field: .attribute("http.route"), op: .is, value: "/orders"),
                                            TraceCondition(field: .anyField, op: .contains, value: "pay now")])
        #expect(SavedFilter(name: "x", filter: rich).filter == rich)
        #expect(saved.spokenLabel == "Checkout errors, saved filter")
    }

    @Test("Edited follows the filters, not the order or empty rows")
    func edited() {
        let saved = SavedFilter(name: "Checkout errors", filter: checkoutErrors)
        #expect(!saved.isEdited(by: checkoutErrors))
        var withEmptyRow = checkoutErrors
        withEmptyRow.conditions = [TraceCondition()]
        #expect(!saved.isEdited(by: withEmptyRow))
        var more = checkoutErrors
        more.statuses.insert(.ok)
        #expect(saved.isEdited(by: more))
        var otherService = checkoutErrors
        otherService.service = "orders"
        #expect(saved.isEdited(by: otherService))
        #expect(saved.isEdited(by: .cleared))
        #expect(saved.title(edited: true) == "Checkout errors — Edited")
        #expect(saved.title(edited: false) == "Checkout errors")
    }

    @Test("names are trimmed, never empty, and unique ignoring case")
    func names() throws {
        var filters = SavedFilters()
        #expect(filters.problem(with: "  ") == .empty)
        #expect(SavedFilters.NameProblem.empty.message == nil)
        let added = filters.add(name: "  Checkout errors ", filter: checkoutErrors)
        let first = try #require(added)
        #expect(first.name == "Checkout errors")
        #expect(filters.problem(with: "checkout ERRORS") == .duplicate("Checkout errors"))
        #expect(SavedFilters.NameProblem.duplicate("Checkout errors").message
                == "A saved filter named “Checkout errors” already exists.")
        let duplicate = filters.add(name: "Checkout errors", filter: .cleared)
        let empty = filters.add(name: "", filter: .cleared)
        #expect(duplicate == nil && empty == nil)
        // Its own name is no duplicate when renaming it.
        #expect(filters.problem(with: "checkout errors", renaming: first.id) == nil)
        #expect(filters.items.count == 1)
    }

    @Test("filters keep the order created; rename and update change one")
    func renameAndUpdate() throws {
        var filters = SavedFilters()
        let addedA = filters.add(name: "Checkout errors", filter: checkoutErrors)
        let addedB = filters.add(name: "Slow orders", filter: TraceFilter(service: "orders", slowerThanNs: 500_000_000))
        let a = try #require(addedA), b = try #require(addedB)
        #expect(filters.items.map(\.name) == ["Checkout errors", "Slow orders"])
        let renamed = filters.rename(a.id, to: "Payment errors")
        let unchanged = filters.rename(a.id, to: "Payment errors")
        let duplicate = filters.rename(a.id, to: "slow orders")
        let empty = filters.rename(a.id, to: " ")
        #expect(renamed && !unchanged && !duplicate && !empty)
        #expect(filters.items.map(\.name) == ["Payment errors", "Slow orders"])
        filters.update(b.id, filter: TraceFilter(service: "orders"))
        #expect(filters[b.id]?.query == "service:orders")
        #expect(filters[a.id]?.query == "service:checkout-api status:error")
    }

    @Test("delete says where it was, and Undo puts it back there")
    func deleteAndUndo() throws {
        var filters = SavedFilters()
        for name in ["A", "B", "C"] { filters.add(name: name, filter: .cleared) }
        let b = try #require(filters.items.first { $0.name == "B" })
        let first = filters.remove(b.id)
        let again = filters.remove(b.id)
        let removed = try #require(first)
        #expect(removed.index == 1 && filters.items.map(\.name) == ["A", "C"])
        #expect(again == nil)
        filters.insert(removed.filter, at: removed.index)
        #expect(filters.items.map(\.name) == ["A", "B", "C"])
        filters.insert(removed.filter, at: 0)
        #expect(filters.items.count == 3, "never twice")
    }

    @Test("they survive a relaunch through UserDefaults; bad data reads as none")
    func stored() throws {
        let store = defaults()
        #expect(SavedFilters.stored(in: store).isEmpty)
        var filters = SavedFilters()
        filters.add(name: "Checkout errors", filter: checkoutErrors)
        filters.add(name: "Slow", filter: TraceFilter(slowerThanNs: 1_500_000_000))
        filters.store(in: store)
        let read = SavedFilters.stored(in: store)
        #expect(read == filters)
        #expect(read.items.map(\.filter) == [checkoutErrors, TraceFilter(slowerThanNs: 1_500_000_000)])
        store.set(Data("not json".utf8), forKey: SavedFilters.defaultsKey)
        #expect(SavedFilters.stored(in: store).isEmpty)
    }
}
