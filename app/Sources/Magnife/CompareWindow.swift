import AppKit
import MagnifeKit
import SwiftUI

/// The Compare Traces window (S-036, docs/ux.md): the two traces, the
/// differences strip, the merged tree and the queries. It reads the
/// comparison's own model, so the main window's live updates never redraw it.
struct CompareWindowView: View {
    @Environment(AppModel.self) private var model
    @Environment(CompareModel.self) private var compare

    var body: some View {
        Group {
            if let comparison = compare.comparison, let pair = compare.pair {
                VStack(alignment: .leading, spacing: 0) {
                    CompareHeader(comparison: comparison, pair: pair, now: Date())
                    if comparison.hasLittleInCommon {
                        Banner(text: comparison.littleInCommonText, symbol: "exclamationmark.triangle.fill") { EmptyView() }
                            .padding(.bottom, Space.sm)
                    }
                    DifferencesStrip(comparison: comparison)
                    Divider()
                    CompareOutline(model: model, compare: compare, generation: compare.generation, comparison: comparison,
                                   collapsed: compare.collapsed, selected: compare.selectedRow, colors: model.serviceColors)
                    if !comparison.queries.isEmpty {
                        Divider()
                        QueriesTable(queries: comparison.queries)
                    }
                }
            } else if compare.pair == nil {
                ContentUnavailableView("No Comparison", systemImage: "arrow.left.arrow.right",
                                       description: Text("Right-click a trace and choose Compare with Selected Trace, or press ⇧⌘K."))
            } else {
                // The first read of a pair: no spinner (docs/ux.md, App-wide states), the window fills in a moment.
                Color.clear
            }
        }
        .navigationTitle("Compare Traces")
        .toolbar {
            ToolbarItemGroup {
                Button("Swap Traces", systemImage: "arrow.up.arrow.down") { model.swapComparedTraces() }
                    .help("Make A the B and B the A (⌥⌘K)")
                    .disabled(compare.pair == nil)
                Toggle("Show Only Differences", systemImage: "line.3.horizontal.decrease",
                       isOn: Binding(get: { compare.showsOnlyDifferences }, set: { _ in model.toggleOnlyDifferences() }))
                    .help("Collapse every part of the tree with no difference in it (⇧⌘D)")
                    .disabled(compare.comparison == nil)
            }
        }
    }
}

/// "A  GET /account/orders · web · 64 ms · 10 spans · 2 min ago  Open Trace", and B under it.
struct CompareHeader: View {
    @Environment(AppModel.self) private var model
    let comparison: TraceComparison
    let pair: CompareModel.Pair
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            side("A", trace: comparison.traceA, inA: true)
            side("B", trace: comparison.traceB, inA: false)
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .gridArea("compare-header", inset: Space.lg)
    }

    private func side(_ letter: String, trace: TraceSummary?, inA: Bool) -> some View {
        HStack(spacing: Space.sm) {
            Text(letter)
                .font(.headline.monospaced())
                .frame(width: Space.lg, alignment: .leading)
                .help(inA ? "Baseline: the trace B is compared with" : "The trace compared with A")
            if let trace {
                if trace.status == .error {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .foregroundStyle(StatusColors.error)
                        .accessibilityLabel("Error")
                }
                Text(trace.route)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(trace.route)
                Text("· \(trace.waterfallSubtitle) · \(RelativeTime.string(for: trace.start, now: now))")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            } else {
                Text("Trace No Longer Stored")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Space.sm)
            Button("Open Trace") { model.openComparedTrace(inA: inA) }
                .controlSize(.small)
                .disabled(trace == nil)
                .accessibilityLabel("Open Trace \(letter)")
        }
        .gridProbe("compare-side-\(letter)", area: "compare-header")
        .accessibilityElement(children: .combine)
    }
}

/// The header sentence, then one button per difference: Error first, then
/// by the time each explains; 3 lines, then "Show All Differences (N)".
struct DifferencesStrip: View {
    @Environment(AppModel.self) private var model
    @Environment(CompareModel.self) private var compare
    let comparison: TraceComparison

