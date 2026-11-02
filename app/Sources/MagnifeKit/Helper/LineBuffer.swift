import Foundation

/// Splits pipe chunks into complete lines. A chunk can end mid-line or hold
/// several lines; the rest waits for the next chunk. Accepts LF and CRLF.
public struct LineBuffer: Sendable {
    private var pending = Data()
    /// A line longer than this is dropped rather than growing without bound.
    public let maxLineLength: Int

    public init(maxLineLength: Int = 16 * 1024 * 1024) {
        self.maxLineLength = maxLineLength
    }

    /// The complete lines in `chunk` plus what was pending, without their
    /// line breaks. Empty lines are skipped.
    public mutating func append(_ chunk: Data) -> [String] {
        pending.append(chunk)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            var line = pending[pending.startIndex..<newline]
            if line.last == 0x0D { line = line.dropLast() }
            pending = Data(pending[pending.index(after: newline)...])
            if !line.isEmpty { lines.append(String(decoding: line, as: UTF8.self)) }
        }
        if pending.count > maxLineLength { pending = Data() }
        return lines
    }

    /// What is left when the pipe closes: a last line with no line break.
    public mutating func finish() -> [String] {
        defer { pending = Data() }
        var line = pending
        if line.last == 0x0D { line = line.dropLast() }
        return line.isEmpty ? [] : [String(decoding: line, as: UTF8.self)]
    }
}

/// A stdout line, decoded.
public enum HelperLine: Sendable, Equatable {
    case event(HelperEvent)
    /// Not JSON, or not a protocol object. Reported, never fatal.
    case malformed(line: String, reason: String)

    public init(_ line: String) {
        do {
            self = .event(try HelperEvent.decode(line: line))
        } catch DecodingError.dataCorrupted {
            self = .malformed(line: line, reason: "not JSON")
        } catch {
            self = .malformed(line: line, reason: "not a protocol object")
        }
    }
}
