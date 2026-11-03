import AppKit
import MagnifeKit

/// S-031: the palette as the app resolves it, against the backgrounds AppKit
/// draws in each appearance, and the Increase Contrast marks (the bar's
/// border, the dot's ring) as they render.
extension SelfTest {
    /// `NSAppearance(named:)` cannot make a high-contrast appearance, so the
    /// Increase Contrast rounds set the override that snapshots use too.
    static let appearances: [(NSAppearance.Name, Bool, String)] = [
        (.aqua, false, "light"), (.darkAqua, false, "dark"),
        (.aqua, true, "light, Increase Contrast"), (.darkAqua, true, "dark, Increase Contrast"),
    ]

    static func checkAppearance(_ model: AppModel) async {
        let system = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        if system { print("INFO Increase Contrast is on in System Settings: the plain rounds read as increased") }
        defer { DisplayOverrides.increaseContrast = false }
        for (name, forced, words) in appearances {
            guard let appearance = NSAppearance(named: name) else { continue }
            DisplayOverrides.increaseContrast = forced
            let increased = appearance.isHighContrast
            check("\(words): the appearance reads as \(forced ? "increased" : "standard") contrast",
                  increased == (forced || system))
            var backgrounds: [UInt32] = []
            var graphics: [UInt32] = []
            var texts: [UInt32] = []
            appearance.performAsCurrentDrawingAppearance {
                let base = NSColor.controlBackgroundColor
                backgrounds = [base, .windowBackgroundColor, .underPageBackgroundColor,
                               NSColor.alternatingContentBackgroundColors[1]].map { hex(of: $0, over: base) }
                graphics = (ServicePalette.nsColors + [StatusColors.errorFillNS]).map { hex(of: $0, over: base) }
                texts = [StatusColors.errorNS, StatusColors.findingNS].map { hex(of: $0, over: base) }
            }
            let graphicLowest = graphics.map { Contrast.lowest($0, against: backgrounds) }.min() ?? 0
            let textLowest = texts.map { Contrast.lowest($0, against: backgrounds) }.min() ?? 0
            let (graphicNeed, textNeed) = increased
                ? (ColorPalette.highContrastGraphic, ColorPalette.highContrastText)
                : (ColorPalette.graphicContrast, ColorPalette.textContrast)
            check("\(words): service colors, Error bars keep \(graphicNeed):1 against the window's backgrounds",
                  graphicLowest >= graphicNeed, String(format: "lowest %.2f", graphicLowest))
            check("\(words): the Error and finding words keep \(textNeed):1",
                  textLowest >= textNeed, String(format: "lowest %.2f", textLowest))

            let bar = renderBar(in: appearance)
            check("\(words): a waterfall bar \(increased ? "has a" : "has no") 1 pt border",
                  bar.map { differs($0.edge, $0.fill) == increased } ?? false,
                  bar.map { "edge \(String($0.edge, radix: 16)), fill \(String($0.fill, radix: 16))" } ?? "no bitmap")
            let dot = renderDot(in: appearance)
            check("\(words): a service dot \(increased ? "has a" : "has no") ring",
                  dot.map { differs($0.edge, $0.fill) == increased } ?? false,
                  dot.map { "edge \(String($0.edge, radix: 16)), fill \(String($0.fill, radix: 16))" } ?? "no bitmap")
        }
    }

    /// A color as sRGB hex, composited over `base` when it is translucent.
    private static func hex(of color: NSColor, over base: NSColor) -> UInt32 {
        guard let color = color.usingColorSpace(.sRGB), let base = base.usingColorSpace(.sRGB) else { return 0 }
        let alpha = color.alphaComponent
        func channel(_ top: CGFloat, _ bottom: CGFloat) -> UInt32 {
            UInt32(((top * alpha + bottom * (1 - alpha)) * 255).rounded())
        }
        return channel(color.redComponent, base.redComponent) << 16
            | channel(color.greenComponent, base.greenComponent) << 8
            | channel(color.blueComponent, base.blueComponent)
    }

    /// A blue bar over a whole 200 pt track: the pixel on its top edge and one inside.
    private static func renderBar(in appearance: NSAppearance) -> (edge: UInt32, fill: UInt32)? {
        let view = SpanBarView(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        view.appearance = appearance
        view.start = 0.25
        view.width = 0.5
        view.color = ServicePalette.nsColor(slot: 0)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let top = Int(((view.bounds.height - Timeline.barHeight) / 2 * scale).rounded())
        let x = Int(100 * scale)
        return (pixel(rep, x: x, y: top), pixel(rep, x: x, y: Int(view.bounds.midY * scale)))
    }

    /// The trace list's dot: the pixel on its left edge and the one in its middle.
    private static func renderDot(in appearance: NSAppearance) -> (edge: UInt32, fill: UInt32)? {
        let image = ServiceDots.image(.row, slot: 0)
        let view = NSImageView(frame: NSRect(origin: .zero, size: image.size))
        view.image = image
        view.appearance = appearance
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let (midX, midY) = (rep.pixelsWide / 2, rep.pixelsHigh / 2)
        // The first pixel from the left that is more than half opaque.
        let edge = (0..<midX).first { (rep.colorAt(x: $0, y: midY)?.alphaComponent ?? 0) > 0.5 } ?? 0
        return (pixel(rep, x: edge, y: midY), pixel(rep, x: midX, y: midY))
    }

    /// Two pixels apart by more than edge smoothing.
    private static func differs(_ first: UInt32, _ second: UInt32) -> Bool {
        let channels = [16, 8, 0].map { shift in abs(Int((first >> UInt32(shift)) & 0xFF) - Int((second >> UInt32(shift)) & 0xFF)) }
        return channels.max() ?? 0 > 48
    }

    private static func pixel(_ rep: NSBitmapImageRep, x: Int, y: Int) -> UInt32 {
        guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return 0 }
        func channel(_ value: CGFloat) -> UInt32 { UInt32((value * 255).rounded()) }
        return channel(color.redComponent) << 16 | channel(color.greenComponent) << 8 | channel(color.blueComponent)
    }
}
