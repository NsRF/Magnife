import Foundation
import GRDB

/// The columns of a span the waterfall draws. No JSON columns, so a
/// 30,000-span trace reads and decodes quickly; the span detail reads the
/// full SpanRecord of the one selected span.
public struct WaterfallSpan: Sendable, Hashable, Identifiable, FetchableRecord {
    public var rowID: Int64
    public var spanID: String
    public var parentSpanID: String?
    public var name: String
    public var kind: SpanKind
    public var startNs: Int64
    public var durationNs: Int64
    public var status: SpanStatus
    public var serviceName: String
    /// `http_method` and `http_route`: where a finding is (`route`).
    public var httpMethod: String?
    public var httpRoute: String?

    public var id: String { spanID }
    public var endNs: Int64 { startNs + durationNs }

    /// The span's route the helper's way (docs/schema.sql, traces.route):
    /// "<method> <route>" when both exist, else the route, else the name. A
    /// server span named "GET" with `http.route` "/v1/orders/{id}" reads
    /// "GET /v1/orders/{id}".
    public var route: String {
        guard let route = httpRoute, !route.isEmpty else { return name }
        guard let method = httpMethod, !method.isEmpty else { return route }
        return "\(method) \(route)"
    }

    public init(rowID: Int64 = 0, spanID: String, parentSpanID: String? = nil, name: String,
                kind: SpanKind = .internal, startNs: Int64, durationNs: Int64,
                status: SpanStatus = .unset, serviceName: String, httpMethod: String? = nil, httpRoute: String? = nil) {
        self.rowID = rowID
        self.spanID = spanID
        self.parentSpanID = parentSpanID
        self.name = name
        self.kind = kind
        self.startNs = startNs
        self.durationNs = durationNs
        self.status = status
        self.serviceName = serviceName
        self.httpMethod = httpMethod
        self.httpRoute = httpRoute
    }

    public init(row: Row) throws {
        rowID = try row.decode(forColumn: "id")
        spanID = try row.decode(forColumn: "span_id")
        parentSpanID = try row.decode(forColumn: "parent_span_id")
        name = try row.decode(forColumn: "name")
        kind = SpanKind(code: try row.decode(forColumn: "kind"))
        startNs = try row.decode(forColumn: "start_ns")
        durationNs = try row.decode(forColumn: "duration_ns")
        status = SpanStatus(code: try row.decode(forColumn: "status_code"))
        serviceName = try row.decode(forColumn: "service_name")
        httpMethod = try row.decode(forColumn: "http_method")
        httpRoute = try row.decode(forColumn: "http_route")
    }
}

/// A trace's spans as a tree: children under their parent in start order,
/// spans whose parent never arrived at the root. Built off the main actor
/// (`build`) and rebuilt whole when more spans arrive, so a late span always
/// lands under its parent. Every walk is iterative: a trace can be one chain
/// 30,000 spans deep.
public struct Waterfall: Sendable {
    /// Traces with more spans than this open with deep subtrees collapsed
    /// (research/design.md, decision 7).
    public static let autoCollapseLimit = 500

    public struct Node: Sendable, Hashable {
        public var span: WaterfallSpan
        public var depth: Int
        /// Index of the parent node, nil at the root.
        public var parent: Int?
        public var children: [Int]
        /// The span names a parent this trace has not received.
        public var isOrphan: Bool
        /// Spans under this one, at any depth.
        public var descendantCount: Int
    }

    public private(set) var nodes: [Node] = []
    public private(set) var roots: [Int] = []
    public private(set) var startNs: Int64 = 0
    public private(set) var endNs: Int64 = 0
    public private(set) var maxDepth = 0
    /// Every span id that has children: Collapse All Spans, and the spans a
    /// collapsed set can hold.
    public private(set) var parentSpanIDs: Set<String> = []
    private var indexByID: [String: Int] = [:]

    public var count: Int { nodes.count }
    public var isEmpty: Bool { nodes.isEmpty }
    public var durationNs: Int64 { endNs - startNs }

    /// Builds the tree on a background thread.
    @concurrent
    public static func build(_ spans: [WaterfallSpan]) async -> Waterfall {
        Waterfall(spans: spans)
    }

