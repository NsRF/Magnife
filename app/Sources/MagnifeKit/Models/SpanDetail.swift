import Foundation

/// The span detail (S-006): one span with the resource it came from, in
/// the order of design decision 5: Attributes (`http.*` and `db.*` first),
/// Events, Resource. A section with nothing in it is left out.
public struct SpanDetail: Sendable, Hashable {
    public var span: SpanRecord
    public var resource: ResourceRecord?

    public init(span: SpanRecord, resource: ResourceRecord?) {
        self.span = span
        self.resource = resource
    }

    public enum Section: String, Sendable, CaseIterable, Identifiable {
        case attributes = "Attributes"
        case events = "Events"
        case resource = "Resource"

        public var id: String { rawValue }
        /// The section header on screen (docs/STORIES.md, S-006 UX).
        public var title: String { rawValue }
    }

    /// The sections that have something in them, in order.
    public var sections: [Section] {
        Section.allCases.filter { section in
            switch section {
            case .attributes: !attributes.isEmpty
            case .events: !events.isEmpty
            case .resource: !resourceAttributes.isEmpty
            }
        }
    }

    /// Prefixes listed first in Attributes, in this order (design decision 5, as Jaeger does).
    public static let attributePrefixes = ["http.", "db."]
    /// Prefixes listed first in Resource: the service the span came from.
    public static let resourcePrefixes = ["service."]

    /// The span's attributes, `http.*` then `db.*` then the rest, each by key.
    public var attributes: [Attribute] {
        Self.ordered(span.attributes.pairs, first: Self.attributePrefixes)
    }

    /// The span's events in time order (the helper stores them that way; ties keep their order).
    public var events: [SpanEvent] {
        span.events.enumerated().sorted { ($0.element.timeNs, $0.offset) < ($1.element.timeNs, $1.offset) }.map(\.element)
    }

    /// The resource's attributes, `service.*` first, then by key.
    public var resourceAttributes: [Attribute] {
        Self.ordered(resource?.attributes.pairs ?? [], first: Self.resourcePrefixes)
    }

    /// The line under the span name: kind, duration and status ("Server · 52 ms · Error").
    public var summary: String {
        [span.kind.title, DurationFormat.string(nanoseconds: span.durationNs), span.status.title].joined(separator: " · ")
    }

    /// When something happened during the span, from its start ("at 12 ms").
    /// A time before the start (clock skew between hosts) reads as a negative offset.
    public func offsetText(_ timeNs: Int64) -> String {
        let offset = timeNs - span.startNs
        let text = DurationFormat.string(nanoseconds: abs(offset))
        return offset < 0 ? "at −\(text)" : "at \(text)"
    }

    /// Pairs whose key starts with one of `prefixes` come first, in the
    /// order of the prefixes; within each group, by key.
    public static func ordered(_ pairs: [Attribute], first prefixes: [String]) -> [Attribute] {
        func group(_ key: String) -> Int { prefixes.firstIndex { key.hasPrefix($0) } ?? prefixes.count }
        return pairs.sorted { (group($0.key), $0.key) < (group($1.key), $1.key) }
    }

    /// What VoiceOver reads for one attribute: "key, value".
    public static func accessibilityLabel(_ attribute: Attribute) -> String {
        "\(attribute.key), \(attribute.value.text)"
    }
}
