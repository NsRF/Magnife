// Draws docs/brand/social-preview.png (1280 x 640, GitHub Settings > Social preview).
// Usage: swift app/tools/social_preview.swift docs/brand/magnife-icon.png <a 03-trace-detail-*-dark.png from tools/snap.sh> docs/brand/social-preview.png
import AppKit

let args = CommandLine.arguments
let icon = NSImage(contentsOfFile: args[1])!
let shot = NSImage(contentsOfFile: args[2])!
let size = NSSize(width: 1280, height: 640)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1280, pixelsHigh: 640, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Background: the brand purple (#8d05fc), darker toward the bottom right.
NSGradient(colors: [NSColor(srgbRed: 0.553, green: 0.020, blue: 0.988, alpha: 1),
                    NSColor(srgbRed: 0.27, green: 0.01, blue: 0.52, alpha: 1)])!
    .draw(in: NSRect(origin: .zero, size: size), angle: -35)

// The app window, tilted off the right edge, faded.
NSGraphicsContext.saveGraphicsState()
let t = NSAffineTransform()
t.translateX(by: 830, yBy: -30)
t.rotate(byDegrees: 8)
t.concat()
let shotRect = NSRect(x: 0, y: 0, width: 720, height: 720 * shot.size.height / shot.size.width)
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
shadow.shadowBlurRadius = 40
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set()
NSBezierPath(roundedRect: shotRect, xRadius: 18, yRadius: 18).addClip()
shot.draw(in: shotRect, from: .zero, operation: .sourceOver, fraction: 0.92)
NSGraphicsContext.restoreGraphicsState()

// Icon.
icon.draw(in: NSRect(x: 72, y: 372, width: 168, height: 168), from: .zero, operation: .sourceOver, fraction: 1)

func text(_ s: String, _ font: NSFont, _ color: NSColor, at p: NSPoint, kern: CGFloat = 0) {
    NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .kern: kern]).draw(at: p)
}
let white = NSColor.white
let soft = NSColor(srgbRed: 0.97, green: 0.93, blue: 1.0, alpha: 1)
let brandYellow = NSColor(srgbRed: 0.988, green: 0.859, blue: 0.020, alpha: 1)
text("Magnife", .systemFont(ofSize: 92, weight: .bold), brandYellow, at: NSPoint(x: 70, y: 250), kern: -1.5)
text("OpenTelemetry traces and logs on your Mac,", .systemFont(ofSize: 34, weight: .medium), soft, at: NSPoint(x: 74, y: 196))
text("the moment your app sends them.", .systemFont(ofSize: 34, weight: .medium), soft, at: NSPoint(x: 74, y: 154))
text("Native macOS  ·  SwiftUI + Go  ·  OTLP gRPC & HTTP  ·  Open source", .systemFont(ofSize: 22, weight: .regular),
     soft.withAlphaComponent(0.75), at: NSPoint(x: 74, y: 76))

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[3]))
print("wrote \(args[3])")