    public init(spans: [WaterfallSpan] = []) {
        let sorted = spans.sorted { ($0.startNs, $0.rowID, $0.spanID) < ($1.startNs, $1.rowID, $1.spanID) }
        nodes.reserveCapacity(sorted.count)
        for (index, span) in sorted.enumerated() {
            indexByID[span.spanID] = index
            nodes.append(Node(span: span, depth: 0, parent: nil, children: [], isOrphan: false, descendantCount: 0))
        }
        guard !nodes.isEmpty else { return }
        startNs = sorted.map(\.startNs).min() ?? 0
        endNs = sorted.map(\.endNs).max() ?? startNs

        // Children in start order, because nodes are already sorted by start.
        var rootCandidates: [Int] = []
        for index in nodes.indices {
            let parentID = nodes[index].span.parentSpanID.flatMap { $0.isEmpty ? nil : $0 }
            if let parentID, let parent = indexByID[parentID], parent != index {
                nodes[index].parent = parent
                nodes[parent].children.append(index)
            } else {
                nodes[index].isOrphan = parentID != nil
                rootCandidates.append(index)
            }
        }
        var visited = [Bool](repeating: false, count: nodes.count)
        for root in rootCandidates { place(root, visited: &visited) }
        // Spans in a parent cycle are reachable from no root: each one left
        // over joins the root, as if its parent never arrived.
        for index in nodes.indices where !visited[index] {
            if let parent = nodes[index].parent { nodes[parent].children.removeAll { $0 == index } }
            nodes[index].parent = nil
            nodes[index].isOrphan = true
            rootCandidates.append(index)
            place(index, visited: &visited)
        }
        roots = rootCandidates.sorted()
        maxDepth = nodes.map(\.depth).max() ?? 0
        parentSpanIDs = Set(nodes.lazy.filter { !$0.children.isEmpty }.map(\.span.spanID))
    }

    /// Sets depths under `root` and counts descendants, without recursion.
    private mutating func place(_ root: Int, visited: inout [Bool]) {
        nodes[root].depth = 0
        visited[root] = true
        var order: [Int] = [root]
        var cursor = 0
        while cursor < order.count {
            let index = order[cursor]
            cursor += 1
            // A child already placed would be a second path into a cycle.
            nodes[index].children.removeAll { visited[$0] }
            for child in nodes[index].children {
                visited[child] = true
                nodes[child].depth = nodes[index].depth + 1
                order.append(child)
            }
        }
        for index in order.reversed() {
            nodes[index].descendantCount = nodes[index].children.reduce(0) { $0 + 1 + nodes[$1].descendantCount }
        }
    }

    public func index(of spanID: String) -> Int? { indexByID[spanID] }

    public func node(_ spanID: String) -> Node? { indexByID[spanID].map { nodes[$0] } }

    /// The span ids above a span, its parent first: what must be open for
    /// its row to show (S-012). Empty for a root or an unknown span.
    public func ancestors(of spanID: String) -> [String] {
        var out: [String] = []
        var index = indexByID[spanID]
        // At most one step per node, whatever the parents say.
        while let current = index, let parent = nodes[current].parent, out.count < nodes.count {
            out.append(nodes[parent].span.spanID)
            index = parent
        }
        return out
    }

    /// The span the waterfall selects when a trace opens: the first root that
    /// has no parent at all, else the first root.
    public var rootSpanID: String? {
        let root = roots.first { !nodes[$0].isOrphan } ?? roots.first
        return root.map { nodes[$0].span.spanID }
    }

    /// The span a failed trace opens on (S-027): the earliest-starting span
    /// with status Error, the first in tree order on a tie; nil without one.
    public var firstErrorSpanID: String? {
        var best: Node?
        for node in nodes where node.span.status == .error {
            if best.map({ node.span.startNs < $0.span.startNs }) ?? true { best = node }
        }
        return best?.span.spanID
    }

    /// The service of a node's parent, nil at the root.
    public func parentService(of index: Int) -> String? {
        nodes[index].parent.map { nodes[$0].span.serviceName }
    }

