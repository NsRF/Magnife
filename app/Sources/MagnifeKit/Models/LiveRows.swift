import Foundation

// A live table's updates (S-030): the trace list is an NSTableView fed with
// one change per update, worked out here, and the updates are paced so new
// rows go in at most every 250 ms however fast the batches come
// (docs/ux.md, S-030 Flow). Pure, so the rules are unit-tested.

/// How a table goes from the rows it shows to new ones.
public enum RowUpdate: Equatable, Sendable {
    /// Same rows, same values: nothing to do.
    case none
    /// So many rows changed that reloading every row is cheaper than the steps.
    case reload
    /// Rows removed (indexes in the old rows), inserted (indexes in the new
    /// rows, applied after the removals) and changed in place (new indexes).
    case changes(removed: IndexSet, inserted: IndexSet, changed: IndexSet)

    /// True when rows come or go, not only change in place.
    public var movesRows: Bool {
        switch self {
        case .none: false
        case .reload: true
        case .changes(let removed, let inserted, _): !removed.isEmpty || !inserted.isEmpty
        }
    }

    /// Above this many inserted or removed rows the table reloads instead.
    public static let reloadThreshold = 1_000

    /// The update from `old` to `new`, rows matched by id. A row whose
    /// value differs (a span count, a status) is changed in place; a row
    /// that moved (its trace got an earlier root) is removed and inserted.
    public static func between<Row: Identifiable & Equatable>(_ old: [Row], _ new: [Row]) -> RowUpdate {
        if old == new { return .none }
        if old.isEmpty || new.isEmpty { return .reload }
        let oldIDs = old.map(\.id), newIDs = new.map(\.id)
        if oldIDs == newIDs {
            return .changes(removed: [], inserted: [], changed: IndexSet(new.indices.filter { old[$0] != new[$0] }))
        }
        // Few rows in common (another scope, a jump): steps would cost more than a reload.
        let common = Set(oldIDs).intersection(newIDs).count
        if (old.count - common) + (new.count - common) > reloadThreshold { return .reload }
        let difference = newIDs.difference(from: oldIDs)
        var removed = IndexSet(), inserted = IndexSet()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        // Rows kept, in order, pair up old and new indexes once the steps are taken out.
        let keptOld = IndexSet(old.indices).subtracting(removed)
        let keptNew = IndexSet(new.indices).subtracting(inserted)
        var changed = IndexSet()
        for (oldIndex, newIndex) in zip(keptOld, keptNew) where old[oldIndex] != new[newIndex] {
            changed.insert(newIndex)
        }
        return .changes(removed: removed, inserted: inserted, changed: changed)
    }
}

/// When a live table may take its next update: rows that come or go at
/// most every `interval` (250 ms), so a flood of batches never redraws the
/// list more often than people can follow it; changes in place, and any
/// update to or from an empty list (a new scope, the first page), at once.
public struct UpdatePacer: Sendable {
    public var interval: TimeInterval
    /// When rows last came or went.
    public private(set) var lastMove: TimeInterval?

    public init(interval: TimeInterval = 0.25) { self.interval = interval }

    /// Seconds to wait before applying `update` at `now` (0: apply now).
    /// `fromEmpty` / `toEmpty`: the table shows no rows, or will show none.
    public func delay(for update: RowUpdate, at now: TimeInterval, fromEmpty: Bool, toEmpty: Bool) -> TimeInterval {
        guard update.movesRows, !fromEmpty, !toEmpty, let lastMove else { return 0 }
        return max(0, lastMove + interval - now)
    }

    /// The update was applied at `now`.
    public mutating func applied(_ update: RowUpdate, at now: TimeInterval) {
        if update.movesRows { lastMove = now }
    }

    /// True when rows came or went within the last second: the list is
    /// under load, and rows go in without an animation (docs/ux.md, S-030 Access).
    public func isBusy(at now: TimeInterval) -> Bool {
        guard let lastMove else { return false }
        return now - lastMove < 1
    }
}

/// At most one change per `interval`: the subtitle's and the sidebar's
/// counts under load refresh at most once a second (docs/ux.md, S-030 States).
public struct Throttle: Sendable {
    public var interval: TimeInterval
    public private(set) var last: TimeInterval?

    public init(interval: TimeInterval = 1) { self.interval = interval }

    /// Seconds to wait before the next change at `now` (0: now).
    public func delay(at now: TimeInterval) -> TimeInterval {
        guard let last else { return 0 }
        return max(0, last + interval - now)
    }

    public mutating func fired(at now: TimeInterval) { last = now }
}
