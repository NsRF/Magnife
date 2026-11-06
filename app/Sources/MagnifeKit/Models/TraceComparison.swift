import Foundation
import GRDB

/// The columns of a span a comparison reads (S-036): the waterfall's, and
/// the URL and statement that title and key it. No JSON columns, so two
/// 30,000-span traces read quickly.
public struct ComparisonSpan: Sendable, Hashable, FetchableRecord {
    public var span: WaterfallSpan
    public var httpURL: String?
    public var dbStatement: String?

    public init(_ span: WaterfallSpan, httpURL: String? = nil, dbStatement: String? = nil) {
        self.span = span
        self.httpURL = httpURL
        self.dbStatement = dbStatement
    }

    public init(row: Row) throws {
        span = try WaterfallSpan(row: row)
        httpURL = try row.decode(forColumn: "http_url")
        dbStatement = try row.decode(forColumn: "db_statement")
    }
}

/// Both traces of a comparison from one read: their rows (nil once pruned)
/// and their spans.
public struct ComparisonRead: Sendable {
    public var traceA: TraceSummary?
    public var traceB: TraceSummary?
    public var spansA: [ComparisonSpan]
    public var spansB: [ComparisonSpan]

    public init(traceA: TraceSummary?, traceB: TraceSummary?, spansA: [ComparisonSpan], spansB: [ComparisonSpan]) {
        self.traceA = traceA
        self.traceB = traceB
        self.spansA = spansA
        self.spansB = spansB
    }
}

/// Two traces matched span by span (S-036, docs/ux.md). Span ids never
/// match between traces, so spans match by where they sit and what they
/// are: under a matched pair, the i-th child with a key pairs with the i-th
/// child with that key on the other side. A key that runs 2 or more times on
/// either side is one group row. What is left is New (only in B) or Missing
/// (only in A), with its whole subtree. Changes read B against A. Every walk
/// is iterative: a trace can be one chain 30,000 spans deep.
public struct TraceComparison: Sendable {
    /// Slower or Faster takes over this much and over `relativeLimit` of A.
    public static let absoluteLimitNs: Int64 = 1_000_000
    public static let relativeLimit = 0.2
    /// Under this share of the spans matched, the traces have little in common.
    public static let commonLimit = 0.2

    public enum Change: Sendable, Hashable {
        case same, slower, faster, repeated, new, missing
    }

    /// One row of the merged tree: a pair, a group of runs, or a span only
    /// one trace has.
    public struct Row: Sendable, Hashable, Identifiable {
        /// Stable across rebuilds of the same two traces: from the parent's
        /// id, the key and the occurrence, so selection and collapsed rows
        /// survive a live re-read.
        public var id: Int
        public var title: String
        public var service: String
        public var kind: SpanKind
        /// Node indexes in `treeA` / `treeB`, in start order.
        public var a: [Int]
        public var b: [Int]
        public var isGroup: Bool
        public var parent: Int?
        public var children: [Int] = []
        public var depth: Int
        public var aDurationNs: Int64 = 0
        public var bDurationNs: Int64 = 0
        public var aSelfNs: Int64 = 0
        public var bSelfNs: Int64 = 0
        /// The shortest and longest run of a group, per side.
        public var aRunRange: ClosedRange<Int64>?
        public var bRunRange: ClosedRange<Int64>?
        /// Error when any span of the row has status Error, else the first span's.
        public var aStatus: SpanStatus?
        public var bStatus: SpanStatus?
        /// Where the row's spans run, in nanoseconds from each trace's start.
        public var aRange: ClosedRange<Int64>?
        public var bRange: ClosedRange<Int64>?
        public var change: Change = .same
        /// One side has status Error and the other does not.
        public var statusChanged = false
        /// A difference somewhere under this row.
        public var differsBelow = false
        /// Rows under this one, at any depth.
        public var descendantCount = 0
        /// Spans in this row's subtree, on both sides (a group counts its runs once).
        public var subtreeSpans = 0

        public var isOneSided: Bool { a.isEmpty || b.isEmpty }
        public var differs: Bool { change != .same || statusChanged }
        public var aRuns: Int { a.count }
        public var bRuns: Int { b.count }
    }

