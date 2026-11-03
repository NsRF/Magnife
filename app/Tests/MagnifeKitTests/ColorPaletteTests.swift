import Foundation
import Testing
@testable import MagnifeKit

/// docs/ux.md S-031: status red, finding orange and all ten service colors
/// keep 4.5:1 for text and 3:1 for bars against the background, in light and
/// dark, and more with Increase Contrast.
@Suite("Color palette")
struct ColorPaletteTests {
    @Test("contrast ratio matches WCAG's reference values")
    func ratio() {
        #expect(abs(Contrast.ratio(0x000000, 0xFFFFFF) - 21) < 0.01)
        #expect(Contrast.ratio(0x777777, 0x777777) == 1)
        // WCAG's own example: #777 on white is just under 4.5.
        #expect(abs(Contrast.ratio(0x767676, 0xFFFFFF) - 4.54) < 0.01)
        #expect(Contrast.ratio(0xFF0000, 0x00FF00) == Contrast.ratio(0x00FF00, 0xFF0000))
    }

    @Test("ten service colors, one per palette slot")
    func serviceCount() {
        #expect(ColorPalette.services.count == ServiceColors.paletteCount)
        #expect(Set(ColorPalette.services.map(\.light)).count == ServiceColors.paletteCount)
        #expect(Set(ColorPalette.services.map(\.dark)).count == ServiceColors.paletteCount)
    }

    @Test("text colors read at 4.5:1, 7:1 with Increase Contrast")
    func text() {
        for color in ColorPalette.textColors {
            check(color, normal: ColorPalette.textContrast, increased: ColorPalette.highContrastText)
        }
    }

    @Test("bars, dots and icons read at 3:1, 4.5:1 with Increase Contrast")
    func graphics() {
        for color in ColorPalette.graphicColors {
            check(color, normal: ColorPalette.graphicContrast, increased: ColorPalette.highContrastGraphic)
        }
    }

    @Test("Increase Contrast never lowers a color's contrast")
    func increasedIsStronger() {
        for color in ColorPalette.textColors + ColorPalette.graphicColors {
            #expect(Contrast.lowest(color.highContrastLight, against: ColorPalette.lightBackgrounds)
                >= Contrast.lowest(color.light, against: ColorPalette.lightBackgrounds))
            #expect(Contrast.lowest(color.highContrastDark, against: ColorPalette.darkBackgrounds)
                >= Contrast.lowest(color.dark, against: ColorPalette.darkBackgrounds))
        }
    }

    @Test("Error and finding never take a service color")
    func statusIsNotAService() {
        let services = Set(ColorPalette.services.flatMap { $0.lightValues + $0.darkValues })
        for color in [ColorPalette.errorText, ColorPalette.errorFill, ColorPalette.finding] {
            #expect(services.isDisjoint(with: color.lightValues + color.darkValues))
        }
    }

    private func check(_ color: ColorValues, normal: Double, increased: Double,
                       sourceLocation: SourceLocation = #_sourceLocation) {
        let cases: [(UInt32, [UInt32], Double)] = [
            (color.light, ColorPalette.lightBackgrounds, normal),
            (color.dark, ColorPalette.darkBackgrounds, normal),
            (color.highContrastLight, ColorPalette.lightBackgrounds, increased),
            (color.highContrastDark, ColorPalette.darkBackgrounds, increased),
        ]
        for (value, backgrounds, minimum) in cases {
            let lowest = Contrast.lowest(value, against: backgrounds)
            #expect(lowest >= minimum, "\(String(value, radix: 16)): \(lowest) < \(minimum)",
                    sourceLocation: sourceLocation)
        }
    }
}
