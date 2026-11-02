import Foundation

/// One attribute value, decoded from the JSON the helper stores (docs/schema.sql):
/// string, int, double, bool, array, kvlist (object), bytes (base64 string), empty (null).
public enum AttributeValue: Sendable, Hashable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case array([AttributeValue])
    case object([Attribute])
    case null

    /// The value as one line of text, the way the span detail shows it.
    public var text: String {
        switch self {
        case .string(let value): value
        case .int(let value): String(value)
        case .double(let value): value.formatted(.number.grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
        case .bool(let value): value ? "true" : "false"
        case .array(let values): "[" + values.map(\.quotedText).joined(separator: ", ") + "]"
        case .object(let pairs): "{" + pairs.map { "\($0.key): \($0.value.quotedText)" }.joined(separator: ", ") + "}"
        case .null: "null"
        }
    }

    /// Strings inside arrays and objects keep their quotes, like JSON.
    private var quotedText: String {
        if case .string(let value) = self { return "\"\(value)\"" }
        return text
    }

    public var string: String? { if case .string(let value) = self { value } else { nil } }
    public var int: Int64? { if case .int(let value) = self { value } else { nil } }
}

extension AttributeValue: Decodable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([AttributeValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode(Attributes.self).pairs)
        }
    }
}

/// One key and value.
public struct Attribute: Sendable, Hashable, Identifiable {
    public var key: String
    public var value: AttributeValue
    public var id: String { key }

    public init(_ key: String, _ value: AttributeValue) {
        self.key = key
        self.value = value
    }
}

/// A JSON object of attributes, sorted by key (order in the database is not significant).
public struct Attributes: Sendable, Hashable, Decodable {
    public var pairs: [Attribute]

    public init(_ pairs: [Attribute] = []) {
        self.pairs = pairs
    }

    public init(from decoder: any Decoder) throws {
        let object = try decoder.singleValueContainer().decode([String: AttributeValue].self)
        pairs = object.map { Attribute($0.key, $0.value) }.sorted { $0.key < $1.key }
    }

    /// Decodes a JSON column. A broken or empty column gives no attributes rather than an error.
    public init(json: String) {
        self = (try? JSONDecoder().decode(Attributes.self, from: Data(json.utf8))) ?? Attributes()
    }

    public subscript(key: String) -> AttributeValue? {
        pairs.first { $0.key == key }?.value
    }

    public var isEmpty: Bool { pairs.isEmpty }
    public var count: Int { pairs.count }
}
