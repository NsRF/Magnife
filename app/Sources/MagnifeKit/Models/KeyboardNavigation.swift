import Foundation

// Keyboard navigation (S-022, docs/ux.md "Keyboard map"): what an arrow key
// does on a waterfall row, where Home, End and Page Up / Page Down land in
// a list, and which column Tab moves to. The views only send the keys here.

/// What ← or → does on the selected waterfall row.
public enum WaterfallMove: Sendable, Equatable {
    case collapse(Int)
    case expand(Int)
    case select(Int)
    case none
}

extension Waterfall {
    /// The span has children and they show.
    public func isExpanded(_ index: Int, collapsed: Set<String>) -> Bool {
        !nodes[index].children.isEmpty && !collapsed.contains(nodes[index].span.spanID)
    }

    /// ←: collapse the span, or select its parent.
    public func moveLeft(from index: Int, collapsed: Set<String>) -> WaterfallMove {
        guard nodes.indices.contains(index) else { return .none }
        if isExpanded(index, collapsed: collapsed) { return .collapse(index) }
        return nodes[index].parent.map { .select($0) } ?? .none
    }

    /// →: expand the span, or select its first child.
    public func moveRight(from index: Int, collapsed: Set<String>) -> WaterfallMove {
        guard nodes.indices.contains(index), let first = nodes[index].children.first else { return .none }
        return isExpanded(index, collapsed: collapsed) ? .select(first) : .expand(index)
    }
}

/// Home, End (⌘↑, ⌘↓), Page Up and Page Down in a list of rows, newest first.
public enum ListMove: Sendable, Equatable {
    case first
    case last
    case pageUp(Int)
    case pageDown(Int)

    /// The row to select from `current` in `count` rows; nil on an empty list
    /// (keys on an empty list do nothing). A page is at least one row.
    public func index(from current: Int?, count: Int) -> Int? {
        guard count > 0 else { return nil }
        switch self {
        case .first: return 0
        case .last: return count - 1
        case .pageUp(let rows): return max(0, (current ?? 0) - max(rows, 1))
        case .pageDown(let rows): return min(count - 1, (current ?? -1) + max(rows, 1))
        }
    }
}

/// The window's columns in Tab order: sidebar → filter bar (when shown) →
/// list → waterfall → span detail (docs/ux.md, Keyboard map).
public enum FocusColumn: Sendable, CaseIterable, Hashable {
    case sidebar, filterBar, list, waterfall, spanDetail

    /// Tab (or ⇧Tab) from `column`, among the columns that show; it wraps around.
    public static func next(after column: FocusColumn, backward: Bool, available: Set<FocusColumn>) -> FocusColumn {
        let order = allCases.filter { available.contains($0) || $0 == column }
        guard let index = order.firstIndex(of: column), order.count > 1 else { return column }
        let step = backward ? order.count - 1 : 1
        return order[(index + step) % order.count]
    }
}