    /// One strip line (docs/ux.md, S-036).
    public struct Difference: Sendable, Hashable {
        public enum Kind: Sendable, Hashable { case error, slower, faster, repeated, new, missing }
        public var kind: Kind
        public var row: Int
        /// The time it explains: B less A for Slower, Faster and Repeated
        /// (self time for Slower and Faster), the subtree's duration for New
        /// and Missing, B's duration for Error.
        public var ns: Int64
    }

    /// One normalized statement of one service, in both traces.
    public struct Query: Sendable, Hashable {
        public var service: String
        public var statement: String
        public var aRuns: Int
        public var bRuns: Int
        public var aNs: Int64
        public var bNs: Int64
    }

    public private(set) var traceA: TraceSummary?
    public private(set) var traceB: TraceSummary?
    public private(set) var treeA: Waterfall
    public private(set) var treeB: Waterfall
    public private(set) var rows: [Row] = []
    public private(set) var roots: [Int] = []
    public private(set) var differences: [Difference] = []
    public private(set) var queries: [Query] = []
    /// Rows that pair one span of A with one of B, and every row that is not a group.
    public private(set) var matchedSpans = 0
    public private(set) var comparedSpans = 0
    private var indexByID: [Int: Int] = [:]
    /// Per node of each tree: its title, key, self time and normalized statement.
    private var spansA: [ComparisonSpan] = []
    private var spansB: [ComparisonSpan] = []

    public var isEmpty: Bool { rows.isEmpty }
    public var count: Int { rows.count }
    /// The longer trace's duration: the Timeline's scale.
    public var scaleNs: Int64 { max(1, treeA.durationNs, treeB.durationNs) }
    public var hasLittleInCommon: Bool {
        comparedSpans > 0 && Double(matchedSpans) / Double(comparedSpans) < Self.commonLimit
    }

    /// Builds the comparison on a background thread.
    @concurrent
    public static func build(_ read: ComparisonRead) async -> TraceComparison {
        TraceComparison(read)
    }

    public init(_ read: ComparisonRead) {
        self.init(traceA: read.traceA, spansA: read.spansA, traceB: read.traceB, spansB: read.spansB)
    }

    public init(traceA: TraceSummary? = nil, spansA: [ComparisonSpan], traceB: TraceSummary? = nil, spansB: [ComparisonSpan]) {
        self.traceA = traceA
        self.traceB = traceB
        let a = Prepared(spansA)
        let b = Prepared(spansB)
        treeA = a.tree
        treeB = b.tree
        self.spansA = a.spans
        self.spansB = b.spans
        match(a, b)
        summarize()
        differences = Self.differences(in: rows)
        queries = Self.queries(a, b)
    }

    public func row(id: Int) -> Row? { indexByID[id].map { rows[$0] } }
    public func index(ofRow id: Int) -> Int? { indexByID[id] }

    /// The span of side `a` or `b` behind a row: its first run.
    public func spanID(of index: Int, inA: Bool) -> String? {
        let row = rows[index]
        guard let node = (inA ? row.a : row.b).first else { return nil }
        return (inA ? treeA : treeB).nodes[node].span.spanID
    }

    /// The row of one span of A or B, for a selection that came from a span.
    public func row(ofSpan spanID: String, inA: Bool) -> Int? {
        guard let node = (inA ? treeA : treeB).index(of: spanID) else { return nil }
        return rows.firstIndex { !$0.isGroup && (inA ? $0.a : $0.b).first == node }
    }

    // MARK: Prepared trees

    /// One trace's tree with, per node, its title, key and self time.
    struct Prepared {
        var tree: Waterfall
        /// Index-aligned with `tree.nodes` (both sorted the same way).
        var spans: [ComparisonSpan]
        var titles: [String]
        var keys: [String]
        var statements: [String]
        var selfNs: [Int64]

        init(_ input: [ComparisonSpan]) {
            spans = input.sorted { ($0.span.startNs, $0.span.rowID, $0.span.spanID) < ($1.span.startNs, $1.span.rowID, $1.span.spanID) }
            tree = Waterfall(spans: spans.map(\.span))
            titles = spans.map(TraceComparison.title)
            statements = spans.map { span in
                guard let statement = span.dbStatement, !statement.isEmpty else { return "" }
                return SQLNormalizer.normalize(statement)
            }
            var keys: [String] = []
            keys.reserveCapacity(spans.count)
            for index in spans.indices {
                let span = spans[index].span
                keys.append([span.serviceName, String(span.kind.rawValue),
                             TraceComparison.normalizedName(titles[index]), statements[index]].joined(separator: "\u{1}"))
            }
            self.keys = keys
            selfNs = TraceComparison.selfTimes(tree)
        }
    }