    static let shown = 3
    static let expandedMaxHeight: CGFloat = 160

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(comparison.totalSentence)
                .fontWeight(.medium)
                .gridProbe("compare-total", area: "differences")
            if comparison.differences.isEmpty {
                Text(TraceComparison.noDifferencesText)
                    .foregroundStyle(.secondary)
            } else if compare.showsAllDifferences {
                ScrollView { lines(comparison.differences[...]) }
                    .frame(maxHeight: Self.expandedMaxHeight)
                    .scrollBounceBehavior(.basedOnSize)
            } else {
                lines(comparison.differences.prefix(Self.shown))
            }
            if comparison.differences.count > Self.shown {
                Button(compare.showsAllDifferences ? "Show Fewer Differences"
                       : "Show All Differences (\(CountFormat.string(comparison.differences.count)))") {
                    compare.showsAllDifferences.toggle()
                }
                .buttonStyle(.link)
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.bottom, Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .gridArea("differences", inset: Space.lg)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Differences")
    }

    private func lines(_ shown: ArraySlice<TraceComparison.Difference>) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            ForEach(Array(shown.enumerated()), id: \.offset) { offset, difference in
                Button {
                    model.selectDifference(difference)
                } label: {
                    HStack(spacing: Space.xs) {
                        DifferenceMark(kind: difference.kind)
                        Text(comparison.line(difference))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(comparison.detailText(difference))
                .accessibilityLabel(comparison.accessibilityLabel(difference))
                .gridProbe("difference-\(offset)", area: "differences")
            }
        }
    }
}

/// A difference's icon, in its color; the word beside it always says the same.
struct DifferenceMark: View {
    let kind: TraceComparison.Difference.Kind

    var body: some View {
        Image(systemName: CompareMarks.symbol(kind))
            .foregroundStyle(CompareMarks.color(kind))
            .accessibilityHidden(true)
    }
}

/// The change marks' icons and colors (docs/ux.md, S-036 Access): Error the
/// octagon in red, Slower and Repeated in the warning color, the rest secondary.
enum CompareMarks {
    static func symbol(_ kind: TraceComparison.Difference.Kind) -> String {
        switch kind {
        case .error: "exclamationmark.octagon.fill"
        case .slower: "tortoise"
        case .faster: "hare"
        case .repeated: "repeat"
        case .new: "plus.circle"
        case .missing: "minus.circle"
        }
    }

    static func color(_ kind: TraceComparison.Difference.Kind) -> Color {
        Color(nsColor: nsColor(kind))
    }

    static func nsColor(_ kind: TraceComparison.Difference.Kind) -> NSColor {
        switch kind {
        case .error: StatusColors.errorNS
        case .slower, .repeated: StatusColors.warningNS
        case .faster, .new, .missing: .secondaryLabelColor
        }
    }

    /// The mark a tree row shows: nil for Same.
    static func kind(of row: TraceComparison.Row) -> TraceComparison.Difference.Kind? {
        if row.statusChanged { return .error }
        switch row.change {
        case .same: return nil
        case .slower: return .slower
        case .faster: return .faster
        case .repeated: return .repeated
        case .new: return .new
        case .missing: return .missing
        }
    }
}

/// Each service's normalized statements in A and B: "2 → 8", "10 ms → 40 ms".
struct QueriesTable: View {
    let queries: [TraceComparison.Query]
    static let height: CGFloat = 168

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Queries")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .gridProbe("queries-title", area: "queries")
                .padding(.horizontal, Space.lg)
                .padding(.top, Space.sm)
            Table(queries.indices.map(QueryItem.init)) {
                TableColumn("Statement") { item in
                    let query = queries[item.id]
                    Text(query.statement)
                        .font(.body.monospaced())
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(query.statement)
                }
                .width(min: 240, ideal: 480)
                TableColumn("Service") { item in Text(queries[item.id].service).lineLimit(1) }
                    .width(min: 72, ideal: 112)
                TableColumn("Runs") { item in
                    Text(TraceComparison.runsText(queries[item.id])).monospacedDigit()
                }
                .width(min: 64, ideal: 80)
                TableColumn("Duration") { item in
                    Text(TraceComparison.durationText(queries[item.id])).monospacedDigit()
                }
                .width(min: 112, ideal: 140)
            }
            .tableStyle(.inset)
        }
        .frame(height: Self.height)
        .gridArea("queries", inset: Space.sm)
    }

    struct QueryItem: Identifiable { let id: Int }
}
