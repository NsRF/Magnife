import Foundation

/// Where a finding is (detector audit 7): the service, the route or span
/// name it sits under, who called whom, and what it cost of the trace.
/// Worked out from the waterfall, not by the detectors, which see only the
/// spans they can flag. On screen it reads "in <service>, under <route>",
/// never "endpoint" (docs/GLOSSARY.md, Route; PROGRESS decision 186).
public struct FindingPlace: Sendable, Hashable {
    /// The flagged span's service; N+1: the repeated spans' services, sorted, each once.
    public var services: [String]
    /// The route or span name the finding sits under.
    public var under: String?
    /// `under` is the trace's route and the service its root service: the
    /// waterfall header already says it, so the strip line leaves it out.
    public var underIsHeader: Bool
    /// HTTP Error: who called (a client's own service, a server's caller).
    public var caller: String?
    /// HTTP Error on a client: the service that answered, and as what.
    public var callee: String?
    public var calleeRoute: String?
    public var traceDurationNs: Int64
    /// HTTP Error: the first span under it that failed on its own.
    public var firstErrorBelow: ErrorBelow?

    public struct ErrorBelow: Sendable, Hashable {
        public var spanID: String
        /// Its HTTP Error's call when it has one, else its span name.
        public var name: String
        public var service: String
        public var message: String

        public init(spanID: String, name: String, service: String, message: String = "") {
            self.spanID = spanID
            self.name = name
            self.service = service
            self.message = message
        }
    }

    public init(services: [String], under: String? = nil, underIsHeader: Bool = false, caller: String? = nil,
                callee: String? = nil, calleeRoute: String? = nil, traceDurationNs: Int64 = 0,
                firstErrorBelow: ErrorBelow? = nil) {
        self.services = services
        self.under = under
        self.underIsHeader = underIsHeader
        self.caller = caller
        self.callee = callee
        self.calleeRoute = calleeRoute
        self.traceDurationNs = traceDurationNs
        self.firstErrorBelow = firstErrorBelow
    }

    /// The finding's share of the trace, in whole percent, at most 100; nil
    /// when it rounds to 0 or the trace has no duration. Slow SQL and N+1 only.
    public func share(of finding: Finding) -> Int? {
        guard finding.kind != .httpError, traceDurationNs > 0 else { return nil }
        let share = min(100, Int((Double(finding.durationNs) / Double(traceDurationNs) * 100).rounded()))
        return share > 0 ? share : nil
    }
}

