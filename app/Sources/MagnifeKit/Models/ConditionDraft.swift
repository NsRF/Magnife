import Foundation

// The condition rows of the Traces filter bar (S-020) as typed: key text,
// operator and value. A row becomes a TraceCondition; rows with no key take
// no part (docs/ux.md, S-020 States).

/// One condition row while people edit it.
public struct ConditionDraft: Sendable, Hashable, Identifiable {
    public let id: UUID
    /// The key field as typed: "http.route", "Any Field", "Route".
    public var key: String
    public var op: TraceCondition.Operator
    public var value: String

    public init(id: UUID = UUID(), key: String = "", op: TraceCondition.Operator = .is, value: String = "") {
        self.id = id
        self.key = key
        self.op = op
        self.value = value
    }

    /// A row from a condition (Apply as Filter, a saved filter).
    public init(_ condition: TraceCondition) {
        self.init(id: condition.id, key: condition.field.title, op: condition.op, value: condition.value)
    }

    public var field: TraceCondition.Field { TraceCondition.Field(key: key) }

    /// The operators the key offers; Any Field only contains.
    public var operators: [TraceCondition.Operator] { field.operators }

    /// The operator in effect: the chosen one when the key offers it, else the key's first.
    public var effectiveOp: TraceCondition.Operator { operators.contains(op) ? op : operators[0] }

    /// What the row means, with the same id, so the list keeps its place.
    public var condition: TraceCondition {
        TraceCondition(id: id, field: field, op: effectiveOp, value: value)
    }

    /// "exists" has no value field.
    public var showsValue: Bool { effectiveOp != .exists }

    /// ">" and "<" with text that is no number: the row says "Type a number".
    public var needsNumber: Bool {
        effectiveOp.isNumeric && !condition.trimmedValue.isEmpty && condition.number == nil
    }

    /// What VoiceOver reads for the row: "Condition 1: http.route is /orders".
    public func spokenText(number: Int) -> String {
        let condition = condition
        guard !condition.field.isEmpty else { return "Condition \(number): no attribute" }
        return "Condition \(number): \(condition.spokenText)"
    }

    /// The rows the bar shows for `conditions`: one empty row when there are none.
    public static func rows(for conditions: [TraceCondition]) -> [ConditionDraft] {
        conditions.isEmpty ? [ConditionDraft()] : conditions.map(ConditionDraft.init)
    }

    /// At most this many rows; "+" is then disabled with "Up to 10 conditions".
    public static let limit = 10
    public static let limitHelp = "Up to 10 conditions"
    public static let numberError = "Type a number"
}

/// A key the key field can complete to: "http.route — span".
public struct ConditionKeySuggestion: Sendable, Hashable, Identifiable {
    public var key: String
    /// "span", "resource", or nil for the built-in keys.
    public var source: String?

    public var id: String { key + "\u{1F}" + (source ?? "") }

    /// The row's text: "http.route — span", "Any Field".
    public var title: String { source.map { "\(key) — \($0)" } ?? key }

    public init(key: String, source: String?) {
        self.key = key
        self.source = source
    }

    /// The built-in keys, offered first (docs/ux.md, S-020 Words).
    public static let builtIn = [ConditionKeySuggestion(key: "Any Field", source: nil),
                                 ConditionKeySuggestion(key: "Route", source: nil)]

    /// The suggestions for what is typed: the built-in keys, then received
    /// span and resource keys that start with it, then those that contain it,
    /// ignoring case; 20 at most. Log keys are not trace filters. A key
    /// typed in full offers nothing more.
    public static func suggestions(for typed: String, keys: [AttributeKey], limit: Int = 20) -> [ConditionKeySuggestion] {
        let text = typed.trimmingCharacters(in: .whitespaces).lowercased()
        let received = keys.filter { $0.source != .log }
            .sorted { ($0.key, $0.source.rawValue) < ($1.key, $1.source.rawValue) }
            .map { ConditionKeySuggestion(key: $0.key, source: $0.source == .span ? "span" : "resource") }
        let builtIn = builtIn.filter { text.isEmpty || $0.key.lowercased().contains(text) }
        let starts = received.filter { text.isEmpty || $0.key.lowercased().hasPrefix(text) }
        let contains = text.isEmpty ? [] : received.filter { !$0.key.lowercased().hasPrefix(text) && $0.key.lowercased().contains(text) }
        let all = builtIn + starts + contains
        // A key typed in full is done; typing on (".name") brings the rest back.
        if all.contains(where: { $0.key.lowercased() == text }) { return [] }
        return Array(all.prefix(limit))
    }
}
