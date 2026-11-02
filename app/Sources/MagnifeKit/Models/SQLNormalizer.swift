import Foundation

/// Turns a SQL statement into its shape, for N+1 (S-024): literals become
/// `?`, an IN list of values one `(?)`, repeated VALUES tuples one tuple,
/// comments go (so sqlcommenter's per-request `/*traceparent=…*/` never
/// splits a group), and runs of white space become one space. Identifiers,
/// quoted identifiers, keywords and bind placeholders (`$1`, `@p0`, `:id`,
/// `?`) stay as written, so different tables, columns or parameters never
/// group together. One pass over the UTF-8 bytes, no regular expressions.
public enum SQLNormalizer {
    /// Statements longer than this are normalized from their start (a
    /// generated statement can be megabytes); the result then ends in " …".
    public static let maxBytes = 10_000

    public static func normalize(_ statement: String) -> String {
        var bytes = Array(statement.utf8)
        let cut = bytes.count > maxBytes
        if cut { bytes.removeSubrange(maxBytes...) }
        var tokens = tokenize(bytes)
        tokens = collapseLists(tokens)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        for token in tokens {
            if token.space && !out.isEmpty { out.append(space) }
            out.append(contentsOf: token.text)
        }
        if cut { out.append(contentsOf: Array(" …".utf8)) }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: Tokens

    struct Token: Equatable {
        enum Kind { case word, literal, punct, quoted }
        var kind: Kind
        var text: [UInt8]
        /// White space (or a comment) came before it.
        var space: Bool

        /// A value or a bind placeholder: what an IN list or VALUES tuple holds.
        var isValue: Bool {
            if kind == .literal { return true }
            guard kind == .word || (kind == .punct && text == [question]), let first = text.first else { return false }
            return first == question || first == dollar || first == at || first == colon
        }

        func isPunct(_ byte: UInt8) -> Bool { kind == .punct && text == [byte] }

        func isWord(_ upper: String) -> Bool {
            kind == .word && text.count == upper.utf8.count
                && zip(text, upper.utf8).allSatisfy { ($0 >= 97 && $0 <= 122 ? $0 - 32 : $0) == $1 }
        }
    }

    private static let space = UInt8(ascii: " ")
    private static let question = UInt8(ascii: "?")
    private static let dollar = UInt8(ascii: "$")
    private static let at = UInt8(ascii: "@")
    private static let colon = UInt8(ascii: ":")
    private static let quote = UInt8(ascii: "'")
    private static let literal = Token(kind: .literal, text: [question], space: false)

    private static func isSpace(_ b: UInt8) -> Bool { b == 32 || (b >= 9 && b <= 13) }
    private static func isDigit(_ b: UInt8) -> Bool { b >= 48 && b <= 57 }
    /// Letters, digits, `_`, `$`, `@`, `:`, `#` and any non-ASCII byte.
    private static func isWordByte(_ b: UInt8) -> Bool {
        (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || isDigit(b) || b == 95 || b == dollar || b == at
            || b == colon || b == 35 || b >= 0x80
    }

    static func tokenize(_ b: [UInt8]) -> [Token] {
        var tokens: [Token] = []
        var i = 0
        var pendingSpace = false
        func push(_ kind: Token.Kind, _ range: Range<Int>) {
            tokens.append(Token(kind: kind, text: Array(b[range]), space: pendingSpace))
            pendingSpace = false
        }
        func pushLiteral() {
            var token = literal
            token.space = pendingSpace
            // A sign before a number is part of the value: "= -5" reads "= ?".
            if let last = tokens.last, last.isPunct(45) || last.isPunct(43) {
                let before = tokens.dropLast().last
                if before == nil || (before!.kind == .punct && !before!.isPunct(41)) {
                    token.space = last.space
                    tokens.removeLast()
                }
            }
            tokens.append(token)
            pendingSpace = false
        }
        while i < b.count {
            let c = b[i]
            if isSpace(c) {
                pendingSpace = true
                i += 1
            } else if c == 45, i + 1 < b.count, b[i + 1] == 45 {
                // -- comment, to the end of the line.
                while i < b.count, b[i] != 10 { i += 1 }
                pendingSpace = true
            } else if c == 47, i + 1 < b.count, b[i + 1] == 42 {
                // /* comment */
                i += 2
                while i < b.count, !(b[i] == 42 && i + 1 < b.count && b[i + 1] == 47) { i += 1 }
                i = min(b.count, i + 2)
                pendingSpace = true
            } else if c == quote {
                // 'string', with '' and \' inside; N'…', E'…', X'…', B'…' too.
                i += 1
                while i < b.count {
                    if b[i] == 92, i + 1 < b.count { i += 2; continue }
                    if b[i] == quote {
                        if i + 1 < b.count, b[i + 1] == quote { i += 2; continue }
                        break
                    }
                    i += 1
                }
                i = min(b.count, i + 1)
                if !pendingSpace, let last = tokens.last, last.kind == .word, last.text.count == 1,
                   [78, 110, 69, 101, 88, 120, 66, 98].contains(last.text[0]) {
                    pendingSpace = last.space
                    tokens.removeLast()
                }
                pushLiteral()
            } else if c == dollar, let end = dollarQuoteEnd(b, from: i) {
                // $$body$$ or $tag$body$tag$
                i = end
                pushLiteral()
            } else if isDigit(c) || (c == 46 && i + 1 < b.count && isDigit(b[i + 1])) {
                // 42, 4.2, .5, 1e-5, 0x1F
                i += 1
                while i < b.count {
                    let d = b[i]
                    if isDigit(d) || d == 46 || d == 95 || (d >= 65 && d <= 90) || (d >= 97 && d <= 122) {
                        i += 1
                    } else if (d == 43 || d == 45), b[i - 1] == 101 || b[i - 1] == 69 {
                        i += 1
                    } else {
                        break
                    }
                }
                pushLiteral()
            } else if c == 34 || c == 96 {
                // "Quoted" or `quoted` identifier, kept as written.
                let start = i
                i += 1
                while i < b.count {
                    if b[i] == c {
                        if i + 1 < b.count, b[i + 1] == c { i += 2; continue }
                        break
                    }
                    i += 1
                }
                i = min(b.count, i + 1)
                push(.quoted, start..<i)
            } else if isWordByte(c) {
                let start = i
                while i < b.count, isWordByte(b[i]) { i += 1 }
                push(.word, start..<i)
            } else {
                push(.punct, i..<(i + 1))
                i += 1
            }
        }
        return tokens
    }

    /// The end of a dollar-quoted string starting at `start`, or nil when
    /// the `$` begins a placeholder (`$1`) or nothing quoted.
    private static func dollarQuoteEnd(_ b: [UInt8], from start: Int) -> Int? {
        var i = start + 1
        while i < b.count, b[i] != dollar {
            let c = b[i]
            guard (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || (i > start + 1 && isDigit(c)) else { return nil }
            i += 1
        }
        guard i < b.count else { return nil }
        let tag = Array(b[start...i])
        var j = i + 1
        while j + tag.count <= b.count {
            if b[j] == dollar, Array(b[j..<(j + tag.count)]) == tag { return j + tag.count }
            j += 1
        }
        return nil
    }

    // MARK: Lists

    /// `IN (?, ?, ?)` reads `IN (?)`; `VALUES (?, ?), (?, ?)` keeps its first tuple.
    static func collapseLists(_ tokens: [Token]) -> [Token] {
        var out: [Token] = []
        out.reserveCapacity(tokens.count)
        var i = 0
        while i < tokens.count {
            if tokens[i].isPunct(40), let end = valueTupleEnd(tokens, from: i) {
                let afterIN = out.last?.isWord("IN") == true
                if afterIN {
                    var open = tokens[i]
                    open.text = [40]
                    var value = literal
                    value.space = tokens[i + 1].space
                    out.append(open)
                    out.append(value)
                    var close = tokens[end - 1]
                    close.space = false
                    out.append(close)
                } else {
                    out.append(contentsOf: tokens[i..<end])
                }
                i = end
                // More tuples of values after a tuple of values: dropped.
                while i < tokens.count, tokens[i].isPunct(44), i + 1 < tokens.count, tokens[i + 1].isPunct(40),
                      let next = valueTupleEnd(tokens, from: i + 1) {
                    i = next
                }
                continue
            }
            out.append(tokens[i])
            i += 1
        }
        return out
    }

    /// The index after `(` value (, value)* `)` starting at `open`, or nil.
    private static func valueTupleEnd(_ tokens: [Token], from open: Int) -> Int? {
        var i = open + 1
        guard i < tokens.count, tokens[i].isValue else { return nil }
        i += 1
        while i + 1 < tokens.count, tokens[i].isPunct(44), tokens[i + 1].isValue { i += 2 }
        guard i < tokens.count, tokens[i].isPunct(41) else { return nil }
        return i + 1
    }
}
