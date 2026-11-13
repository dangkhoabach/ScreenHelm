// Renders the app icon set from code: a display on which half a ship's helm
// rises like the sun, its handles the rays, so the project needs no design
// tool to produce ScreenHelmApp/Resources/Assets.xcassets/AppIcon.appiconset.
//
// Run once (or whenever the look changes):
//   swift scripts/generate-app-icon.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.first!).deletingLastPathComponent().deletingLastPathComponent()
let iconset = root.appendingPathComponent("ScreenHelmApp/Resources/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func withShadow(blur: CGFloat, y: CGFloat, color shadowColor: NSColor, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = blur
    shadow.shadowOffset = NSSize(width: 0, height: y)
    shadow.shadowColor = shadowColor
    shadow.set()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

/// The point `radius` away from `center` at `degrees`, counterclockwise from the right.
func point(_ center: NSPoint, _ radius: CGFloat, _ degrees: CGFloat) -> NSPoint {
    let angle = degrees * .pi / 180
    return NSPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
}

func stroke(from: NSPoint, to: NSPoint, width: CGFloat) {
    let path = NSBezierPath()
    path.lineWidth = width
    path.lineCapStyle = .round
    path.move(to: from)
    path.line(to: to)
    path.stroke()
}

/// Drawn on a 1024-point canvas; every size is scaled down from it.
func drawIcon() {
    // macOS icon grid: the squircle occupies ~80% of the canvas.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    NSGradient(colors: [color(0x1D2B6E), color(0x0A0F26)])!.draw(in: squircle, angle: -90)
    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.14), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: 100, y: 600, width: 824, height: 324), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // The display: a white bezel on its stand.
    let screen = NSRect(x: 176, y: 300, width: 672, height: 448)
    withShadow(blur: 40, y: -14, color: NSColor.black.withAlphaComponent(0.4)) {
        NSColor.white.setFill()
        NSBezierPath(roundedRect: screen.insetBy(dx: -26, dy: -26), xRadius: 56, yRadius: 56).fill()
        let stand = NSBezierPath()
        stand.move(to: NSPoint(x: 452, y: screen.minY - 26))
        stand.line(to: NSPoint(x: 572, y: screen.minY - 26))
        stand.line(to: NSPoint(x: 612, y: 176))
        stand.line(to: NSPoint(x: 412, y: 176))
        stand.close()
        stand.fill()
    }

    // A dawn sky on the screen, and half a helm rising from its bottom
    // edge: spokes and handles as rays, the rim, and the hub as the sun.
    let glass = NSBezierPath(roundedRect: screen, xRadius: 32, yRadius: 32)
    NSGraphicsContext.saveGraphicsState()
    glass.addClip()
    NSGradient(colors: [color(0x1E3A8A), color(0x6D28D9), color(0xF97316)])!.draw(in: glass, angle: -90)
    let center = NSPoint(x: 512, y: screen.minY + 10)
    color(0xFFE1A1).setStroke()
    for index in 0..<7 {
        let degrees = 15 + CGFloat(index) * 25
        stroke(from: point(center, 90, degrees), to: point(center, 236, degrees), width: 22)
        stroke(from: point(center, 262, degrees), to: point(center, 300, degrees), width: 40)
    }
    let rim = NSBezierPath()
    rim.lineWidth = 30
    rim.appendArc(withCenter: center, radius: 222, startAngle: 0, endAngle: 180)
    rim.stroke()
    withShadow(blur: 50, y: 0, color: color(0xFFB13B, 0.9)) {
        color(0xFFC75A).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - 100, y: center.y - 100, width: 200, height: 200)).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
}

var entries: [[String: String]] = []
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let pixels = points * scale
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    context.imageInterpolation = .high
    NSGraphicsContext.current = context
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(pixels) / 1024)
    transform.concat()
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    entries.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
}
let contents: [String: Any] = ["images": entries, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: iconset.appendingPathComponent("Contents.json"))
print("Wrote \(entries.count) icons to \(iconset.path)")
