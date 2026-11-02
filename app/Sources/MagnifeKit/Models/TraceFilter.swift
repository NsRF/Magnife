import Foundation

// What narrows the trace list: the sidebar's service (S-009) and the
// filter bar's status chips (S-018), "Slower than" (S-019) and condition
// rows (S-020). Search (S-017) and saved filters (S-021) write the same
// value through the query language in TraceQuery.swift (docs/ux.md,
// "Search tokens"), so a query and the filter bar always mean one thing.

/// The trace list's filters. Every part must match (AND).
public struct TraceFilter: Sendable, Hashable {
    /// The sidebar's service, nil for all services (`service:`).
    public var service: String?
    /// The status chips that are on (`status:`). None on means every status.
    /// A trace's status is the helper's `traces.status`: Error when any span
    /// is Error, else its root span's status (docs/schema.sql).
    public var statuses: Set<SpanStatus>
    /// "Slower than", in nanoseconds (`>200ms`): traces that took longer.
    public var slowerThanNs: Int64?
    /// Condition rows (`key=value`, `route:`, free text). Rows with no key are ignored.
    public var conditions: [TraceCondition]

    public init(service: String? = nil, statuses: Set<SpanStatus> = [], slowerThanNs: Int64? = nil,
                conditions: [TraceCondition] = []) {
        self.service = service
        self.statuses = statuses
        self.slowerThanNs = slowerThanNs
        self.conditions = conditions
    }

    /// The conditions that take part: a row needs a key, and every operator
    /// but "exists" a value ("Any Field" and "Route" are keys).
    public var activeConditions: [TraceCondition] { conditions.filter(\.isActive) }

    /// The filter bar's own filters are on (status, duration, a condition):
    /// the list may hide traces of the scope ("312 of 1,204 traces").
    public var narrowsScope: Bool { !statuses.isEmpty || slowerThanNs != nil || !activeConditions.isEmpty }

    /// Any filter is on, the service included: Clear Filters has something to clear.
    public var isActive: Bool { service != nil || narrowsScope }

    /// The same filter without the sidebar's part.
    public var withoutService: TraceFilter {
        var next = self
        next.service = nil
        return next
    }

    /// A click on a status chip shows only that status; clicking the only
    /// chip on shows every status again. ⌘-click or Space (`adding`) turns
    /// one chip on or off and leaves the others (docs/ux.md, Filter bar).
    public func clicking(_ status: SpanStatus, adding: Bool) -> TraceFilter {
        var next = self
        if adding {
            if next.statuses.contains(status) { next.statuses.remove(status) } else { next.statuses.insert(status) }
        } else {
            next.statuses = statuses == [status] ? [] : [status]
        }
        return next
    }

    /// Clear Filters: every status, any duration, no condition, All Services.
    public static let cleared = TraceFilter()
}

/// One condition row of the filter bar (S-020), or a typed token.
public struct TraceCondition: Sendable, Hashable, Identifiable {
    /// What the row looks at.
    public enum Field: Sendable, Hashable {
        /// "Any Field": service, route, trace ID, span name and attribute values.
        case anyField
        /// "Route": the trace's route, as the list shows it.
        case route
        /// A span or resource attribute key, such as `http.route`.
        case attribute(String)

        /// The key field's text: "Any Field", "Route" or the key.
        public var title: String {
            switch self {
            case .anyField: "Any Field"
            case .route: "Route"
            case .attribute(let key): key
            }
        }

        /// The key typed or picked in the row: the built-in names first,
        /// whatever the case; anything else is an attribute key.
        public init(key: String) {
            let trimmed = key.trimmingCharacters(in: .whitespaces)
            switch trimmed.lowercased() {
            case "any field": self = .anyField
            case "route": self = .route
            default: self = .attribute(trimmed)
            }
        }

        /// The operators the field offers: "Any Field" only contains, "Route"
        /// has no "exists" (every trace has one) nor numbers.
        public var operators: [Operator] {
            switch self {
            case .anyField: [.contains]
            case .route: [.is, .isNot, .contains]
            case .attribute: Operator.allCases
            }
        }

        public var isEmpty: Bool { self == .attribute("") }
    }

    public enum Operator: String, Sendable, CaseIterable {
        case `is`, isNot, contains, exists, greater, less

        /// The operator pop-up's words (docs/ux.md, S-020).
        public var title: String {
            switch self {
            case .is: "is"
            case .isNot: "is not"
            case .contains: "contains"
            case .exists: "exists"
            case .greater: ">"
            case .less: "<"
            }
        }

        /// ">" and "<" compare numbers.
        public var isNumeric: Bool { self == .greater || self == .less }
    }

    public let id: UUID
    public var field: Field
    public var op: Operator
    public var value: String