    /// Each node's duration less the union of its children's intervals,
    /// clipped to the span (children are in start order).
    static func selfTimes(_ tree: Waterfall) -> [Int64] {
        tree.nodes.map { node in
            let start = node.span.startNs
            let end = node.span.endNs
            var cursor = start
            var covered: Int64 = 0
            for child in node.children {
                let span = tree.nodes[child].span
                let from = max(span.startNs, cursor)
                let to = min(span.endNs, end)
                if to > from {
                    covered += to - from
                    cursor = to
                }
            }
            return max(0, node.span.durationNs - covered)
        }
    }

    // MARK: Matching

    private struct Job {
        var a: [Int]
        var b: [Int]
        var parent: Int?
        var depth: Int
    }

    private mutating func match(_ a: Prepared, _ b: Prepared) {
        var jobs: [Job] = []
        if a.tree.roots.count == 1, b.tree.roots.count == 1 {
            // One root on each side always match: a renamed route still lines up.
            let root = addRow(a: [a.tree.roots[0]], b: [b.tree.roots[0]], isGroup: false, key: a.keys[a.tree.roots[0]],
                              occurrence: 0, parent: nil, depth: 0, a, b)
            jobs.append(Job(a: a.tree.nodes[a.tree.roots[0]].children, b: b.tree.nodes[b.tree.roots[0]].children,
                            parent: root, depth: 1))
        } else {
            jobs.append(Job(a: a.tree.roots, b: b.tree.roots, parent: nil, depth: 0))
        }
        var cursor = 0
        while cursor < jobs.count {
            let job = jobs[cursor]
            cursor += 1
            for (pairA, pairB, row) in matchSet(job, a, b) {
                let childrenA = pairA.map { a.tree.nodes[$0].children } ?? []
                let childrenB = pairB.map { b.tree.nodes[$0].children } ?? []
                if !childrenA.isEmpty || !childrenB.isEmpty {
                    jobs.append(Job(a: childrenA, b: childrenB, parent: row, depth: rows[row].depth + 1))
                }
            }
            // Jobs already run are not needed again.
            if cursor > 4_096 {
                jobs.removeFirst(cursor)
                cursor = 0
            }
        }
    }

    /// Groups one set of siblings by key and adds their rows; answers the
    /// pairs and one-sided spans whose children match next.
    private mutating func matchSet(_ job: Job, _ a: Prepared, _ b: Prepared) -> [(Int?, Int?, Int)] {
        struct Group { var a: [Int] = []; var b: [Int] = []; var first: Int64; var order: Int }
        var groups: [String: Group] = [:]
        var order: [String] = []
        for index in job.a {
            let key = a.keys[index]
            let start = a.tree.nodes[index].span.startNs - a.tree.startNs
            if groups[key] == nil {
                groups[key] = Group(first: start, order: order.count)
                order.append(key)
            }
            groups[key]?.a.append(index)
        }
        for index in job.b {
            let key = b.keys[index]
            let start = b.tree.nodes[index].span.startNs - b.tree.startNs
            if groups[key] == nil {
                groups[key] = Group(first: start, order: order.count)
                order.append(key)
            } else if let first = groups[key]?.first, groups[key]?.b.isEmpty == true {
                groups[key]?.first = min(first, start)
            }
            groups[key]?.b.append(index)
        }
        order.sort { (groups[$0]!.first, groups[$0]!.order) < (groups[$1]!.first, groups[$1]!.order) }
        var next: [(Int?, Int?, Int)] = []
        for key in order {
            let group = groups[key]!
            let runs = max(group.a.count, group.b.count)
            var parent = job.parent
            var depth = job.depth
            if runs >= 2 {
                parent = addRow(a: group.a, b: group.b, isGroup: true, key: key, occurrence: -1,
                                parent: job.parent, depth: job.depth, a, b)
                depth += 1
            }
            for occurrence in 0..<runs {
                let pairA = occurrence < group.a.count ? group.a[occurrence] : nil
                let pairB = occurrence < group.b.count ? group.b[occurrence] : nil
                let row = addRow(a: pairA.map { [$0] } ?? [], b: pairB.map { [$0] } ?? [], isGroup: false, key: key,
                                 occurrence: occurrence, parent: parent, depth: depth, a, b)
                next.append((pairA, pairB, row))
            }
        }
        return next
    }

