import MagnifeKit
import SwiftUI

/// The Route cell of the trace list: the route, then a badge per finding
/// kind (S-023+). A badge shows its word only where the whole route still
/// fits beside it; otherwise its icon alone, and the tooltip and VoiceOver
/// carry the words, so a badge never costs the route more than an icon
/// (PROGRESS decision 134).
struct RouteCell: View {
    let route: String
    let findings: FindingSummary?

    var body: some View {
        if let findings, !findings.isEmpty {
            ViewThatFits(in: .horizontal) {
                row(findings, words: true)
                row(findings, words: false)
            }
        } else {
            routeText
        }
    }

    private var routeText: some View {
        Text(route)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(route)
    }

    private func row(_ findings: FindingSummary, words: Bool) -> some View {
        HStack(spacing: Space.xs) {
            // With words, the route's ideal is its whole text; with icons, nothing,
            // so that row always fits and the route truncates beside the icons.
            routeText
                .frame(minWidth: 0, idealWidth: words ? nil : 0, maxWidth: .infinity, alignment: .leading)
            ForEach(findings.kinds) { kind in
                FindingBadge(kind: kind, showsWord: words)
                    .help(findings.help(kind))
            }
        }
    }
}

/// One finding kind: the icon and its name in orange (docs/ux.md S-023
/// Access), on an orange-tinted capsule. `StatusColors.finding` is the
/// palette's text orange (4.5:1, S-031), so the word reads in light and dark.
struct FindingBadge: View {
    let kind: FindingKind
    var showsWord = true

    var body: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: kind.symbol)
            if showsWord { Text(kind.title) }
        }
        .foregroundStyle(StatusColors.finding)
        .font(.callout)
        .lineLimit(1)
        .fixedSize()
        // The icon alone needs no capsule: the route keeps that room.
        .padding(.horizontal, showsWord ? Space.xs : 0)
        .padding(.vertical, showsWord ? 1 : 0)
        .background(showsWord ? AnyShapeStyle(StatusColors.finding.quaternary) : AnyShapeStyle(.clear), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(kind.title)
    }
}

/// The findings strip under the waterfall header (S-023+): one line per
/// finding, three at most, then "Show All Findings (7)". A line selects its span.
struct FindingsStrip: View {
    @Environment(AppModel.self) private var model

    /// Expanded, the lines scroll past this height, so the waterfall keeps its room.
    static let expandedMaxHeight: CGFloat = 160

    var body: some View {
        let findings = model.openTraceFindings
        if !findings.isEmpty {
            VStack(alignment: .leading, spacing: Space.xs) {
                if model.showsAllFindings {
                    ScrollView {
                        lines(findings.shownInStrip(all: true), in: findings)
                    }
                    .frame(maxHeight: Self.expandedMaxHeight)
                    .scrollBounceBehavior(.basedOnSize)
                } else {
                    lines(findings.shownInStrip(all: false), in: findings)
                }
                if let title = findings.showAllTitle {
                    Button(model.showsAllFindings ? "Show Less" : title) { model.showsAllFindings.toggle() }
                        .buttonStyle(.link)
                }
            }
            .padding(.horizontal, Space.lg)
            .padding(.bottom, Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .gridArea("findings-strip", inset: Space.lg)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Findings")
        }
    }

    /// Each line says what and where; its tooltip is the span detail's text (detector audit 8).
    private func lines(_ shown: ArraySlice<Finding>, in findings: TraceFindings) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            ForEach(shown) { finding in
                let place = findings.place(for: finding)
                Button {
                    model.selectFinding(finding)
                } label: {
                    HStack(spacing: Space.xs) {
                        Image(systemName: finding.kind.symbol)
                            .foregroundStyle(StatusColors.finding)
                        Text(finding.line(in: place))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(finding.detailText(in: place))
                .accessibilityLabel(finding.accessibilityLabel(in: place))
                .accessibilityHint(finding.accessibilityHint(in: place) ?? "")
                .gridProbe("finding-\(finding.id)", area: "findings-strip")
            }
        }
    }
}

/// The span detail's Findings section, first (S-023 Flow): per finding its
/// title, why it was flagged, and the statement, monospaced, three lines
/// then "Show All".
struct FindingList: View {
    let findings: [Finding]
    /// Where each one is, by finding id (`TraceFindings.places`).
    var places: [String: FindingPlace] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            ForEach(findings) { finding in
                VStack(alignment: .leading, spacing: Space.xs) {
                    Label {
                        Text(finding.kind.title)
                            .fontWeight(.semibold)
                    } icon: {
                        Image(systemName: finding.kind.symbol)
                            .foregroundStyle(StatusColors.finding)
                    }
                    .accessibilityAddTraits(.isHeader)
                    Text(finding.detailText(in: places[finding.id]))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if let statement = finding.shownStatement {
                        ExpandableText(text: statement, id: SpanDetailValueID.finding(finding.id), monospaced: true)
                    }
                }
            }
        }
    }
}
