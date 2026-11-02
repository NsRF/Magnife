import Foundation

// The query language Search (S-017), the filter bar and saved filters share
// (docs/ux.md, "Search tokens"; design decision 2). A query parses into a
// TraceFilter, and a TraceFilter formats back into a query, so ⌘Return in
// Search and a saved filter set exactly what the filter bar shows.
//
//   service:checkout-api      the sidebar's service
//   status:error|ok|unset     status chips, case-insensitive; several add up
//   route:/orders             Route contains (route=, route!=, route~ too)
//   >200ms  >1.5s  >200       Slower than (plain numbers are milliseconds)
//   key=value key!=value key~value key>1 key<1   attribute is, is not, contains, >, <
//   has:key                   attribute exists
//   any other word, "quoted"  Any Field contains it
//
// Tokens combine with AND. Quotes keep spaces: route:"GET /items/{id}".

/// A parsed query: the filter it means, its tokens for the chips, and the
/// unfinished token the cursor is on, if any.
public struct TraceQuery: Sendable, Equatable {
    public var text: String
    public var filter: TraceFilter
    /// Every token that means a filter, in the order typed.
    public var tokens: [Token]
    /// The last token while it is still being typed (`status:`, `status:er`,
    /// `service:`, `has:`), for the suggestions; it filters nothing yet.
    public var unfinished: Unfinished?

    public struct Token: Sendable, Hashable {
        public enum Kind: Sendable, Hashable {
            case service(String)
            case status(SpanStatus)
            case slowerThan(Int64)
            case condition(TraceCondition)
        }

        public var kind: Kind
        /// The text typed for it.
        public var text: String

        /// A chip's words, read by VoiceOver after "Filter:": "status is
        /// Error", "service is orders", "slower than 200 ms", "http.route is /orders".
        public var spokenText: String {
            switch kind {
            case .service(let name): "service is \(name)"
            case .status(let status): "status is \(status.title)"
            case .slowerThan(let ns): "slower than \(DurationInput.normalized(ns))"
            case .condition(let condition): condition.spokenText
            }
        }
    }

    /// A token being typed at the end of the query.
    public struct Unfinished: Sendable, Hashable {
        public enum Prefix: String, Sendable, Hashable {
            case status, service, has
        }

        public var prefix: Prefix
        /// What is typed after the colon.
        public var partial: String
        /// Where the token starts in `text`, in characters.
        public var offset: Int

        /// The values to offer, among `candidates` (statuses, service names,
        /// attribute keys): those that start with what is typed, ignoring
        /// case, then those that contain it; none when one already matches exactly.
        public func suggestions(from candidates: [String], limit: Int = 20) -> [String] {
            let typed = partial.lowercased()
            if candidates.contains(where: { $0.lowercased() == typed }) { return [] }
            let starts = candidates.filter { $0.lowercased().hasPrefix(typed) }
            let contains = candidates.filter { !$0.lowercased().hasPrefix(typed) && $0.lowercased().contains(typed) }
            return Array((starts + contains).prefix(limit))
        }
    }

    /// The status values `status:` offers.
    public static let statusValues = ["error", "ok", "unset"]

    /// Parses a query. Never fails: text that is no token is free text.
    public init(_ text: String) {
        self.text = text
        var filter = TraceFilter()
        var tokens: [Token] = []
        var unfinished: Unfinished?
        let words = Self.split(text)
        var index = 0
        while index < words.count {
            var word = words[index]
            index += 1
            // ">200 ms": a number and its unit typed apart are one duration.
            if word.isDuration, index < words.count, Self.units.contains(words[index].plain.lowercased()),
               !word.plain.dropFirst().contains(where: \.isLetter) {
                word = Word(text: word.text + words[index].text, plain: word.plain + words[index].plain,
                            leadingQuoted: false, offset: word.offset, prefixLength: 0)
                index += 1
            }
            let isLast = index == words.count && !(text.last?.isWhitespace ?? true)
            switch Self.classify(word) {
            case .service(let name):
                filter.service = name
                tokens.removeAll { if case .service = $0.kind { true } else { false } }
                tokens.append(Token(kind: .service(name), text: word.text))
                // A full name can still be the start of a longer one.
                if isLast { unfinished = Unfinished(prefix: .service, partial: name, offset: word.offset) }
            case .status(let status):
                if !filter.statuses.contains(status) {
                    filter.statuses.insert(status)
                    tokens.append(Token(kind: .status(status), text: word.text))
                }
            case .slowerThan(let ns):
                filter.slowerThanNs = ns
                tokens.removeAll { if case .slowerThan = $0.kind { true } else { false } }
                tokens.append(Token(kind: .slowerThan(ns), text: word.text))
            case .condition(let condition):
                filter.conditions.append(condition)
                tokens.append(Token(kind: .condition(condition), text: word.text))
                if isLast, condition.op == .exists, case .attribute(let key) = condition.field {
                    unfinished = Unfinished(prefix: .has, partial: key, offset: word.offset)
                }
            case .incomplete(let prefix, let partial):
                if isLast { unfinished = Unfinished(prefix: prefix, partial: partial, offset: word.offset) }
            case .ignored:
                break
            }
        }
        self.filter = filter
        self.tokens = tokens
        self.unfinished = unfinished
    }

