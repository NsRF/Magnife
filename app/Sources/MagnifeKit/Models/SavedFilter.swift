import Foundation

// Saved filters (S-021): a name and a query in the language of
// TraceQuery.swift (docs/ux.md, "Search tokens": "A saved filter stores its
// query in this form"). The app owns them, so they live in UserDefaults,
// never in the database (PROGRESS decision 6), in the order created.

/// One saved filter: "Checkout errors" = `service:checkout-api status:error`.
public struct SavedFilter: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    /// The scope and filters, formatted by `TraceQuery.format`.
    public var query: String

    public init(id: UUID = UUID(), name: String, query: String) {
        self.id = id
        self.name = name
        self.query = query
    }

    public init(id: UUID = UUID(), name: String, filter: TraceFilter) {
        self.init(id: id, name: name, query: TraceQuery.format(filter))
    }

    /// The scope and filters the query means.
    public var filter: TraceFilter { TraceQuery(query).filter }

    /// The current filters differ from the saved ones: the title reads
    /// "Checkout errors — Edited". Compared as queries, so the order of
    /// chips and rows with no key never count as a change.
    public func isEdited(by current: TraceFilter) -> Bool {
        TraceQuery.format(current) != TraceQuery.format(filter)
    }

    /// The window title while it is selected.
    public func title(edited: Bool) -> String { edited ? "\(name) — Edited" : name }

    /// What VoiceOver reads for the sidebar row.
    public var spokenLabel: String { "\(name), saved filter" }
}

/// Every saved filter, in the order created, and the rules for names.
public struct SavedFilters: Sendable, Equatable {
    public static let defaultsKey = "savedFilters"

    public private(set) var items: [SavedFilter]

    public init(_ items: [SavedFilter] = []) { self.items = items }

    public subscript(id: SavedFilter.ID) -> SavedFilter? { items.first { $0.id == id } }

    public var isEmpty: Bool { items.isEmpty }

    /// Why a name cannot be used, for the sheet and for rename.
    public enum NameProblem: Sendable, Equatable {
        case empty
        case duplicate(String)

        /// Under the Name field. An empty name only disables Save.
        public var message: String? {
            switch self {
            case .empty: nil
            case .duplicate(let name): "A saved filter named “\(name)” already exists."
            }
        }
    }

    /// Names are trimmed; two filters cannot share one, ignoring case
    /// ("checkout errors" and "Checkout errors" would read the same in the sidebar).
    public static func cleaned(_ name: String) -> String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    public func problem(with name: String, renaming id: SavedFilter.ID? = nil) -> NameProblem? {
        let name = Self.cleaned(name)
        if name.isEmpty { return .empty }
        if let other = items.first(where: { $0.id != id && $0.name.compare(name, options: .caseInsensitive) == .orderedSame }) {
            return .duplicate(other.name)
        }
        return nil
    }

    /// Adds a filter at the end; nil when the name cannot be used.
    @discardableResult
    public mutating func add(name: String, filter: TraceFilter) -> SavedFilter? {
        guard problem(with: name) == nil else { return nil }
        let saved = SavedFilter(name: Self.cleaned(name), filter: filter)
        items.append(saved)
        return saved
    }

    /// Renames one filter; false when the name cannot be used or nothing changes.
    @discardableResult
    public mutating func rename(_ id: SavedFilter.ID, to name: String) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }), problem(with: name, renaming: id) == nil,
              items[index].name != Self.cleaned(name) else { return false }
        items[index].name = Self.cleaned(name)
        return true
    }

    /// Save Filter on an edited saved filter: it keeps the current filters.
    public mutating func update(_ id: SavedFilter.ID, filter: TraceFilter) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].query = TraceQuery.format(filter)
    }

    /// Removes one filter and says where it was, so Undo can put it back there.
    @discardableResult
    public mutating func remove(_ id: SavedFilter.ID) -> (filter: SavedFilter, index: Int)? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        return (items.remove(at: index), index)
    }

    /// Undo Delete Filter: back in its place.
    public mutating func insert(_ filter: SavedFilter, at index: Int) {
        guard self[filter.id] == nil else { return }
        items.insert(filter, at: min(max(index, 0), items.count))
    }

    // MARK: Defaults

    /// The stored filters, as JSON data; anything unreadable reads as none.
    public static func stored(in defaults: UserDefaults) -> SavedFilters {
        guard let data = defaults.data(forKey: defaultsKey),
              let items = try? JSONDecoder().decode([SavedFilter].self, from: data) else { return SavedFilters() }
        return SavedFilters(items)
    }

    public func store(in defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