    private mutating func addRow(a nodesA: [Int], b nodesB: [Int], isGroup: Bool, key: String, occurrence: Int,
                                 parent: Int?, depth: Int, _ a: Prepared, _ b: Prepared) -> Int {
        var hasher = Hasher()
        hasher.combine(parent.map { rows[$0].id } ?? 0)
        hasher.combine(key)
        hasher.combine(occurrence)
        let first = nodesB.first.map { (b.titles[$0], b.tree.nodes[$0].span) } ?? nodesA.first.map { (a.titles[$0], a.tree.nodes[$0].span) }!
        var row = Row(id: hasher.finalize(), title: first.0, service: first.1.serviceName, kind: first.1.kind,
                      a: nodesA, b: nodesB, isGroup: isGroup, parent: parent, depth: depth)
        Self.fill(&row, side: nodesA, a, inA: true)
        Self.fill(&row, side: nodesB, b, inA: false)
        row.change = Self.change(of: row)
        if let statusA = row.aStatus, let statusB = row.bStatus {
            row.statusChanged = (statusA == .error) != (statusB == .error)
        }
        let index = rows.count
        rows.append(row)
        indexByID[row.id] = index
        if let parent { rows[parent].children.append(index) } else { roots.append(index) }
        return index
    }

    private static func fill(_ row: inout Row, side nodes: [Int], _ prepared: Prepared, inA: Bool) {
        guard let firstNode = nodes.first else { return }
        let tree = prepared.tree
        var total: Int64 = 0
        var selfNs: Int64 = 0
        var shortest = Int64.max
        var longest = Int64.min
        var start = Int64.max
        var end = Int64.min
        var status = tree.nodes[firstNode].span.status
        for node in nodes {
            let span = tree.nodes[node].span
            total += span.durationNs
            selfNs += prepared.selfNs[node]
            shortest = min(shortest, span.durationNs)
            longest = max(longest, span.durationNs)
            start = min(start, span.startNs - tree.startNs)
            end = max(end, span.endNs - tree.startNs)
            if span.status == .error { status = .error }
        }
        let range = start...max(start, end)
        let runs = shortest...longest
        if inA {
            row.aDurationNs = total
            row.aSelfNs = selfNs
            row.aRunRange = runs
            row.aStatus = status
            row.aRange = range
        } else {
            row.bDurationNs = total
            row.bSelfNs = selfNs
            row.bRunRange = runs
            row.bStatus = status
            row.bRange = range
        }
    }

    /// Slower or Faster over 1 ms and over 20% of A, else Same.
    public static func change(from a: Int64, to b: Int64) -> Change {
        let delta = b - a
        guard abs(delta) > absoluteLimitNs, Double(abs(delta)) > relativeLimit * Double(a) else { return .same }
        return delta > 0 ? .slower : .faster
    }

    static func change(of row: Row) -> Change {
        if row.a.isEmpty { return .new }
        if row.b.isEmpty { return .missing }
        if row.isGroup, row.a.count != row.b.count { return .repeated }
        return change(from: row.aDurationNs, to: row.bDurationNs)
    }

    /// Counts and flags bottom-up: children always come after their parent.
    private mutating func summarize() {
        for index in rows.indices.reversed() {
            rows[index].subtreeSpans += rows[index].isGroup ? 0 : rows[index].a.count + rows[index].b.count
            guard let parent = rows[index].parent else { continue }
            rows[parent].descendantCount += 1 + rows[index].descendantCount
            rows[parent].subtreeSpans += rows[index].subtreeSpans
            if rows[index].differs || rows[index].differsBelow { rows[parent].differsBelow = true }
        }
        let singles = rows.lazy.filter { !$0.isGroup }
        comparedSpans = singles.count
        matchedSpans = singles.filter { !$0.isOneSided }.count
    }

    // MARK: Differences and queries