    /// The query with the unfinished token replaced by `value` and a space,
    /// so the next token can follow: "status:er" -> "status:error ".
    public func completing(with value: String) -> String {
        guard let unfinished else { return text }
        let start = text.index(text.startIndex, offsetBy: unfinished.offset)
        return String(text[..<start]) + "\(unfinished.prefix.rawValue):\(Self.quotedValue(value)) "
    }

    /// Words that look like a trace ID (8 or more hex digits, up to 32): a
    /// trace whose ID starts with one comes first (docs/ux.md, S-017).
    public var traceIDPrefixes: [String] {
        filter.conditions.compactMap { condition in
            guard condition.field == .anyField else { return nil }
            let word = condition.trimmedValue.lowercased()
            guard (8...32).contains(word.count), word.allSatisfy(\.isHexDigit) else { return nil }
            return word
        }
    }

    // MARK: Formatting

    /// The query a filter means, in the order the filter bar shows it:
    /// service, statuses, duration, conditions. Parsing it gives the same filter.
    public static func format(_ filter: TraceFilter) -> String {
        var parts: [String] = []
        if let service = filter.service { parts.append("service:\(quotedValue(service))") }
        for status in SpanStatus.chipOrder where filter.statuses.contains(status) {
            parts.append("status:\(status.title.lowercased())")
        }
        if let ns = filter.slowerThanNs { parts.append(DurationInput.token(ns)) }
        for condition in filter.activeConditions { parts.append(format(condition)) }
        return parts.joined(separator: " ")
    }

    static func format(_ condition: TraceCondition) -> String {
        let value = quotedValue(condition.trimmedValue)
        switch condition.field {
        case .anyField:
            // A word that would read as a token (or as nothing, like ">x") is quoted, so it stays free text.
            return quoted(condition.trimmedValue, always: TraceQuery(condition.trimmedValue).tokens.first?.kind
                          != .condition(TraceCondition(field: .anyField, op: .contains, value: condition.trimmedValue)))
        case .route:
            switch condition.op {
            case .is: return "route=\(value)"
            case .isNot: return "route!=\(value)"
            default: return "route:\(value)"
            }
        case .attribute(let name):
            // A key the bare form cannot carry ("_dd.p.tid", "app.kubernetes.io/name", spaces) is quoted.
            let key = isBareKey(name) ? name : quoted(name, always: true)
            switch condition.op {
            case .is: return "\(key)=\(value)"
            case .isNot: return "\(key)!=\(value)"
            case .contains: return "\(key)~\(value)"
            case .exists: return "has:\(quotedValue(name))"
            case .greater: return "\(key)>\(value)"
            case .less: return "\(key)<\(value)"
            }
        }
    }

