import Foundation

/// What a comparison says, on every surface (docs/ux.md, S-036): the tree's
/// cells, the strip's lines, the header sentence, VoiceOver and the MCP
/// tool, so the window and a coding agent never disagree.
extension TraceComparison {
    /// "+300 ms", "−3 ms" (a real minus sign).
    public static func signed(_ ns: Int64) -> String {
        (ns < 0 ? "\u{2212}" : "+") + DurationFormat.string(nanoseconds: abs(ns))
    }

    public static func runs(_ a: Int, _ b: Int) -> String { "\(CountFormat.string(a)) → \(CountFormat.string(b)) runs" }

    /// The Change column: "+300 ms", "−3 ms", "Same", "New", "Missing", "2 → 8 runs".
    public func changeText(of index: Int) -> String {
        let row = rows[index]
        switch row.change {
        case .same: return "Same"
        case .slower, .faster: return Self.signed(row.bDurationNs - row.aDurationNs)
        case .repeated: return Self.runs(row.aRuns, row.bRuns)
        case .new: return "New"
        case .missing: return "Missing"
        }
    }

    /// The A or B column: the duration, "—" on the side that has none; a
    /// group's "2 × 5.0 ms" when its runs are alike (within 10%), else
    /// "8 runs, 40 ms".
    public func durationText(of index: Int, inA: Bool) -> String {
        let row = rows[index]
        let runs = inA ? row.aRuns : row.bRuns
        guard runs > 0 else { return "—" }
        let total = inA ? row.aDurationNs : row.bDurationNs
        guard row.isGroup, let range = inA ? row.aRunRange : row.bRunRange else {
            return DurationFormat.string(nanoseconds: total)
        }
        if runs == 1 { return DurationFormat.string(nanoseconds: total) }
        if Double(range.upperBound - range.lowerBound) <= 0.1 * Double(range.upperBound) {
            return "\(CountFormat.string(runs)) × \(DurationFormat.string(nanoseconds: total / Int64(runs)))"
        }
        return "\(CountFormat.string(runs)) runs, \(DurationFormat.string(nanoseconds: total))"
    }

    /// The change mark's word: nil for Same.
    public func markWord(of index: Int) -> String? {
        let row = rows[index]
        if row.statusChanged { return "Error" }
        switch row.change {
        case .same: return nil
        case .slower: return "Slower"
        case .faster: return "Faster"
        case .repeated: return "Repeated"
        case .new: return "New"
        case .missing: return "Missing"
        }
    }

    /// What VoiceOver reads for a tree row: "SELECT orders, orders, A 20
    /// milliseconds, B 320 milliseconds, Slower by 300 milliseconds".
    public func accessibilityLabel(of index: Int) -> String {
        let row = rows[index]
        var parts = [row.title, row.service]
        if row.isGroup {
            if row.aRuns > 0 { parts.append("\(CountFormat.string(row.aRuns)) runs in A") }
            if row.bRuns > 0 { parts.append("\(CountFormat.string(row.bRuns)) runs in B") }
        } else {
            if row.aRuns > 0 { parts.append("A \(DurationFormat.spoken(nanoseconds: row.aDurationNs))") }
            if row.bRuns > 0 { parts.append("B \(DurationFormat.spoken(nanoseconds: row.bDurationNs))") }
        }
        switch row.change {
        case .same: parts.append("Same")
        case .slower: parts.append("Slower by \(DurationFormat.spoken(nanoseconds: row.bDurationNs - row.aDurationNs))")
        case .faster: parts.append("Faster by \(DurationFormat.spoken(nanoseconds: row.aDurationNs - row.bDurationNs))")
        case .repeated: parts.append("Repeated")
        case .new: parts.append("only in B, New")
        case .missing: parts.append("only in A, Missing")
        }
        if row.statusChanged { parts.append("Error in \(row.bStatus == .error ? "B" : "A")") }
        return parts.joined(separator: ", ")
    }

    // MARK: The header sentence

    /// "B took 356 ms longer than A (6.6×). B has 6 more spans."
    public var totalSentence: String {
        let a = traceA?.durationNs ?? treeA.durationNs
        let b = traceB?.durationNs ?? treeB.durationNs
        var time: String
        switch Self.change(from: a, to: b) {
        case .slower:
            time = "B took \(DurationFormat.string(nanoseconds: b - a)) longer than A"
            if a > 0 { time += " (\(Self.ratio(Double(b) / Double(a))))" }
        case .faster:
            time = "B took \(DurationFormat.string(nanoseconds: a - b)) less than A"
            if b > 0 { time += " (\(Self.ratio(Double(a) / Double(b))) faster)" }
        default:
            time = "B and A took about as long, \(DurationFormat.string(nanoseconds: b)) and \(DurationFormat.string(nanoseconds: a))"
        }
        let spansA = traceA?.spanCount ?? treeA.count
        let spansB = traceB?.spanCount ?? treeB.count
        let spans: String
        if spansB > spansA {
            spans = "B has \(CountFormat.string(spansB - spansA)) more \(spansB - spansA == 1 ? "span" : "spans")."
        } else if spansB < spansA {
            spans = "B has \(CountFormat.string(spansA - spansB)) fewer \(spansA - spansB == 1 ? "span" : "spans")."
        } else {
            spans = "Both have \(TraceList.spansText(spansA))."
        }
        return time + ". " + spans
    }

