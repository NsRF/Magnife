import AppKit
import MagnifeKit
import SwiftUI

/// Search (S-017): a floating panel over the top of the main window, the
/// shape of Xcode's Open Quickly. A click outside it closes it; so do Esc,
/// opening a result and Apply as Filter. Liquid Glass, as a floating
/// control; Reduce Transparency makes it solid.
struct SearchOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.showsSearch {
            ZStack(alignment: .top) {
                // Catches the click outside; the window stays visible behind it.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { model.closeSearch() }
                    .accessibilityHidden(true)
                SearchPanel()
                    .padding(.top, Space.sm)
                    .padding(.horizontal, Space.margin)
            }
        }
    }
}

struct SearchPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    static let width: CGFloat = 640
    private let shape = RoundedRectangle(cornerRadius: Radius.card + Space.xs, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title = model.searchCompareTitle {
                CompareBaseChip(title: title)
                    .padding(.horizontal, Space.lg)
                    .padding(.top, Space.md)
            }
            field
            let tokens = model.searchQuery.tokens
            if !tokens.isEmpty {
                SearchTokenChips(tokens: tokens)
                    .padding(.horizontal, Space.lg)
                    .padding(.bottom, Space.sm)
            }
            Divider()
            SearchResults()
            Divider()
            footer
        }
        .frame(maxWidth: Self.width)
        .modifier(PanelSurface(shape: shape, solid: reduceTransparency || DisplayOverrides.reduceTransparency))
        .gridArea("search-panel", inset: Space.lg)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search")
    }

    private var field: some View {
        @Bindable var model = model
        return HStack(spacing: Space.sm) {
            Image(systemName: "magnifyingglass")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: Space.xl)
                .accessibilityHidden(true)
            SearchField(text: $model.searchText, focusRequest: model.searchFocusRequest,
                        placeholder: model.searchCompareBase == nil ? TraceSearch.placeholder : TraceSearch.comparePlaceholder,
                        onMove: { model.moveSearchSelection(by: $0) },
                        onSubmit: { model.activateSearchSelection() },
                        onApply: { model.applySearchAsFilter() },
                        onCancel: { model.closeSearch() })
                .gridProbe("search-field", area: "search-panel")
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
    }

    /// "↩ Open   ⌘↩ Apply as Filter   esc Close", the keys in the same words
    /// as the menus; in compare mode "↩ Compare   esc Close" (S-036).
    private var footer: some View {
        HStack(spacing: Space.lg) {
            Button(model.searchCompareBase == nil ? "↩ Open" : "↩ Compare") { model.activateSearchSelection() }
                .disabled(model.searchTraces.isEmpty && model.searchSuggestions.isEmpty)
            if model.searchCompareBase == nil {
                // The field editor never sees ⌘Return; the window's key equivalents do.
                Button("⌘↩ Apply as Filter") { model.applySearchAsFilter() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!model.searchQuery.filter.isActive)
            }
            Button("esc Close") { model.closeSearch() }
            Spacer(minLength: 0)
        }
        .buttonStyle(.plain)
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.sm)
    }
}

/// Compare mode's chip before the field (S-036): "Compare with GET /account/orders · 64 ms".
struct CompareBaseChip: View {
    let title: String

    var body: some View {
        Label(title, systemImage: "arrow.left.arrow.right")
            .font(.callout)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, Space.sm)
            .padding(.vertical, 2)
            .background(.tint.opacity(0.16), in: Capsule())
            .help(title)
            .gridProbe("compare-chip", area: "search-panel", edge: nil)
    }
}

/// What the typed tokens mean, one chip each: "status is Error". VoiceOver
/// reads "Filter: status is Error".
struct SearchTokenChips: View {
    let tokens: [TraceQuery.Token]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Space.xs) {
                ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                    Text(token.spokenText)
                        .font(.callout)
                        .lineLimit(1)
                        .padding(.horizontal, Space.sm)
                        .padding(.vertical, 2)
                        .background(.tint.opacity(0.16), in: Capsule())
                        .help(token.text)
                        .accessibilityLabel("Filter: \(token.spokenText)")
                }
            }
        }
        .scrollIndicators(.never)
    }
}

/// Suggestions for the unfinished token, then "Newest Traces" or
/// "Matching Traces" with the count, or "No traces match …".
struct SearchResults: View {
    @Environment(AppModel.self) private var model
    static let maxHeight: CGFloat = 400

