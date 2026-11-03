import SwiftUI

/// Liquid Glass, or under Reduce Transparency a solid window background with
/// a hairline edge (S-031).
struct PanelSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    let solid: Bool

    func body(content: Content) -> some View {
        if solid {
            content
                .background(.windowBackground, in: shape)
                .overlay(shape.strokeBorder(.separator, lineWidth: 1))
                .shadow(radius: Space.sm)
        } else {
            content.glassEffect(.regular, in: shape)
        }
    }
}

/// Snapshot runs set these to show the Increase Contrast and Reduce
/// Transparency looks, which neither SwiftUI's environment nor
/// `NSAppearance(named:)` can fake. Never set in real runs.
enum DisplayOverrides {
    nonisolated(unsafe) static var increaseContrast = false
    static var reduceTransparency = false
}
