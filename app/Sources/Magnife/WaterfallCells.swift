import AppKit
import MagnifeKit

/// The waterfall's Span column: service dot, the octagon for an Error span,
/// an orange icon per finding kind (S-023+), the name (truncated, full name in the tooltip), the service where it
/// differs from the parent's, and the duration at the trailing edge, where a
/// bar can never cover it. A collapsed span's "N spans" sits by its bar,
/// where the timeline has room (a narrow Span column clipped it here).
final class SpanNameCell: NSTableCellView {
    private let dot = NSImageView()
    private let octagon = NSImageView()
    /// One icon per finding kind, shown when the span carries it.
    private let marks = FindingKind.allCases.map { kind in
        let view = NSImageView()
        view.image = NSImage(systemSymbolName: kind.symbol, accessibilityDescription: kind.title)
        view.contentTintColor = StatusColors.findingNS
        view.isHidden = true
        return view
    }
    private let name = NSTextField(labelWithString: "")
    private let service = NSTextField(labelWithString: "")
    private let duration = NSTextField(labelWithString: "")
    /// Narrower than this, a service name would show one or two letters.
    private static let serviceMinimum: CGFloat = 40
    /// The share of the text's room the service keeps when name and service
    /// do not both fit, so both show, each cut with "…" (S-005 Words).
    private static let serviceShare: CGFloat = 0.35
    private let spacer = NSView()
    private lazy var serviceWidth: NSLayoutConstraint = {
        let constraint = service.widthAnchor.constraint(greaterThanOrEqualToConstant: 0)
        // Above the name's compression resistance (251), below required.
        constraint.priority = .init(252)
        constraint.isActive = true
        return constraint
    }()

    init() {
        super.init(frame: .zero)
        dot.image = ServiceDots.image(.waterfall, slot: 0)
        octagon.image = NSImage(systemSymbolName: "exclamationmark.octagon.fill", accessibilityDescription: "Error")
        octagon.contentTintColor = StatusColors.errorNS
        for label in [name, service] {
            // One line that ends in "…", never a clipped word.
            label.maximumNumberOfLines = 1
            label.cell?.wraps = false
            label.lineBreakMode = .byTruncatingTail
        }
        service.textColor = .secondaryLabelColor
        duration.textColor = .secondaryLabelColor
        duration.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        duration.alignment = .right
        for view in [dot, octagon, name, service, duration] + marks { view.setContentHuggingPriority(.required, for: .horizontal) }
        duration.setContentCompressionResistancePriority(.required, for: .horizontal)
        // When space runs out the service gives way first, then the name
        // truncates; a service with no room for a few letters is not drawn
        // (layout), and the tooltip names it.
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        service.setContentCompressionResistancePriority(.init(249), for: .horizontal)
        name.setContentCompressionResistancePriority(.init(251), for: .horizontal)
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = NSStackView(views: [dot, octagon] + marks + [name, service, spacer, duration])
        stack.spacing = Space.xs
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        textField = name
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Space.xs),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Space.sm),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        // VoiceOver reads the row as one sentence (S-005 Access).
        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
        for view in [dot, octagon, name, service, duration] + marks { view.setAccessibilityElement(false) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        reserveServiceRoom()
        super.layout()
        let needed = min(Self.serviceMinimum, service.intrinsicContentSize.width)
        service.alphaValue = service.frame.width + 0.5 >= needed ? 1 : 0
    }

    /// The room the name and service share: the cell less the dot, the
    /// octagon, the duration, the margins and the gaps between them.
    private var textRoom: CGFloat {
        let fixed = ([dot, octagon, duration] + marks).filter { !$0.isHidden }.map(\.intrinsicContentSize.width).reduce(0, +)
        let gaps = CGFloat(([dot, octagon, name, service, spacer, duration] + marks).filter { !$0.isHidden }.count - 1) * Space.xs
        return bounds.width - Space.xs - Space.sm - fixed - gaps
    }

    /// A service that would not fit next to the whole name keeps a share of
    /// the room, at least a few letters' worth; in a cell too narrow for
    /// both, the name takes it all.
    private func reserveServiceRoom() {
        guard !service.isHidden else {
            if serviceWidth.constant != 0 { serviceWidth.constant = 0 }
            return
        }
        let room = textRoom
        let full = service.intrinsicContentSize.width
        let share = (room * Self.serviceShare).rounded(.down)
        let wanted = share >= Self.serviceMinimum ? min(full, share) : 0
        if serviceWidth.constant != wanted { serviceWidth.constant = wanted }
    }

    /// The service name shows, at least partly (self-test).
    var showsService: Bool { !service.isHidden && service.alphaValue > 0 && service.frame.width > 0 }

    /// The octagon shows (self-test).
    var showsError: Bool { !octagon.isHidden }

    /// The dot image draws itself in the current appearance.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        dot.needsDisplay = true
    }

    /// The finding icons shown, in order (self-test).
    var shownFindings: [FindingKind] { zip(FindingKind.allCases, marks).filter { !$0.1.isHidden }.map(\.0) }

    func configure(name text: String, service shown: String?, duration time: String, colorSlot: Int, isError: Bool,
                   findings: [FindingKind] = [], hiddenCount: Int, isOrphan: Bool, label: String) {
        duration.stringValue = time
        dot.image = ServiceDots.image(.waterfall, slot: colorSlot)
        octagon.isHidden = !isError
        for (kind, mark) in zip(FindingKind.allCases, marks) { mark.isHidden = !findings.contains(kind) }
        name.stringValue = text
        service.stringValue = shown ?? ""
        service.isHidden = shown == nil
        // A span whose parent never arrived says so (S-005 States).
        let named = shown.map { "\(text) · \($0)" } ?? text
        var help = hiddenCount == 0 ? named : "\(named) (\(TraceList.spansText(hiddenCount)))"
        if isOrphan { help += " · \(Waterfall.orphanHelp)" }
        if !findings.isEmpty { help += " · " + findings.map(\.title).joined(separator: ", ") }
        toolTip = help
        name.toolTip = help
        setAccessibilityLabel(hiddenCount == 0 ? label : "\(label), \(TraceList.spansText(hiddenCount))")
    }
}

