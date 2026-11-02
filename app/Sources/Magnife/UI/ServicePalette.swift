import MagnifeKit
import SwiftUI

/// One color per service, the same in the sidebar, list, and waterfall
/// (research/design.md, decision 4): docs/ux.md's ten system colors, taken in
/// the order services were first seen (ServiceColors in MagnifeKit). Red is
/// Error and orange is a finding, so neither is a service color.
enum ServicePalette {
    static let colors: [Color] = [.blue, .green, .purple, .teal, .pink, .indigo, .brown, .mint, .cyan, .yellow]

    static func color(slot: Int) -> Color {
        colors[slot % colors.count]
    }
}
