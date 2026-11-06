import AppKit
import MagnifeKit
import SwiftUI

/// One color per service, the same in the sidebar, list, and waterfall
/// (research/design.md, decision 4): docs/ux.md's ten system colors, taken in
/// the order services were first seen (ServiceColors in MagnifeKit). Red is
/// Error and orange is a finding, so neither is a service color. The values
/// are MagnifeKit's `ColorPalette`, checked for contrast in light, dark and
/// Increase Contrast (S-031).
enum ServicePalette {
    static let colors: [Color] = ColorPalette.services.map(Color.init)

    /// The same ten as AppKit colors, for the waterfall's bars (S-005).
    static let nsColors: [NSColor] = ColorPalette.services.map(NSColor.init)

    static func color(slot: Int) -> Color {
        colors[slot % colors.count]
    }

    static func nsColor(slot: Int) -> NSColor {
        nsColors[slot % nsColors.count]
    }
}

/// Error, finding and warning colors (docs/ux.md, Colors). Never `.red`,
/// `.orange` or `.yellow` in a view: the system colors are too light for text
/// on a light background.
enum StatusColors {
    /// The Error word and its octagon, the sidebar's counts, the Error chips.
    static let error = Color(ColorPalette.errorText)
    static let errorNS = NSColor(ColorPalette.errorText)
    /// An Error span's waterfall bar and the menu bar glyph's red.
    static let errorFillNS = NSColor(ColorPalette.errorFill)
    /// Finding badges, strip lines and icons.
    static let finding = Color(ColorPalette.finding)
    static let findingNS = NSColor(ColorPalette.finding)
    /// The Warn level's triangle.
    static let warning = Color(ColorPalette.warning)
    static let warningNS = NSColor(ColorPalette.warning)
    /// Increase Contrast's 1 pt border on waterfall bars and ring on service
    /// dots: the label color, clear otherwise, so views always draw it and
    /// it appears and goes with the setting.
    static let contrastEdgeNS = NSColor(name: nil) { $0.isHighContrast ? .labelColor : .clear }
    static let contrastEdge = Color(nsColor: contrastEdgeNS)
}

extension Color {
    nonisolated init(_ values: ColorValues) {
        self.init(light: values.light, dark: values.dark,
                  highContrastLight: values.highContrastLight, highContrastDark: values.highContrastDark)
    }
}

extension NSColor {
    /// A dynamic color that resolves to the appearance it is drawn in.
    nonisolated convenience init(_ values: ColorValues) {
        self.init(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua,
                                                   .accessibilityHighContrastDarkAqua])
            let isDark = dark == .darkAqua || dark == .accessibilityHighContrastDarkAqua
            return switch (isDark, appearance.isHighContrast) {
            case (false, false): NSColor(hex: values.light)
            case (true, false): NSColor(hex: values.dark)
            case (false, true): NSColor(hex: values.highContrastLight)
            case (true, true): NSColor(hex: values.highContrastDark)
            }
        }
    }
}

extension NSAppearance {
    /// True under Increase Contrast (System Settings > Accessibility >
    /// Display). `NSAppearance(named:)` cannot make a high-contrast
    /// appearance, so snapshot runs set `DisplayOverrides.increaseContrast`.
    nonisolated var isHighContrast: Bool {
        let match = bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
        return match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua
            || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast || DisplayOverrides.increaseContrast
    }
}

/// Service dots for AppKit cells: the symbol's circle in the service's color,
/// with a ring in the label color under Increase Contrast (S-031). Drawn
/// when shown, so one image follows every appearance change.
enum ServiceDots {
    enum Size: CaseIterable {
        /// The trace list and Logs rows, beside body text.
        case row
        /// The waterfall's Span column.
        case waterfall

        var configuration: NSImage.SymbolConfiguration {
            switch self {
            case .row: .init(textStyle: .body, scale: .small)
            case .waterfall: .init(pointSize: 7, weight: .regular) // grid: ok symbol size
            }
        }
    }

    private static var cache: [Size: [NSImage]] = [:]

    static func image(_ size: Size, slot: Int) -> NSImage {
        if cache[size] == nil {
            cache[size] = (0..<ServicePalette.nsColors.count).map { make(size, color: ServicePalette.nsColors[$0]) }
        }
        let images = cache[size] ?? []
        return images[slot % images.count]
    }

    private static func make(_ size: Size, color: NSColor) -> NSImage {
        let configuration = size.configuration
        let fill = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) ?? NSImage()
        // The outline symbol has the filled one's outer edge, so it rings the dot.
        let outline = NSImage(systemSymbolName: "circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) ?? NSImage()
        let (dot, ring) = (fill, outline)
        let image = NSImage(size: fill.size, flipped: false) { rect in
            draw(dot, color: color, in: rect)
            if NSAppearance.currentDrawing().isHighContrast { draw(ring, color: StatusColors.contrastEdgeNS, in: rect) }
            return true
        }
        image.cacheMode = .never
        return image
    }

    /// The template symbol filled with `color`, in its own layer so the fill
    /// touches only the symbol's pixels.
    private nonisolated static func draw(_ symbol: NSImage, color: NSColor, in rect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        symbol.draw(in: rect)
        color.setFill()
        rect.fill(using: .sourceAtop)
        context.endTransparencyLayer()
    }
}