    var body: some View {
        let suggestions = model.searchSuggestions
        let traces = model.searchTraces
        ScrollViewReader { proxy in
            ScrollView {
                // At most 8 suggestions and 50 traces: a plain stack, so every row keeps its own identity.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.element) { index, value in
                        SearchSuggestionRow(prefix: model.searchQuery.unfinished?.prefix.rawValue ?? "", value: value,
                                            isSelected: model.searchSelection == index) {
                            model.completeSearch(with: value)
                        }
                        .id(Self.rowID(index))
                    }
                    if let result = model.searchResult {
                        if traces.isEmpty {
                            noMatches(result)
                        } else {
                            // Compare mode (S-036): "Same Route" first, then the result's own header.
                            let same = model.searchSameRouteCount
                            if same > 0 { sectionHeader(TraceSearch.sameRouteHeader, count: "") }
                            ForEach(Array(traces.enumerated()), id: \.element.id) { offset, trace in
                                let index = suggestions.count + offset
                                if offset == same, offset < traces.count { header(result) }
                                SearchResultRow(trace: trace, now: model.now, isSelected: model.searchSelection == index) {
                                    model.pickSearchResult(trace.traceID)
                                }
                                .id(Self.rowID(index))
                            }
                        }
                    }
                }
                .padding(.vertical, Space.xs)
            }
            .frame(maxHeight: Self.maxHeight)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: model.searchSelection) { _, index in proxy.scrollTo(Self.rowID(index)) }
        }
    }

    /// Scroll targets by place in the list, apart from the rows' own identity.
    private static func rowID(_ index: Int) -> String { "row-\(index)" }

    private func header(_ result: TraceSearchResult) -> some View {
        sectionHeader(result.header, count: result.countText)
    }

    private func sectionHeader(_ title: String, count: String) -> some View {
        HStack {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Text(count)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, Space.lg)
        .padding(.top, Space.sm)
        .padding(.bottom, Space.xs)
    }

    private func noMatches(_ result: TraceSearchResult) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(TraceSearch.noMatchTitle(result.text))
                .font(.headline)
            Text(TraceSearch.noMatchHint)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        .accessibilityElement(children: .combine)
    }
}

/// A highlighted row is accent-filled with on-accent text, like a menu's.
private struct SearchRowBackground: ViewModifier {
    let isSelected: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, Space.sm)
            .padding(.vertical, Space.xs + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(.clear),
                        in: .rect(cornerRadius: Radius.small - 2))
            .padding(.horizontal, Space.sm)
            .contentShape(Rectangle())
    }
}

/// "POST /orders · checkout-api · 240 ms · Error · 2 min ago", as the list row reads.
struct SearchResultRow: View {
    let trace: TraceSummary
    let now: Date
    let isSelected: Bool
    let open: () -> Void

    var body: some View {
        let parts = TraceSearch.rowParts(trace, now: now)
        Button(action: open) {
            HStack(spacing: Space.xs) {
                if trace.status == .error {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .foregroundStyle(isSelected ? AnyShapeStyle(Palette.onAccent) : AnyShapeStyle(StatusColors.error))
                }
                Text(trace.route)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("· " + parts.dropFirst().joined(separator: " · "))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Palette.onAccent) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(Palette.onAccent) : AnyShapeStyle(.primary))
            .modifier(SearchRowBackground(isSelected: isSelected))
        }
        .buttonStyle(.plain)
        .help(trace.route)
        .accessibilityLabel(trace.accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A value the unfinished token can take: "status:error".
struct SearchSuggestionRow: View {
    let prefix: String
    let value: String
    let isSelected: Bool
    let complete: () -> Void

    var body: some View {
        Button(action: complete) {
            HStack(spacing: Space.xs) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .accessibilityHidden(true)
                Text("\(prefix):\(value)")
                    .font(.body.monospaced())
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(Palette.onAccent) : AnyShapeStyle(.primary))
            .modifier(SearchRowBackground(isSelected: isSelected))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(prefix) \(value)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The toolbar's Search button (docs/ux.md, Toolbar item 9).
struct SearchToolbarButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.showSearch()
        } label: {
            Label("Search", systemImage: "magnifyingglass")
        }
        .labelStyle(.iconOnly)
        .help("Look up a trace by service, route, trace ID or attribute (⌘K)")
    }
}
