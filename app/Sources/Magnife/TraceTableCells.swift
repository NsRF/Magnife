import AppKit
import MagnifeKit
import SwiftUI

/// The live lists' cells (S-004, S-013, S-030): plain AppKit views, so
/// drawing a row never runs the window's SwiftUI graph inside the table's
/// own callbacks (FIXLOG). Only the Route column (finding badges) and the
/// Logs list's Level and Body host SwiftUI, each in a hosting view of its
/// own that is given values, never the model (`HostingCell`).
extension NSUserInterfaceItemIdentifier {
    static let traceService = NSUserInterfaceItemIdentifier("trace-service")
    static let traceRoute = NSUserInterfaceItemIdentifier("trace-route")
    static let traceDuration = NSUserInterfaceItemIdentifier("trace-duration")
    static let traceSpans = NSUserInterfaceItemIdentifier("trace-spans")
    static let traceStatus = NSUserInterfaceItemIdentifier("trace-status")
    static let traceTime = NSUserInterfaceItemIdentifier("trace-time")
}

/// A text, an optional leading image, and the row's sentence for VoiceOver
/// on the first cell only (the others are hidden from it, S-004 Access).
final class TraceTextCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()

    init(identifier: NSUserInterfaceItemIdentifier, alignment: NSTextAlignment = .natural, digits: Bool = false,
         truncation: NSLineBreakMode = .byTruncatingTail) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.alignment = alignment
        label.maximumNumberOfLines = 1
        label.cell?.wraps = false
        label.lineBreakMode = truncation
        label.font = digits ? .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            : .systemFont(ofSize: NSFont.systemFontSize)
        icon.isHidden = true
        // Frames, not constraints: adding a row view with constraints to the
        // window's layout engine cost most of the main thread under a flood (S-030).
        addSubview(icon)
        addSubview(label)
        textField = label
        for view in [self, label, icon] as [NSView] { view.setAccessibilityElement(false) }
    }

    /// The icon at the leading edge, the text in the rest, both centered on the row.
    override func layout() {
        super.layout()
        var x: CGFloat = 0
        if !icon.isHidden, let size = icon.image?.size {
            icon.frame = NSRect(x: 0, y: ((bounds.height - size.height) / 2).rounded(), width: size.width, height: size.height)
            x = size.width + Space.xs
        }
        let height = label.intrinsicContentSize.height
        label.frame = NSRect(x: x, y: ((bounds.height - height) / 2).rounded(), width: max(0, bounds.width - x), height: height)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ text: String, color: NSColor = .labelColor, image: NSImage? = nil, imageTint: NSColor? = nil,
                   tooltip: String? = nil) {
        if label.stringValue != text { label.stringValue = text }
        label.textColor = color
        if icon.image !== image || icon.isHidden != (image == nil) {
            icon.image = image
            icon.isHidden = image == nil
            needsLayout = true
        }
        icon.contentTintColor = imageTint
        toolTip = tooltip
    }
}

extension TraceTextCell {
    static let dot = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(textStyle: .body, scale: .small))
    private static let octagon = NSImage(systemSymbolName: "exclamationmark.octagon.fill", accessibilityDescription: nil)

    /// The cell for a column of the trace list, made or reused.
    static func make(_ identifier: NSUserInterfaceItemIdentifier, in table: NSTableView) -> NSTableCellView {
        if let cell = table.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView { return cell }
        switch identifier {
        case .traceRoute: return HostingCell(identifier: identifier, view: RouteCell(route: "", findings: nil))
        case .traceDuration, .traceSpans: return TraceTextCell(identifier: identifier, alignment: .right, digits: true)
        case .traceTime: return TraceTextCell(identifier: identifier, digits: true)
        default: return TraceTextCell(identifier: identifier)
        }
    }

    /// Fills a cell with its trace's value for the column.
    static func fill(_ cell: NSTableCellView, with trace: TraceSummary, findings: FindingSummary?, now: Date,
                     colors: ServiceColors) {
        if let route = cell as? HostingCell<RouteCell> {
            if route.view.route != trace.route || route.view.findings != findings {
                route.view = RouteCell(route: trace.route, findings: findings)
            }
            return
        }
        guard let cell = cell as? TraceTextCell else { return }
        switch cell.identifier {
        case .traceService:
            cell.configure(trace.rootService, image: dot,
                           imageTint: ServicePalette.nsColor(slot: colors.slot(for: trace.rootService)))
        case .traceDuration:
            cell.configure(DurationFormat.string(nanoseconds: trace.durationNs))
        case .traceSpans:
            cell.configure(trace.spanCount.formatted())
        case .traceStatus:
            // Error pairs the octagon with the word; OK is the word; Unset is blank.
            switch trace.status {
            case .error: cell.configure(trace.status.title, color: .systemRed, image: octagon, imageTint: .systemRed)
            case .ok: cell.configure(trace.status.title)
            case .unset: cell.configure("")
            }
        case .traceTime:
            cell.configure(RelativeTime.string(for: trace.start, now: now), color: .secondaryLabelColor)
        default:
            break
        }
    }
}
