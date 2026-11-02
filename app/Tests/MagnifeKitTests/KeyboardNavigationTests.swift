import Foundation
import Testing
@testable import MagnifeKit

/// Keyboard navigation (S-022): ← and → on waterfall rows, Home / End /
/// Page Up / Page Down in lists, and the Tab order of the columns.
@Suite("Keyboard navigation (S-022)")
struct KeyboardNavigationTests {
    let waterfall = Waterfall(spans: WaterfallTests.orders)

    func index(_ id: String) -> Int { waterfall.index(of: id)! }

    @Test("← collapses an open span, else selects its parent")
    func left() {
        #expect(waterfall.moveLeft(from: index("charge"), collapsed: []) == .collapse(index("charge")))
        #expect(waterfall.moveLeft(from: index("charge"), collapsed: ["charge"]) == .select(index("root")))
        #expect(waterfall.moveLeft(from: index("stripe"), collapsed: []) == .select(index("charge")))
        #expect(waterfall.moveLeft(from: index("root"), collapsed: []) == .collapse(index("root")))
        #expect(waterfall.moveLeft(from: index("root"), collapsed: ["root"]) == .none)
        #expect(waterfall.moveLeft(from: 99, collapsed: []) == .none)
    }

    @Test("→ expands a closed span, else selects its first child; a leaf does nothing")
    func right() {
        #expect(waterfall.moveRight(from: index("root"), collapsed: ["root"]) == .expand(index("root")))
        #expect(waterfall.moveRight(from: index("root"), collapsed: []) == .select(index("auth")))
        #expect(waterfall.moveRight(from: index("charge"), collapsed: []) == .select(index("stripe")))
        #expect(waterfall.moveRight(from: index("stripe"), collapsed: []) == .none)
        #expect(waterfall.isExpanded(index("charge"), collapsed: []))
        #expect(!waterfall.isExpanded(index("save"), collapsed: []), "a leaf is never expanded")
    }

    @Test("Home, End and pages stay inside the list; an empty list does nothing")
    func listMoves() {
        #expect(ListMove.first.index(from: 7, count: 20) == 0)
        #expect(ListMove.last.index(from: 0, count: 20) == 19)
        #expect(ListMove.pageDown(10).index(from: 3, count: 20) == 13)
        #expect(ListMove.pageDown(10).index(from: 15, count: 20) == 19)
        #expect(ListMove.pageDown(10).index(from: nil, count: 20) == 9)
        #expect(ListMove.pageUp(10).index(from: 13, count: 20) == 3)
        #expect(ListMove.pageUp(10).index(from: 4, count: 20) == 0)
        #expect(ListMove.pageUp(0).index(from: 4, count: 20) == 3, "a page is at least a row")
        for move in [ListMove.first, .last, .pageUp(5), .pageDown(5)] {
            #expect(move.index(from: nil, count: 0) == nil)
        }
    }

    @Test("Tab goes sidebar → filter bar → list → waterfall → span detail, skipping what is hidden, and wraps")
    func tabOrder() {
        let all = Set(FocusColumn.allCases)
        #expect(FocusColumn.next(after: .sidebar, backward: false, available: all) == .filterBar)
        #expect(FocusColumn.next(after: .filterBar, backward: false, available: all) == .list)
        #expect(FocusColumn.next(after: .list, backward: false, available: all) == .waterfall)
        #expect(FocusColumn.next(after: .waterfall, backward: false, available: all) == .spanDetail)
        #expect(FocusColumn.next(after: .spanDetail, backward: false, available: all) == .sidebar)
        #expect(FocusColumn.next(after: .sidebar, backward: true, available: all) == .spanDetail)
        let noBar: Set<FocusColumn> = [.sidebar, .list, .waterfall]
        #expect(FocusColumn.next(after: .sidebar, backward: false, available: noBar) == .list)
        #expect(FocusColumn.next(after: .waterfall, backward: false, available: noBar) == .sidebar)
        #expect(FocusColumn.next(after: .list, backward: true, available: noBar) == .sidebar)
        #expect(FocusColumn.next(after: .list, backward: false, available: [.list]) == .list)
    }
}
