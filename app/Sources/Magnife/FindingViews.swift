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

/// One finding kind: the orange icon and its name, on an orange-tinted
/// capsule. The word stays in the primary text color: system orange text
/// is too faint on a light background (as Warn's word, decision 73).
struct FindingBadge: View {
    let kind: FindingKind
    var showsWord = true

    var body: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: kind.symbol)
                .foregroundStyle(.orange)
            if showsWord { Text(kind.title) }
        }
        .font(.callout)
        .lineLimit(1)
        .fixedSize()
        // The icon alone needs no capsule: the route keeps that room.
        .padding(.horizontal, showsWord ? Space.xs : 0)
        .padding(.vertical, showsWord ? 1 : 0)
        .background(showsWord ? AnyShapeStyle(.orange.quaternary) : AnyShapeStyle(.clear), in: Capsule())
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
                        lines(findings.shownInStrip(all: true))
                    }
                    .frame(maxHeight: Self.expandedMaxHeight)
                    .scrollBounceBehavior(.basedOnSize)
                } else {
                    lines(findings.shownInStrip(all: false))
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

    private func lines(_ findings: ArraySlice<Finding>) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            ForEach(findings) { finding in
                Button {
                    model.selectFinding(finding)
                } label: {
                    HStack(spacing: Space.xs) {
                        Image(systemName: finding.kind.symbol)
                            .foregroundStyle(.orange)
                        Text(finding.line)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(finding.line)
                .accessibilityLabel(finding.accessibilityLabel)
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

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            ForEach(findings) { finding in
                VStack(alignment: .leading, spacing: Space.xs) {
                    Label {
                        Text(finding.kind.title)
                            .fontWeight(.semibold)
                    } icon: {
                        Image(systemName: finding.kind.symbol)
                            .foregroundStyle(.orange)
                    }
                    .accessibilityAddTraits(.isHeader)
                    Text(finding.detailText)
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