/// The waterfall's bar column: the span's bar placed and sized by its start
/// and duration within the trace, over quarter lines that match the header's
/// scale, with "N spans" beside it while the span is collapsed.
final class SpanBarCell: NSTableCellView {
    private let bar = SpanBarView()

    init() {
        super.init(frame: .zero)
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The bar's start and width as fractions of the trace (self-test).
    var fractions: (start: Double, width: Double) { (bar.start, bar.width) }
    /// The collapsed span count shown by the bar (self-test).
    var hiddenCountText: String? { bar.note }

    func configure(start: Double, width: Double, color: NSColor, note: String?) {
        bar.start = start
        bar.width = width
        bar.color = color
        bar.note = note
        bar.needsDisplay = true
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            bar.isEmphasized = backgroundStyle == .emphasized
            bar.needsDisplay = true
        }
    }
}

/// Where the timeline sits inside the bar column: the bar cells and the
/// header scale share it.
enum Timeline {
    static let inset = Space.sm
    static let barHeight: CGFloat = 12
    static let quarters: [Double] = [0.25, 0.5, 0.75]

    static func track(in rect: NSRect) -> NSRect {
        rect.insetBy(dx: inset, dy: 0)
    }
}

final class SpanBarView: NSView {
    var start = 0.0
    var width = 0.0
    var color = ServicePalette.nsColor(slot: 0)
    var note: String?
    var isEmphasized = false

    override var isFlipped: Bool { true }

    /// Light, dark and Increase Contrast redraw the bar in their colors at once.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = Timeline.track(in: bounds)
        NSColor.separatorColor.setFill()
        for quarter in Timeline.quarters {
            NSRect(x: (track.minX + quarter * track.width).rounded(), y: 0, width: 1, height: bounds.height).fill()
        }
        let x = track.minX + start * track.width
        let barWidth = max(2, width * track.width)
        let rect = NSRect(x: x, y: (bounds.height - Timeline.barHeight) / 2, width: barWidth, height: Timeline.barHeight)
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: Radius.bar, yRadius: Radius.bar).fill()
        // Increase Contrast: a 1 pt border in the label color (S-031).
        if effectiveAppearance.isHighContrast {
            let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: Radius.bar, yRadius: Radius.bar)
            border.lineWidth = 1
            StatusColors.contrastEdgeNS.setStroke()
            border.stroke()
        }
        guard let note else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
            .foregroundColor: isEmphasized ? NSColor.alternateSelectedControlTextColor : NSColor.secondaryLabelColor,
        ]
        let text = note as NSString
        let size = text.size(withAttributes: attributes)
        // Right of the bar, else left of it; with room on neither side the
        // row's tooltip and VoiceOver label still carry it.
        var textX = rect.maxX + Space.xs
        if textX + size.width > track.maxX { textX = rect.minX - Space.xs - size.width }
        guard textX >= track.minX else { return }
        text.draw(at: NSPoint(x: textX, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
}

/// The bar column's header: the trace's time scale at each quarter line.
final class TimelineHeaderCell: NSTableHeaderCell {
    var durationNs: Int64 = 0

    init() {
        super.init(textCell: "")
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        guard durationNs > 0 else { return }
        let track = Timeline.track(in: cellFrame)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        // From the trace's end leftward; a label that would touch the one
        // to its right is left out, so narrow columns show fewer labels.
        var limit = track.maxX + Space.xs
        for fraction in ([1] + Timeline.quarters.reversed()) {
            let text = DurationFormat.string(nanoseconds: Int64((Double(durationNs) * fraction).rounded())) as NSString
            let size = text.size(withAttributes: attributes)
            // Each label ends at its line, the last one at the trace's end.
            let lineX = track.minX + fraction * track.width
            let x = fraction == 1 ? track.maxX - size.width : lineX - size.width - Space.xs
            guard x >= track.minX, x + size.width + Space.xs <= limit else { continue }
            text.draw(at: NSPoint(x: x, y: cellFrame.midY - size.height / 2), withAttributes: attributes)
            limit = x
        }
    }
}