    /// A key `key=value` can carry unquoted: letters, digits, `.`, `_` and
    /// `-`, starting with a letter, and not a built-in field's name.
    static func isBareKey(_ key: String) -> Bool {
        guard let first = key.first, first.isLetter,
              key.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }) else { return false }
        return TraceCondition.Field(key: key) == .attribute(key)
    }

    /// A value after a prefix or operator: quoted when it has spaces, quotes or backslashes.
    static func quotedValue(_ value: String) -> String {
        quoted(value, always: false)
    }

    private static func quoted(_ value: String, always: Bool) -> String {
        let needs = always || value.isEmpty || value.contains { $0.isWhitespace || $0 == "\"" || $0 == "\\" }
        guard needs else { return value }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: Parsing

    static let units: Set<String> = ["ms", "s", "us", "µs", "ns"]

    /// One whitespace-separated word: its text as typed, its text without
    /// quotes, whether it started with a quote, and where the quote began.
    struct Word {
        var text: String
        var plain: String
        var leadingQuoted: Bool
        var offset: Int
        /// Characters of `plain` before the first quoted part (the key and
        /// operator of `key="a b"`), or nil when nothing was quoted.
        var prefixLength: Int?
        /// Where the first quoted part closed, in `plain` and in `text`
        /// (`"_dd.p.tid"=abc`: a quoted key), or nil while it is open.
        var firstQuoteEnd: (plain: Int, text: Int)?

        var isDuration: Bool { !leadingQuoted && plain.hasPrefix(">") }

        /// The part before any quote: where prefixes and operators are read.
        var unquotedPrefix: String {
            prefixLength.map { String(plain.prefix($0)) } ?? plain
        }
    }

    /// Splits on whitespace outside quotes; a backslash in quotes escapes the next character.
    static func split(_ text: String) -> [Word] {
        var words: [Word] = []
        var current: Word?
        var inQuote = false
        var escaped = false
        for (offset, char) in text.enumerated() {
            if !inQuote, char.isWhitespace {
                if let word = current { words.append(word) }
                current = nil
                continue
            }
            if current == nil {
                current = Word(text: "", plain: "", leadingQuoted: char == "\"", offset: offset, prefixLength: nil)
            }
            current!.text.append(char)
            if escaped {
                current!.plain.append(char)
                escaped = false
            } else if inQuote && char == "\\" {
                escaped = true
            } else if char == "\"" {
                if !inQuote, current!.prefixLength == nil { current!.prefixLength = current!.plain.count }
                if inQuote, current!.firstQuoteEnd == nil {
                    current!.firstQuoteEnd = (current!.plain.count, current!.text.count)
                }
                inQuote.toggle()
            } else {
                current!.plain.append(char)
            }
        }
        if let word = current { words.append(word) }
        return words
    }

    enum Classified {
        case service(String)
        case status(SpanStatus)
        case slowerThan(Int64)
        case condition(TraceCondition)
        case incomplete(Unfinished.Prefix, String)
        case ignored
    }

    /// What one word means.
    static func classify(_ word: Word) -> Classified {
        let anyField = Classified.condition(TraceCondition(field: .anyField, op: .contains, value: word.plain))
        if word.leadingQuoted {
            if let condition = quotedKeyCondition(word), condition.isActive { return .condition(condition) }
            return word.plain.isEmpty ? .ignored : anyField
        }
        if word.isDuration {
            // A duration still being typed (">", ">100m") filters nothing yet.
            return DurationInput.parse(word.plain).map { .slowerThan($0) } ?? .ignored
        }
        let head = word.unquotedPrefix
        let lower = head.lowercased()
        for prefix in ["service:", "status:", "route:", "has:"] where lower.hasPrefix(prefix) {
            let value = String(word.plain.dropFirst(prefix.count))
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            switch prefix {
            case "service:":
                return trimmed.isEmpty ? .incomplete(.service, "") : .service(trimmed)
            case "status:":
                switch trimmed.lowercased() {
                case "error": return .status(.error)
                case "ok": return .status(.ok)
                case "unset": return .status(.unset)
                default: return .incomplete(.status, trimmed)
                }
            case "route:":
                return trimmed.isEmpty ? .ignored : .condition(TraceCondition(field: .route, op: .contains, value: trimmed))
            default:
                return trimmed.isEmpty ? .incomplete(.has, "")
                    : .condition(TraceCondition(field: .attribute(trimmed), op: .exists))
            }
        }
        // "a>b" is no comparison (">" needs a number): it stays free text.
        if let condition = attributeCondition(word), condition.isActive { return .condition(condition) }
        return anyField
    }

    /// `"key"=value` and the other operators after a quoted key: always an
    /// attribute, whatever the key holds.
    static func quotedKeyCondition(_ word: Word) -> TraceCondition? {
        guard let end = word.firstQuoteEnd, end.plain > 0 else { return nil }
        let after = word.text.dropFirst(end.text)
        guard let (symbol, op) = attributeOperators.first(where: { after.hasPrefix($0.0) }) else { return nil }
        let value = String(word.plain.dropFirst(end.plain + symbol.count))
        guard !value.isEmpty else { return nil }
        return TraceCondition(field: .attribute(String(word.plain.prefix(end.plain))), op: op, value: value)
    }

    /// The operators after a key, longest first where they share a start.
    static let attributeOperators: [(String, TraceCondition.Operator)] = [("!=", .isNot), ("=", .is), ("~", .contains),
                                                                         (">", .greater), ("<", .less)]

    /// `key=value`, `key!=value`, `key~value`, `key>1`, `key<1`; `route`
    /// as the key means the built-in Route. The key is letters, digits,
    /// `.`, `_` and `-`, starting with a letter, so URLs stay free text.
    static func attributeCondition(_ word: Word) -> TraceCondition? {
        let head = word.unquotedPrefix
        guard let (range, op) = attributeOperators.compactMap({ symbol, op in head.range(of: symbol).map { ($0, op) } })
            .min(by: { $0.0.lowerBound < $1.0.lowerBound }) else { return nil }
        let key = String(head[..<range.lowerBound])
        guard let first = key.first, first.isLetter, key.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) })
        else { return nil }
        let keyLength = head.distance(from: head.startIndex, to: range.upperBound)
        let value = String(word.plain.dropFirst(keyLength))
        guard !value.isEmpty else { return nil }
        let field = TraceCondition.Field(key: key)
        // Route offers is, is not and contains only.
        guard field.operators.contains(op) else { return nil }
        return TraceCondition(field: field, op: op, value: value)
    }
}