    /// Where the bar starts and how wide it is, as fractions of the trace.
    public func barFractions(of index: Int) -> (start: Double, width: Double) {
        let total = Double(max(1, durationNs))
        let span = nodes[index].span
        let start = Double(span.startNs - startNs) / total
        let width = Double(span.durationNs) / total
        return (min(max(start, 0), 1), min(max(width, 0), 1 - min(max(start, 0), 1)))
    }

    /// Spans that start collapsed: none up to `limit` spans. Above it, the
    /// tree opens level by level while the rows shown stay within `limit`,
    /// and every span with children below that level starts collapsed. The
    /// root's children always show.
    public func defaultCollapsed(limit: Int = Waterfall.autoCollapseLimit) -> Set<String> {
        guard nodes.count > limit else { return [] }
        var perDepth = [Int](repeating: 0, count: maxDepth + 1)
        for node in nodes { perDepth[node.depth] += 1 }
        var shown = 0
        var openDepth = 0
        for depth in perDepth.indices {
            shown += perDepth[depth]
            if shown > limit { break }
            openDepth = depth
        }
        openDepth = max(openDepth, 1)
        return Set(nodes.filter { $0.depth >= openDepth && !$0.children.isEmpty }.map(\.span.spanID))
    }

    /// The spans to collapse when this tree replaces `previous`, the same
    /// trace before more spans arrived, so a trace that grows past `limit`
    /// while it is open reads like one that opened that big (design decision
    /// 7). Crossing the limit, or with no previous tree (a trace that opens):
    /// `defaultCollapsed`. Already above it: only spans that became parents
    /// since, where `defaultCollapsed` would collapse them; spans that were
    /// parents before keep the state people gave them.
    public func autoCollapsed(after previous: Waterfall?, limit: Int = Waterfall.autoCollapseLimit) -> Set<String> {
        let collapsed = defaultCollapsed(limit: limit)
        guard let previous, previous.count > limit, !collapsed.isEmpty else { return collapsed }
        return collapsed.filter { !previous.parentSpanIDs.contains($0) }
    }

    /// The collapsed spans after a rebuild: spans that stopped having
    /// children cannot stay collapsed, and `added` (from `autoCollapsed`) joins.
    public func collapsed(keeping collapsed: Set<String>, adding added: Set<String>) -> Set<String> {
        collapsed.intersection(parentSpanIDs).union(added)
    }

    /// The rows on screen, in order, with `collapsed` subtrees closed.
    public func visibleRows(collapsed: Set<String>) -> [Int] {
        var rows: [Int] = []
        var stack = roots.reversed() as [Int]
        while let index = stack.popLast() {
            rows.append(index)
            if !collapsed.contains(nodes[index].span.spanID) { stack.append(contentsOf: nodes[index].children.reversed()) }
        }
        return rows
    }


    /// The service shown next to the name: only where it differs from the parent's.
    public func shownService(of index: Int) -> String? {
        let service = nodes[index].span.serviceName
        return parentService(of: index) == service ? nil : service
    }

    /// What VoiceOver reads for a row:
    /// "charge-card, payments, starts at 12 milliseconds, lasts 80 milliseconds, Error".
    public func accessibilityLabel(of index: Int) -> String {
        let span = nodes[index].span
        var parts = [span.name, span.serviceName,
                     "starts at \(DurationFormat.spoken(nanoseconds: span.startNs - startNs))",
                     "lasts \(DurationFormat.spoken(nanoseconds: span.durationNs))"]
        if span.status != .unset { parts.append(span.status.title) }
        if nodes[index].isOrphan { parts.append(Self.orphanHelp) }
        return parts.joined(separator: ", ")
    }

    /// The tooltip of a span whose parent never arrived (S-005).
    public static let orphanHelp = "Parent span not received"
}

extension TraceSummary {
    /// The waterfall header after the route: "checkout-api · 240 ms · 18 spans".
    public var waterfallSubtitle: String {
        [rootService, DurationFormat.string(nanoseconds: durationNs), TraceList.spansText(spanCount)]
            .joined(separator: " · ")
    }
}