    public init(id: UUID = UUID(), field: Field = .attribute(""), op: Operator = .is, value: String = "") {
        self.id = id
        self.field = field
        self.op = op
        self.value = value
    }

    /// Two conditions are the same filter when field, operator and value
    /// match; the row's id only keeps SwiftUI's rows apart.
    public static func == (lhs: TraceCondition, rhs: TraceCondition) -> Bool {
        lhs.field == rhs.field && lhs.op == rhs.op && lhs.value == rhs.value
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(field)
        hasher.combine(op)
        hasher.combine(value)
    }

    /// The value as matched: surrounding spaces do not count.
    public var trimmedValue: String { value.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The number ">" and "<" compare with; nil when the value is not one.
    public var number: Double? {
        guard op.isNumeric else { return nil }
        return Double(trimmedValue.replacingOccurrences(of: "_", with: ""))
    }

    /// The row takes part in the filter: it has a key, an operator the key
    /// offers, and a value unless it is "exists"; ">" and "<" need a number.
    public var isActive: Bool {
        guard !field.isEmpty, field.operators.contains(op) else { return false }
        if op == .exists { return true }
        if op.isNumeric { return number != nil }
        return !trimmedValue.isEmpty
    }

    /// What VoiceOver reads and the chips show: "http.route is /orders",
    /// "Any Field contains paymnt", "db.system exists".
    public var spokenText: String {
        op == .exists ? "\(field.title) exists" : "\(field.title) \(op.title) \(trimmedValue)"
    }
}

/// "Slower than" (S-019): what the field and the `>` token accept, and how
/// a value reads once it is understood.
public enum DurationInput {
    /// `200`, `200ms`, `>200ms`, `> 200 ms`, `1.5s`, `1.5 s`, `850us`,
    /// `850µs`: plain numbers are milliseconds. Nil when it does not parse,
    /// or is not above zero.
    public static func parse(_ text: String) -> Int64? {
        var rest = text.replacingOccurrences(of: " ", with: "").lowercased()
        if rest.hasPrefix(">") { rest.removeFirst() }
        guard !rest.isEmpty else { return nil }
        let units: [(String, Double)] = [("ms", 1_000_000), ("µs", 1_000), ("us", 1_000), ("ns", 1),
                                        ("s", 1_000_000_000)]
        var factor = 1_000_000.0
        for (unit, scale) in units where rest.hasSuffix(unit) {
            factor = scale
            rest.removeLast(unit.count)
            break
        }
        // Digits and one point only: no signs, exponents or "inf".
        guard !rest.isEmpty, rest.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              rest.filter({ $0 == "." }).count <= 1, rest != ".", let number = Double(rest) else { return nil }
        let ns = number * factor
        guard ns >= 1, ns < 9e18 else { return nil }
        return Int64(ns.rounded())
    }

    /// The value as the field shows it once focus leaves, and as the token
    /// writes it: "200 ms", "1.5 s", "850 µs".
    public static func normalized(_ ns: Int64) -> String {
        if ns < 1_000_000 { return "\(trimmed(Double(ns) / 1_000)) µs" }
        if ns < 1_000_000_000 { return "\(trimmed(Double(ns) / 1_000_000)) ms" }
        return "\(trimmed(Double(ns) / 1_000_000_000)) s"
    }

    /// The normalized value for VoiceOver: "200 milliseconds", "1.5 seconds", "1 second".
    public static func spoken(_ ns: Int64) -> String {
        let parts = normalized(ns).split(separator: " ").map(String.init)
        let words = ["µs": ("microsecond", "microseconds"), "ms": ("millisecond", "milliseconds"), "s": ("second", "seconds")]
        guard parts.count == 2, let unit = words[parts[1]] else { return normalized(ns) }
        return "\(parts[0]) \(parts[0] == "1" ? unit.0 : unit.1)"
    }

    /// The token form: ">200ms", ">1.5s" (no spaces, so it stays one token).
    public static func token(_ ns: Int64) -> String {
        ">" + normalized(ns).replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "µs", with: "us")
    }

    /// Up to three decimals, without trailing zeros: 1.5, 200, 0.25.
    private static func trimmed(_ value: Double) -> String {
        var text = String(format: "%.3f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// The field's error text (docs/ux.md, S-019).
    public static let errorText = "Type a duration, like 200 ms or 1.5 s"
}

extension SpanStatus {
    /// A status chip's tooltip (docs/ux.md, S-018), the rule `traces.status` follows.
    public var chipHelp: String {
        switch self {
        case .error: "Show traces with at least one Error span"
        case .ok: "Show traces with no Error span and an OK root span"
        case .unset: "Show traces with no Error span and an Unset or missing root span"
        }
    }

    /// The order of the chips: Error, OK, Unset.
    public static let chipOrder: [SpanStatus] = [.error, .ok, .unset]
}