    /// "6.6×", "29×" from 10 on.
    static func ratio(_ value: Double) -> String {
        value >= 10 ? "\(Int(value.rounded()))×" : String(format: "%.1f×", value)
    }

    /// The banner over a comparison with little in common.
    public var littleInCommonText: String {
        "These traces have little in common: \(CountFormat.string(matchedSpans)) of \(CountFormat.string(comparedSpans)) spans match. They may not be the same request."
    }

    public static let noDifferencesText = "No differences over 1 ms and 20%."

    // MARK: Strip lines

    public func kindWord(_ kind: Difference.Kind) -> String {
        switch kind {
        case .error: "Error"
        case .slower: "Slower"
        case .faster: "Faster"
        case .repeated: "Repeated"
        case .new: "New"
        case .missing: "Missing"
        }
    }

    /// "Slower · +300 ms · SELECT orders · orders",
    /// "Repeated · 2 → 8 runs · +30 ms · SELECT order_items · orders",
    /// "New · 3 spans · GET /v1/inventory · orders", "Missing · HGET · checkout-api",
    /// "Error · Unset → Error · GET /v1/recommendations · checkout-api".
    public func line(_ difference: Difference) -> String {
        let row = rows[difference.row]
        var parts = [kindWord(difference.kind)]
        switch difference.kind {
        case .slower, .faster: parts.append(Self.signed(difference.ns))
        case .repeated:
            parts.append(Self.runs(row.aRuns, row.bRuns))
            parts.append(Self.signed(difference.ns))
        case .new, .missing:
            if row.subtreeSpans > 1 { parts.append(TraceList.spansText(row.subtreeSpans)) }
        case .error:
            parts.append("\((row.aStatus ?? .unset).title) → \((row.bStatus ?? .unset).title)")
        }
        parts.append(row.title)
        parts.append(row.service)
        return parts.joined(separator: " · ")
    }

    /// The strip line's tooltip and the MCP tool's sentence.
    public func detailText(_ difference: Difference) -> String {
        let row = rows[difference.row]
        let a = DurationFormat.string(nanoseconds: row.aDurationNs)
        let b = DurationFormat.string(nanoseconds: row.bDurationNs)
        let own = DurationFormat.string(nanoseconds: abs(difference.ns))
        switch difference.kind {
        case .slower:
            return "\(row.title) took \(b) in B and \(a) in A; \(own) of it is its own time, not its children's."
        case .faster:
            return "\(row.title) took \(b) in B and \(a) in A; its own time, not its children's, is \(own) shorter."
        case .repeated:
            return "\(row.title) ran \(CountFormat.string(row.bRuns)) times in B (\(b)) and \(CountFormat.string(row.aRuns)) times in A (\(a))."
        case .new:
            let spans = row.subtreeSpans > 1 ? ", with \(TraceList.spansText(row.subtreeSpans - 1)) under it" : ""
            return "\(row.title) in \(row.service) is only in B: \(b)\(spans)."
        case .missing:
            let spans = row.subtreeSpans > 1 ? ", with \(TraceList.spansText(row.subtreeSpans - 1)) under it" : ""
            return "\(row.title) in \(row.service) is only in A: \(a)\(spans)."
        case .error:
            return "\(row.title) in \(row.service) has status \((row.bStatus ?? .unset).title) in B and \((row.aStatus ?? .unset).title) in A."
        }
    }

    /// VoiceOver's words for a strip line: the line, with durations spoken.
    public func accessibilityLabel(_ difference: Difference) -> String {
        let row = rows[difference.row]
        let spoken = DurationFormat.spoken(nanoseconds: abs(difference.ns))
        switch difference.kind {
        case .slower: return "Slower, \(row.title) in \(row.service), \(spoken) more"
        case .faster: return "Faster, \(row.title) in \(row.service), \(spoken) less"
        case .repeated: return "Repeated, \(row.title) in \(row.service), \(row.aRuns) runs in A, \(row.bRuns) in B"
        case .new: return "New, \(row.title) in \(row.service)"
        case .missing: return "Missing, \(row.title) in \(row.service)"
        case .error: return "Error, \(row.title) in \(row.service), \((row.aStatus ?? .unset).title) in A, \((row.bStatus ?? .unset).title) in B"
        }
    }

    // MARK: Queries

    /// "2 → 8"
    public static func runsText(_ query: Query) -> String {
        "\(CountFormat.string(query.aRuns)) → \(CountFormat.string(query.bRuns))"
    }

    /// "10 ms → 40 ms", "—" for a side with no run.
    public static func durationText(_ query: Query) -> String {
        let a = query.aRuns > 0 ? DurationFormat.string(nanoseconds: query.aNs) : "—"
        let b = query.bRuns > 0 ? DurationFormat.string(nanoseconds: query.bNs) : "—"
        return "\(a) → \(b)"
    }

    /// The header line of one side: "GET /account/orders · web · 64 ms · 10 spans".
    public static func headerText(_ trace: TraceSummary) -> String {
        [trace.route, trace.waterfallSubtitle].joined(separator: " · ")
    }
}