    static func differences(in rows: [Row]) -> [Difference] {
        var errors: [Difference] = []
        var others: [Difference] = []
        for (index, row) in rows.enumerated() {
            let parent = row.parent.map { rows[$0] }
            if row.statusChanged, !row.isGroup {
                errors.append(Difference(kind: .error, row: index, ns: row.bDurationNs))
            }
            if row.isOneSided {
                // Only the top of a New or Missing subtree, and not the extra runs of a group (Repeated says those).
                guard parent.map({ !$0.isOneSided && !$0.isGroup }) ?? true else { continue }
                others.append(Difference(kind: row.a.isEmpty ? .new : .missing, row: index,
                                         ns: row.a.isEmpty ? row.bDurationNs : row.aDurationNs))
                continue
            }
            if parent?.isGroup == true { continue }
            if row.change == .repeated {
                others.append(Difference(kind: .repeated, row: index, ns: row.bDurationNs - row.aDurationNs))
                continue
            }
            // Its own time moved the way its duration did: a span that got
            // faster overall is never a Slower line, whatever its gaps did.
            switch change(from: row.aSelfNs, to: row.bSelfNs) {
            case .slower where row.change != .faster: others.append(Difference(kind: .slower, row: index, ns: row.bSelfNs - row.aSelfNs))
            case .faster where row.change != .slower: others.append(Difference(kind: .faster, row: index, ns: row.bSelfNs - row.aSelfNs))
            default: break
            }
        }
        let ranked = { (lhs: Difference, rhs: Difference) in (abs(lhs.ns), -lhs.row) > (abs(rhs.ns), -rhs.row) }
        return errors.sorted(by: ranked) + others.sorted(by: ranked)
    }

    static func queries(_ a: Prepared, _ b: Prepared) -> [Query] {
        var byKey: [String: Query] = [:]
        for (prepared, inA) in [(a, true), (b, false)] {
            for index in prepared.spans.indices where !prepared.statements[index].isEmpty {
                let span = prepared.spans[index].span
                let key = span.serviceName + "\u{1}" + prepared.statements[index]
                var query = byKey[key] ?? Query(service: span.serviceName, statement: prepared.statements[index],
                                                aRuns: 0, bRuns: 0, aNs: 0, bNs: 0)
                if inA {
                    query.aRuns += 1
                    query.aNs += span.durationNs
                } else {
                    query.bRuns += 1
                    query.bNs += span.durationNs
                }
                byKey[key] = query
            }
        }
        return byKey.values.sorted {
            (abs($0.bRuns - $0.aRuns), abs($0.bNs - $0.aNs), $1.statement, $1.service)
                > (abs($1.bRuns - $1.aRuns), abs($1.bNs - $1.aNs), $0.statement, $0.service)
        }
    }

    // MARK: Rows on screen

    /// The rows on screen, in order, with `collapsed` rows (ids) closed.
    public func visibleRows(collapsed: Set<Int>) -> [Int] {
        var out: [Int] = []
        var stack = roots.reversed() as [Int]
        while let index = stack.popLast() {
            out.append(index)
            if !collapsed.contains(rows[index].id) { stack.append(contentsOf: rows[index].children.reversed()) }
        }
        return out
    }

    /// The rows that start collapsed: groups always (their runs are one row);
    /// with `onlyDifferences`, every row with nothing different under it;
    /// and above `limit` rows on screen, every row from the level where the
    /// rows shown would pass it (S-005's rule).
    public func defaultCollapsed(onlyDifferences: Bool, limit: Int = Waterfall.autoCollapseLimit) -> Set<Int> {
        var collapsed = Set<Int>()
        for row in rows where !row.children.isEmpty {
            if row.isGroup || (onlyDifferences && !row.differsBelow) { collapsed.insert(row.id) }
        }
        guard visibleRows(collapsed: collapsed).count > limit else { return collapsed }
        let maxDepth = rows.map(\.depth).max() ?? 0
        var perDepth = [Int](repeating: 0, count: maxDepth + 1)
        for row in rows { perDepth[row.depth] += 1 }
        var shown = 0
        var openDepth = 0
        for depth in perDepth.indices {
            shown += perDepth[depth]
            if shown > limit { break }
            openDepth = depth
        }
        openDepth = max(openDepth, 1)
        for row in rows where row.depth >= openDepth && !row.children.isEmpty { collapsed.insert(row.id) }
        return collapsed
    }