/// Builds every finding's place from the open trace's tree. Pure, and every
/// walk is iterative with at most one step per node: a trace can be one
/// chain 30,000 spans deep.
public enum FindingPlaces {
    /// A span named only for its method is no route ("GET"): it is skipped
    /// for one further up.
    static let methods: Set<String> = ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "CONNECT", "TRACE"]

    static func isMethodOnly(_ name: String) -> Bool { methods.contains(name.uppercased()) }

    public static func build(_ findings: TraceFindings, in tree: Waterfall, trace: TraceSummary?) -> [String: FindingPlace] {
        guard !findings.isEmpty else { return [:] }
        let traceDurationNs = trace?.durationNs ?? tree.durationNs
        var below: ErrorsBelow?
        var calls: [String: String] = [:]
        for finding in findings.findings where finding.kind == .httpError {
            if let spanID = finding.spanIDs.first { calls[spanID] = finding.call }
        }
        var places: [String: FindingPlace] = [:]
        for finding in findings.findings {
            var place = FindingPlace(services: finding.kind == .nPlusOne ? finding.services
                                        : [finding.serviceName].filter { !$0.isEmpty },
                                     traceDurationNs: traceDurationNs)
            switch finding.kind {
            case .slowSQL:
                place.under = finding.spanIDs.first.flatMap(tree.index(of:)).flatMap { slowSQLUnder($0, in: tree) }
            case .nPlusOne:
                place.under = commonAncestor(finding.spanIDs.compactMap(tree.index(of:)), in: tree)
                    .flatMap { routeAtOrAbove($0, in: tree) }
            case .httpError:
                guard let index = finding.spanIDs.first.flatMap(tree.index(of:)) else { break }
                if below == nil { below = ErrorsBelow(tree) }
                httpPlace(&place, index: index, in: tree, below: below!, calls: calls)
            }
            if let under = place.under, let trace {
                place.underIsHeader = under == trace.route && place.services == [trace.rootService]
            }
            places[finding.id] = place
        }
        return places
    }

    /// The distinct span ids whose status message the places need.
    public static func errorSpanIDs(_ places: [String: FindingPlace]) -> [String] {
        Array(Set(places.values.compactMap(\.firstErrorBelow?.spanID))).sorted()
    }

    /// The places with the status messages read for them.
    public static func withMessages(_ places: [String: FindingPlace], _ messages: [String: String]) -> [String: FindingPlace] {
        places.mapValues { place in
            var place = place
            if let id = place.firstErrorBelow?.spanID { place.firstErrorBelow?.message = messages[id] ?? "" }
            return place
        }
    }

    // MARK: Under

    /// Slow SQL: the nearest server or consumer span above that is not named
    /// for its method alone, else the root's name; nil for a root or an orphan.
    static func slowSQLUnder(_ index: Int, in tree: Waterfall) -> String? {
        var current = tree.nodes[index].parent
        var root: Int?
        var steps = 0
        while let node = current, steps < tree.count {
            let span = tree.nodes[node].span
            if span.kind == .server || span.kind == .consumer, !isMethodOnly(span.name) { return span.name }
            root = node
            current = tree.nodes[node].parent
            steps += 1
        }
        return root.map { tree.nodes[$0].span.name }.flatMap { isMethodOnly($0) ? nil : $0 }
    }

    /// The name at this node, or the first one above it that is not named for its method alone.
    static func routeAtOrAbove(_ index: Int, in tree: Waterfall) -> String? {
        var current: Int? = index
        var steps = 0
        while let node = current, steps <= tree.count {
            let name = tree.nodes[node].span.name
            if !isMethodOnly(name) { return name }
            current = tree.nodes[node].parent
            steps += 1
        }
        return nil
    }

    /// The lowest span above all of these (never one of them); nil when they
    /// have none in common (several roots, orphans). Each walk stops at a
    /// node already walked, so the cost is the spans plus their ancestors.
    static func commonAncestor(_ indices: [Int], in tree: Waterfall) -> Int? {
        guard let first = indices.first else { return nil }
        // The first span's ancestors, its parent first, and each one's place in that chain.
        var chain: [Int] = []
        var position: [Int: Int] = [:]
        var current = tree.nodes[first].parent
        while let node = current, chain.count < tree.count {
            position[node] = chain.count
            chain.append(node)
            current = tree.nodes[node].parent
        }
        guard !chain.isEmpty else { return nil }
        // For each node walked: the chain position its walk reached (-1: none).
        var reached: [Int: Int] = [:]
        var highest = 0
        for index in indices.dropFirst() {
            var path: [Int] = []
            var found = -1
            current = tree.nodes[index].parent
            while let node = current, path.count < tree.count {
                if let at = position[node] { found = at; break }
                if let known = reached[node] { found = known; break }
                path.append(node)
                current = tree.nodes[node].parent
            }
            for node in path { reached[node] = found }
            guard found >= 0 else { return nil }
            highest = max(highest, found)
        }
        return chain[highest]
    }

    // MARK: HTTP

    static func httpPlace(_ place: inout FindingPlace, index: Int, in tree: Waterfall, below: ErrorsBelow,
                          calls: [String: String]) {
        let node = tree.nodes[index]
        let service = node.span.serviceName
        var calleeIndex: Int?
        switch node.span.kind {
        case .client, .producer:
            place.caller = service.isEmpty ? nil : service
            calleeIndex = node.children.first { child in
                let span = tree.nodes[child].span
                return (span.kind == .server || span.kind == .consumer) && span.serviceName != service
            }
            if let callee = calleeIndex {
                place.callee = tree.nodes[callee].span.serviceName
                place.calleeRoute = tree.nodes[callee].span.name
            }
        case .server, .consumer:
            if let parent = node.parent {
                let span = tree.nodes[parent].span
                if (span.kind == .client || span.kind == .producer), span.serviceName != service, !span.serviceName.isEmpty {
                    place.caller = span.serviceName
                }
            }
        default:
            break
        }
        if let error = below.first[index], error != calleeIndex {
            let span = tree.nodes[error].span
            place.firstErrorBelow = FindingPlace.ErrorBelow(spanID: span.spanID, name: calls[span.spanID] ?? span.name,
                                                            service: span.serviceName)
        }
    }

    /// For every span, the first span under it (by start, then span id) with
    /// status Error and no child with status Error: where a failure began.
    /// One pass from the leaves up.
    struct ErrorsBelow {
        /// By node index; nil when nothing under it failed on its own.
        private(set) var first: [Int?]

        init(_ tree: Waterfall) {
            var order: [Int] = []
            order.reserveCapacity(tree.count)
            order.append(contentsOf: tree.roots)
            var cursor = 0
            while cursor < order.count {
                order.append(contentsOf: tree.nodes[order[cursor]].children)
                cursor += 1
            }
            func earlier(_ a: Int, _ b: Int) -> Bool {
                let x = tree.nodes[a].span, y = tree.nodes[b].span
                return (x.startNs, x.spanID) < (y.startNs, y.spanID)
            }
            var best = [Int?](repeating: nil, count: tree.count)
            for index in order.reversed() {
                var found: Int?
                for child in tree.nodes[index].children {
                    let span = tree.nodes[child].span
                    let failedHere = span.status == .error
                        && !tree.nodes[child].children.contains { tree.nodes[$0].span.status == .error }
                    for candidate in [failedHere ? child : nil, best[child]].compactMap({ $0 })
                    where found.map({ earlier(candidate, $0) }) ?? true {
                        found = candidate
                    }
                }
                best[index] = found
            }
            first = best
        }
    }
}
