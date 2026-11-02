import Foundation

/// The span detail (S-006, S-007): one span with the resource it came from,
/// in the order of design decision 5: Exception, Attributes (`http.*` and
/// `db.*` first), Events, Resource. A section with nothing in it is left out.
/// The ordered lists are worked out once, where the detail is read (off the
/// main actor), so a view update never sorts thousands of attributes or events.
public struct SpanDetail: Sendable, Hashable {
    public let span: SpanRecord
    public let resource: ResourceRecord?
    /// The span's attributes, `http.*` then `db.*` then the rest, each by key.
    public let attributes: [Attribute]
    /// The span's exceptions in time order: one block each in Exception (S-007).
    public let exceptions: [SpanException]
    /// The span's other events in time order. Exception events show in
    /// Exception instead, so they are not listed twice.
    public let events: [SpanEvent]
    /// The resource's attributes, `service.*` first, then by key.
    public let resourceAttributes: [Attribute]
    /// The sections that have something in them, in order.
    public let sections: [Section]

    public init(span: SpanRecord, resource: ResourceRecord?) {
        self.span = span
        self.resource = resource
        attributes = Self.ordered(span.attributes.pairs, first: Self.attributePrefixes)
        // Every event in time order (the helper stores them that way; ties keep their order).
        let timeOrdered = span.events.enumerated()
            .sorted { ($0.element.timeNs, $0.offset) < ($1.element.timeNs, $1.offset) }.map(\.element)
        exceptions = timeOrdered.compactMap(\.exception)
        events = timeOrdered.filter { !$0.isException }
        resourceAttributes = Self.ordered(resource?.attributes.pairs ?? [], first: Self.resourcePrefixes)
        var sections: [Section] = []
        if !exceptions.isEmpty { sections.append(.exception) }
        if !attributes.isEmpty { sections.append(.attributes) }
        if !events.isEmpty { sections.append(.events) }
        if !resourceAttributes.isEmpty { sections.append(.resource) }
        self.sections = sections
    }

    public enum Section: String, Sendable, CaseIterable, Identifiable {
        case exception = "Exception"
        case attributes = "Attributes"
        case events = "Events"
        case resource = "Resource"

        public var id: String { rawValue }
        /// The section header on screen (docs/STORIES.md, S-006 and S-007 UX).
        public var title: String { rawValue }
    }

    /// Prefixes listed first in Attributes, in this order (design decision 5, as Jaeger does).
    public static let attributePrefixes = ["http.", "db."]
    /// Prefixes listed first in Resource: the service the span came from.
    public static let resourcePrefixes = ["service."]

    /// The stack trace Edit > Copy Stack Trace copies: the first exception's that has one.
    public var firstStackTrace: String? {
        exceptions.first { $0.hasStackTrace }?.stackTrace
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
