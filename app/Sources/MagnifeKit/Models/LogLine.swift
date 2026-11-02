import Foundation

/// One log as the span detail and Trace Logs show it (S-011, S-012): its
/// time ("14:02:31.204"), level word, body (JSON bodies pretty-printed) and
/// attributes by key. Built where the logs are read, off the main actor, so
/// a view update never re-indents a body or sorts attributes.
public struct LogLine: Sendable, Hashable, Identifiable {
    public let record: LogRecord
    /// "14:02:31.204", local time.
    public let time: String
    /// "14:02:31", what VoiceOver reads.
    public let spokenTime: String
    /// The body as shown: a JSON object or array re-indented, anything else as sent.
    public let body: String
    /// True when `body` is a pretty-printed JSON object or array.
    public let isStructured: Bool
    /// The log's attributes, by key.
    public let attributes: [Attribute]

    public var id: Int64 { record.id }
    public var level: SeverityLevel? { record.level }
    /// "ERROR"; "—" when the log set no level (severity 0, docs/ux.md S-014).
    public var levelWord: String { record.level?.title ?? Self.noLevel }

    public static let noLevel = "—"
    /// The tooltip of "—".
    public static let noLevelHelp = "No level set"

    public init(_ record: LogRecord, timeZone: TimeZone = .current) {
        self.record = record
        time = LogTime.string(nanoseconds: record.timeNs, timeZone: timeZone)
        spokenTime = LogTime.string(nanoseconds: record.timeNs, timeZone: timeZone, milliseconds: false)
        let pretty = LogBody.pretty(record.body)
        body = pretty ?? record.body
        isStructured = pretty != nil
        attributes = record.attributes.pairs.sorted { $0.key < $1.key }
    }

    /// What VoiceOver reads for one log: "14:02:31, ERROR, Payment declined
    /// for order 1182" (docs/ux.md, S-011), the body's first line only.
    public var accessibilityLabel: String {
        let firstLine = record.body.prefix { !$0.isNewline }
        return [spokenTime, record.level?.title ?? "no level", String(firstLine.prefix(200))]
            .filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// Log times as Magnife shows them: "14:02:31.204" in the Mac's time zone.
public enum LogTime {
    public static func string(nanoseconds: Int64, timeZone: TimeZone = .current, milliseconds: Bool = true) -> String {
        let (seconds, fraction) = nanoseconds.floorDivided(by: 1_000_000_000)
        let offset = Int64(timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(seconds))))
        let (_, ofDay) = (seconds + offset).floorDivided(by: 86_400)
        let day = Int(ofDay)
        let clock = String(format: "%02ld:%02ld:%02ld", day / 3_600, day / 60 % 60, day % 60)
        return milliseconds ? clock + String(format: ".%03ld", Int(fraction / 1_000_000)) : clock
    }
}

/// Structured log bodies: the helper stores a non-string body as compact
/// JSON (docs/schema.sql), and a string body may hold JSON too.
public enum LogBody {
    /// Larger bodies show as sent; "Show All" still shows all of it.
    public static let prettyLimit = 64_000

    /// The body re-indented two spaces per level when it is a JSON object or
    /// array, else nil. Key order, numbers and escapes stay exactly as sent:
    /// it re-indents tokens instead of decoding and encoding values.
    public static func pretty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.unicodeScalars.first, first == "{" || first == "[",
              trimmed.utf8.count <= prettyLimit,
              (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) != nil else { return nil }
        var out = String.UnicodeScalarView()
        var depth = 0
        var inString = false
        var escaped = false
        // After an opening bracket the line break waits, so "{}" and "[]" stay on one line.
        var opened = false
        func newline() {
            out.append("\n")
            out.append(contentsOf: String(repeating: "  ", count: depth).unicodeScalars)
        }
        for scalar in trimmed.unicodeScalars {
            if inString {
                out.append(scalar)
                if escaped { escaped = false } else if scalar == "\\" { escaped = true } else if scalar == "\"" { inString = false }
                continue
            }
            if scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" { continue }
            let closes = scalar == "}" || scalar == "]"
            if opened {
                opened = false
                if !closes { newline() }
            }
            switch scalar {
            case "{", "[":
                out.append(scalar)
                depth += 1
                opened = true
            case "}", "]":
                depth -= 1
                if out.last != "{" && out.last != "[" { newline() }
                out.append(scalar)
            case ",":
                out.append(scalar)
                newline()
            case ":":
                out.append(contentsOf: ": ".unicodeScalars)
            case "\"":
                out.append(scalar)
                inString = true
            default:
                out.append(scalar)
            }
        }
        return String(out)
    }
}

extension Int64 {
    /// Quotient and remainder rounded toward negative infinity, so times
    /// before 1970 still read as a time of day.
    func floorDivided(by divisor: Int64) -> (quotient: Int64, remainder: Int64) {
        let remainder = self % divisor
        return remainder < 0 ? (self / divisor - 1, remainder + divisor) : (self / divisor, remainder)
    }
}
