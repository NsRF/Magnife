import Foundation

/// One color in the four appearances macOS draws: light, dark, and each with
/// Increase Contrast. Values are sRGB hex, 0xRRGGBB.
public struct ColorValues: Sendable, Equatable {
    public let light: UInt32
    public let dark: UInt32
    public let highContrastLight: UInt32
    public let highContrastDark: UInt32

    public init(light: UInt32, dark: UInt32, highContrastLight: UInt32, highContrastDark: UInt32) {
        self.light = light
        self.dark = dark
        self.highContrastLight = highContrastLight
        self.highContrastDark = highContrastDark
    }

    /// The four values with the background each one is read against.
    public var lightValues: [UInt32] { [light, highContrastLight] }
    public var darkValues: [UInt32] { [dark, highContrastDark] }
}

/// Every color Magnife draws besides the system's own label, background and
/// accent colors (docs/ux.md, Colors and S-031). Each is the system color of
/// the same name where that one already meets the contrast below, else the
/// same hue made darker (light) or lighter (dark) until it does:
/// - text (the Error word, finding words): 4.5:1 against the backgrounds,
/// - graphics (bars, dots, icons): 3:1,
/// - with Increase Contrast, text 7:1 and graphics 4.5:1.
/// `ColorPaletteTests` checks every value; the app turns them into dynamic
/// colors (UI/ServicePalette.swift) and draws no other fixed color.
public enum ColorPalette {
    /// The ten service colors, in docs/ux.md's order: blue, green, purple,
    /// teal, pink, indigo, brown, mint, cyan, yellow.
    public static let services: [ColorValues] = [
        ColorValues(light: 0x0088FF, dark: 0x0091FF, highContrastLight: 0x006DCC, highContrastDark: 0x29A3FF),
        ColorValues(light: 0x299D46, dark: 0x30D158, highContrastLight: 0x207C38, highContrastDark: 0x30D158),
        ColorValues(light: 0xCB30E0, dark: 0xDB34F2, highContrastLight: 0xB71ECB, highContrastDark: 0xE56BF6),
        ColorValues(light: 0x0098A2, dark: 0x00D2E0, highContrastLight: 0x007981, highContrastDark: 0x00D2E0),
        ColorValues(light: 0xFF2D55, dark: 0xFF375F, highContrastLight: 0xDA002A, highContrastDark: 0xFF6A88),
        ColorValues(light: 0x6155F5, dark: 0x6D7CFF, highContrastLight: 0x5F53F5, highContrastDark: 0x8793FF),
        ColorValues(light: 0xAC7F5E, dark: 0xB78A66, highContrastLight: 0x8C6548, highContrastDark: 0xBE9574),
        ColorValues(light: 0x009A8A, dark: 0x00DAC3, highContrastLight: 0x007B6F, highContrastDark: 0x00DAC3),
        ColorValues(light: 0x0096B5, dark: 0x3CD3FE, highContrastLight: 0x00768F, highContrastDark: 0x3CD3FE),
        ColorValues(light: 0xA68500, dark: 0xFFD600, highContrastLight: 0x856A00, highContrastDark: 0xFFD600),
    ]

    /// Error as text and as the octagon beside it: the word, the sidebar
    /// count, the status chips.
    public static let errorText = ColorValues(light: 0xDB0004, dark: 0xFF6D70,
                                              highContrastLight: 0xA80003, highContrastDark: 0xFFABAC)
    /// Error as a fill: an Error span's waterfall bar, the menu bar glyph.
    public static let errorFill = ColorValues(light: 0xFF383C, dark: 0xFF4245,
                                              highContrastLight: 0xDB0004, highContrastDark: 0xFF6D70)
    /// Findings: the badge words and every finding icon.
    public static let finding = ColorValues(light: 0xAF5200, dark: 0xFF9230,
                                            highContrastLight: 0x843E00, highContrastDark: 0xFFB068)
    /// The Warn level's triangle (its word stays the label color).
    public static let warning = ColorValues(light: 0xA68500, dark: 0xFFD600,
                                            highContrastLight: 0x856A00, highContrastDark: 0xFFD600)

    /// The palette colors drawn as text; the rest are graphics.
    public static var textColors: [ColorValues] { [errorText, finding] }
    public static var graphicColors: [ColorValues] { services + [errorFill, warning] }

    /// The backgrounds the colors sit on, measured from the window: the
    /// list and detail (white / 0x1E1E1E), alternating rows, the under-page
    /// background (0x282828), and the sidebar at its darkest (0xF2F2F2 /
    /// 0x333333).
    public static let lightBackgrounds: [UInt32] = [0xFFFFFF, 0xF4F5F5, 0xF2F2F2]
    public static let darkBackgrounds: [UInt32] = [0x1E1E1E, 0x282828, 0x292929, 0x333333]

    public static let textContrast = 4.5
    public static let graphicContrast = 3.0
    public static let highContrastText = 7.0
    public static let highContrastGraphic = 4.5
}

/// WCAG 2 contrast between two sRGB colors.
public enum Contrast {
    public static func ratio(_ first: UInt32, _ second: UInt32) -> Double {
        let (a, b) = (luminance(first), luminance(second))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// The lowest ratio of a color against any of the backgrounds.
    public static func lowest(_ color: UInt32, against backgrounds: [UInt32]) -> Double {
        backgrounds.map { ratio(color, $0) }.min() ?? 1
    }

    public static func luminance(_ hex: UInt32) -> Double {
        func channel(_ shift: UInt32) -> Double {
            let value = Double((hex >> shift) & 0xFF) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }
}
