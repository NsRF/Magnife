import Foundation
import Testing
@testable import MagnifeKit

/// The trace list's table updates (S-030): one change per update, rows
/// matched by id, and new rows paced to at most one insert every 250 ms.
@Suite("Live rows (S-030)")
struct LiveRowsTests {
    private struct Row: Identifiable, Equatable {
        var id: String
        var spans = 1
    }

    private func rows(_ ids: String...) -> [Row] { ids.map { Row(id: $0) } }

    @Test("same rows: nothing to do")
    func same() {
        #expect(RowUpdate.between(rows("a", "b"), rows("a", "b")) == .none)
        #expect(RowUpdate.between([Row](), []) == .none)
    }

    @Test("to or from an empty list: one reload")
    func empty() {
        #expect(RowUpdate.between([], rows("a")) == .reload)
        #expect(RowUpdate.between(rows("a"), []) == .reload)
    }

    @Test("new traces at the top: inserted there, the rest kept")
    func prepend() {
        let update = RowUpdate.between(rows("c", "d"), rows("a", "b", "c", "d"))
        #expect(update == .changes(removed: [], inserted: [0, 1], changed: []))
        #expect(update.movesRows)
    }

    @Test("a row whose values changed is reloaded in place, at its new index")
    func changedInPlace() {
        var new = rows("a", "b", "c")
        new[1].spans = 5
        #expect(RowUpdate.between(rows("a", "b", "c"), new) == .changes(removed: [], inserted: [], changed: [1]))
        #expect(!RowUpdate.between(rows("a", "b", "c"), new).movesRows)
        var grown = rows("x", "a", "b", "c")
        grown[2].spans = 5
        #expect(RowUpdate.between(rows("a", "b", "c"), grown) == .changes(removed: [], inserted: [0], changed: [2]))
    }

    @Test("pruned rows are removed; a page below is appended")
    func removeAndAppend() {
        #expect(RowUpdate.between(rows("a", "b", "c"), rows("a", "c")) == .changes(removed: [1], inserted: [], changed: []))
        #expect(RowUpdate.between(rows("a", "b"), rows("a", "b", "c", "d"))
                == .changes(removed: [], inserted: [2, 3], changed: []))
    }

    @Test("a row that moved (an earlier root arrived) is removed and inserted")
    func moved() {
        guard case .changes(let removed, let inserted, _) = RowUpdate.between(rows("a", "b", "c"), rows("b", "c", "a")) else {
            Issue.record("expected steps")
            return
        }
        #expect(removed.count == 1 && inserted.count == 1)
        // Applying the steps gives the new order.
        var shown = rows("a", "b", "c").map(\.id)
        for index in removed.reversed() { shown.remove(at: index) }
        let new = ["b", "c", "a"]
        for index in inserted { shown.insert(new[index], at: index) }
        #expect(shown == new)
    }

    @Test("another scope with few rows in common reloads")
    func otherScope() {
        let old = (0..<800).map { Row(id: "old\($0)") }
        let new = (0..<800).map { Row(id: "new\($0)") }
        #expect(RowUpdate.between(old, new) == .reload)
    }

    @Test("the steps for 100,000 rows with 50 new on top are worked out quickly")
    func large() {
        let old = (0..<100_000).map { Row(id: "t\($0)") }
        let new = (0..<50).map { Row(id: "n\($0)") } + old.dropLast(50)
        let started = ContinuousClock.now
        let update = RowUpdate.between(old, new)
        let elapsed = ContinuousClock.now - started
        #expect(update == .changes(removed: IndexSet(99_950..<100_000), inserted: IndexSet(0..<50), changed: []))
        #expect(elapsed < .seconds(1))
    }

    @Test("rows go in at most every 250 ms; changes in place and empty lists at once")
    func pacing() {
        var pacer = UpdatePacer()
        let insert = RowUpdate.changes(removed: [], inserted: [0], changed: [])
        let inPlace = RowUpdate.changes(removed: [], inserted: [], changed: [3])
        #expect(pacer.delay(for: insert, at: 10, fromEmpty: false, toEmpty: false) == 0)
        pacer.applied(insert, at: 10)
        #expect(abs(pacer.delay(for: insert, at: 10.1, fromEmpty: false, toEmpty: false) - 0.15) < 1e-9)
        #expect(pacer.delay(for: insert, at: 10.3, fromEmpty: false, toEmpty: false) == 0)
        #expect(pacer.delay(for: inPlace, at: 10.1, fromEmpty: false, toEmpty: false) == 0)
        // A new scope empties the list and fills it at once.
        #expect(pacer.delay(for: .reload, at: 10.05, fromEmpty: false, toEmpty: true) == 0)
        #expect(pacer.delay(for: .reload, at: 10.05, fromEmpty: true, toEmpty: false) == 0)
        pacer.applied(inPlace, at: 10.2)
        #expect(pacer.lastMove == 10)
    }

    @Test("under load (rows moving within the last second) rows go in without animation")
    func busy() {
        var pacer = UpdatePacer()
        #expect(!pacer.isBusy(at: 5))
        pacer.applied(.reload, at: 5)
        #expect(pacer.isBusy(at: 5.5))
        #expect(!pacer.isBusy(at: 6.5))
    }
}
