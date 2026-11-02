import AppKit
import MagnifeKit
import SwiftUI

/// The detail column's vertical split: the waterfall on top, the span
/// detail below (docs/ux.md, Window: 55 / 45 by default). An NSSplitView,
/// because SwiftUI's VSplitView can neither set nor remember its divider
/// and cannot hide a pane; the divider position is remembered across
/// launches (not in test and snapshot runs), and a hidden bottom pane
/// gives the waterfall the whole column.
struct DetailSplit<Top: View, Bottom: View>: NSViewRepresentable {
    let showsBottom: Bool
    let top: Top
    let bottom: Bottom

    /// The waterfall's share of the column when nothing is remembered.
    static var defaultFraction: CGFloat { 0.55 }

    func makeCoordinator() -> DetailSplitCoordinator { DetailSplitCoordinator() }

    func makeNSView(context: Context) -> NSSplitView {
        let split = RememberingSplitView()
        split.isVertical = false
        split.dividerStyle = .thin
        split.delegate = context.coordinator
        split.fraction = DetailSplitCoordinator.storedFraction ?? Self.defaultFraction
        for view in [AnyView(top), AnyView(bottom)] {
            let host = NSHostingView(rootView: view)
            // The split sets the sizes; the hosted views only fill them.
            host.sizingOptions = []
            split.addArrangedSubview(host)
        }
        // Equal priorities: a taller window grows both panes in proportion.
        split.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        split.arrangedSubviews[1].isHidden = !showsBottom
        split.setAccessibilityLabel("Detail")
        return split
    }

    func updateNSView(_ split: NSSplitView, context: Context) {
        (split.arrangedSubviews[0] as? NSHostingView<AnyView>)?.rootView = AnyView(top)
        (split.arrangedSubviews[1] as? NSHostingView<AnyView>)?.rootView = AnyView(bottom)
        let bottomView = split.arrangedSubviews[1]
        guard bottomView.isHidden == showsBottom else { return }
        bottomView.isHidden = !showsBottom
        (split as? RememberingSplitView)?.layoutPanes()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSplitView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 420, height: proposal.height ?? 640)
    }
}

/// Keeps the divider at `fraction` of the height through every resize; a
/// hidden bottom pane gives the top one the whole height.
final class RememberingSplitView: NSSplitView {
    var fraction: CGFloat = 0.55
    /// True while this view sets its panes' frames, so that is not saved as a drag.
    private(set) var isApplying = false

    func layoutPanes() {
        guard arrangedSubviews.count == 2 else { return adjustSubviews() }
        isApplying = true
        defer { isApplying = false }
        let (top, bottom) = (arrangedSubviews[0], arrangedSubviews[1])
        guard !bottom.isHidden else {
            top.frame = bounds
            return
        }
        let total = bounds.height - dividerThickness
        let minimum = min(DetailSplitCoordinator.minimumPane, total / 2)
        let height = min(max((total * fraction).rounded(), minimum), total - minimum)
        top.frame = NSRect(x: 0, y: 0, width: bounds.width, height: height)
        bottom.frame = NSRect(x: 0, y: height + dividerThickness, width: bounds.width, height: total - height)
    }

    /// The waterfall's share of the column, as laid out now.
    var currentFraction: CGFloat {
        let total = bounds.height - dividerThickness
        guard total > 0, arrangedSubviews.count == 2, !arrangedSubviews[1].isHidden else { return fraction }
        return arrangedSubviews[0].frame.height / total
    }
}

final class DetailSplitCoordinator: NSObject, NSSplitViewDelegate {
    private static let key = "detail.splitFraction"
    /// Neither pane gets smaller than this.
    static let minimumPane: CGFloat = 120

    static var storedFraction: CGFloat? {
        guard !StoreLocation.isOverridden(), let value = UserDefaults.standard.object(forKey: key) as? Double,
              (0.1...0.9).contains(value) else { return nil }
        return value
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        Self.minimumPane
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        splitView.bounds.height - splitView.dividerThickness - Self.minimumPane
    }

    /// Every resize keeps the fraction (AppKit's own split would share the change evenly).
    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        guard let split = splitView as? RememberingSplitView else { return splitView.adjustSubviews() }
        split.layoutPanes()
    }

    /// A drag of the divider: remember where it was left.
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard let split = notification.object as? RememberingSplitView, !split.isApplying,
              notification.userInfo?["NSSplitViewDividerIndex"] != nil else { return }
        split.fraction = split.currentFraction
        if !StoreLocation.isOverridden() { UserDefaults.standard.set(Double(split.fraction), forKey: Self.key) }
    }
}
