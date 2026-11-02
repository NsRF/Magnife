import MagnifeKit
import SwiftUI

/// One color per service, the same in the sidebar, list, and waterfall
/// (research/design.md, decision 4). The slot comes from MagnifeKit's
/// ServiceColor, so it is stable across launches. Red and pink are left out:
/// red means Error. Hues alternate, so nearby slots never look alike.
enum ServicePalette {
    static let colors: [Color] = [
        .blue, .purple, .teal, .orange, .indigo, .yellow,
        .cyan, .brown, .green,
        Color(light: 0x8C6BD6, dark: 0xB7A0F2), // lavender
        .mint,
        Color(light: 0x6B7A12, dark: 0xB4C83A), // olive
    ]

    static func color(for service: String) -> Color {
        colors[ServiceColor.slot(for: service, slots: colors.count)]
    }
}