    /// The row ids above a row, its parent first: what must be open for it to show.
    public func ancestors(of index: Int) -> [Int] {
        var out: [Int] = []
        var current = rows[index].parent
        while let parent = current, out.count < rows.count {
            out.append(rows[parent].id)
            current = rows[parent].parent
        }
        return out
    }

    /// Where a side's bar starts and how wide it is, as fractions of `scaleNs`.
    public func barFractions(of index: Int, inA: Bool) -> (start: Double, width: Double)? {
        guard let range = inA ? rows[index].aRange : rows[index].bRange else { return nil }
        let scale = Double(scaleNs)
        let start = min(max(Double(range.lowerBound) / scale, 0), 1)
        let width = min(max(Double(range.upperBound - range.lowerBound) / scale, 0), 1 - start)
        return (start, width)
    }

    /// The service shown next to the title: only where it differs from the parent row's.
    public func shownService(of index: Int) -> String? {
        let service = rows[index].service
        guard let parent = rows[index].parent else { return service }
        return rows[parent].service == service ? nil : service
    }

    // MARK: Keys and titles

    static let methods: Set<String> = ["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS", "CONNECT", "TRACE"]

    /// A span's title: its name, or for a span named only for its HTTP
    /// method, the method with its route or its URL's path ("GET /v1/inventory").
    public static func title(_ span: ComparisonSpan) -> String {
        let name = span.span.name
        guard methods.contains(name.uppercased()) else { return name }
        if let route = span.span.httpRoute, !route.isEmpty { return "\(name) \(route)" }
        if let url = span.httpURL, let path = path(of: url) { return "\(name) \(path)" }
        return name
    }

    /// A URL's path without its scheme, host, query and fragment.
    static func path(of url: String) -> String? {
        var rest = Substring(url)
        if let scheme = rest.range(of: "://") {
            rest = rest[scheme.upperBound...]
            rest = rest.firstIndex(of: "/").map { rest[$0...] } ?? "/"
        }
        if let end = rest.firstIndex(where: { $0 == "?" || $0 == "#" }) { rest = rest[..<end] }
        return rest.isEmpty ? nil : String(rest)
    }

    /// A name with its ids read as `?`: runs of 2 or more digits, and words of
    /// hex digits and hyphens with 8 or more hex digits and at least one digit
    /// (UUIDs, span ids, dates). "GET /orders/1042" and "GET /orders/1187" read alike.
    public static func normalizedName(_ name: String) -> String {
        let bytes = Array(name.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var index = 0
        func isWord(_ byte: UInt8) -> Bool { isAlnum(byte) || byte == UInt8(ascii: "-") }
        while index < bytes.count {
            guard isWord(bytes[index]) else {
                out.append(bytes[index])
                index += 1
                continue
            }
            var end = index
            while end < bytes.count, isWord(bytes[end]) { end += 1 }
            let word = bytes[index..<end]
            if isID(word) {
                out.append(UInt8(ascii: "?"))
            } else {
                // Digit runs of 2 or more inside the word.
                var cursor = word.startIndex
                while cursor < word.endIndex {
                    if isDigit(word[cursor]) {
                        var runEnd = cursor
                        while runEnd < word.endIndex, isDigit(word[runEnd]) { runEnd += 1 }
                        if runEnd - cursor >= 2 { out.append(UInt8(ascii: "?")) } else { out.append(contentsOf: word[cursor..<runEnd]) }
                        cursor = runEnd
                    } else {
                        out.append(word[cursor])
                        cursor += 1
                    }
                }
            }
            index = end
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func isDigit(_ byte: UInt8) -> Bool { byte >= 48 && byte <= 57 }
    private static func isHexLetter(_ byte: UInt8) -> Bool { (byte >= 97 && byte <= 102) || (byte >= 65 && byte <= 70) }
    private static func isAlnum(_ byte: UInt8) -> Bool {
        isDigit(byte) || (byte >= 97 && byte <= 122) || (byte >= 65 && byte <= 90)
    }

    private static func isID(_ word: ArraySlice<UInt8>) -> Bool {
        var hex = 0
        var digits = 0
        for byte in word {
            if isDigit(byte) { digits += 1; hex += 1 } else if isHexLetter(byte) { hex += 1 } else if byte != UInt8(ascii: "-") { return false }
        }
        return hex >= 8 && digits >= 1
    }
}
