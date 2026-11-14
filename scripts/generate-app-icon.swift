// Renders the app icon set from code: on the dark rounded square the
// other apps' icons share, a display with a ship's helm on its screen, in
// one warm gradient, so the project needs no design tool to produce
// ScreenHelmApp/Resources/Assets.xcassets/AppIcon.appiconset.
//
// Run once (or whenever the look changes):
//   swift scripts/generate-app-icon.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.first!).deletingLastPathComponent().deletingLastPathComponent()
let iconset = root.appendingPathComponent("ScreenHelmApp/Resources/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

/// The point `radius` away from `center` at `degrees`, counterclockwise from the right.
func point(_ center: NSPoint, _ radius: CGFloat, _ degrees: CGFloat) -> NSPoint {
    let angle = degrees * .pi / 180
    return NSPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
}

func line(from: NSPoint, to: NSPoint, width: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    path.lineWidth = width
    path.lineCapStyle = .round
    path.move(to: from)
    path.line(to: to)
    return path
}

/// Drawn on a 1024-point canvas; every size is scaled down from it.
func drawIcon() {
    // macOS icon grid: the squircle occupies ~80% of the canvas, in the
    // same near-black as the other apps' icons.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    color(0x121214).setFill()
    NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185).fill()

    // The glyph is drawn a little larger and scaled about the middle, so
    // it keeps the same margin as the other apps' glyphs.
    let glyph = NSAffineTransform()
    glyph.translateX(by: 512, yBy: 512)
    glyph.scale(by: 0.9)
    glyph.translateX(by: -512, yBy: -512)

    // The display: screen, neck and foot.
    let screen = NSBezierPath(roundedRect: NSRect(x: 220, y: 350, width: 584, height: 400), xRadius: 44, yRadius: 44)
    screen.lineWidth = 44
    var strokes = [screen,
                   line(from: NSPoint(x: 512, y: 350), to: NSPoint(x: 512, y: 280), width: 44),
                   line(from: NSPoint(x: 392, y: 272), to: NSPoint(x: 632, y: 272), width: 44)]

    // The helm on its screen: rim, six spokes and the handles beyond them.
    let center = NSPoint(x: 512, y: 550)
    let rim = NSBezierPath(ovalIn: NSRect(x: center.x - 82, y: center.y - 82, width: 164, height: 164))
    rim.lineWidth = 28
    strokes.append(rim)
    for index in 0..<6 {
        let degrees = 90 + CGFloat(index) * 60
        strokes.append(line(from: point(center, 25, degrees), to: point(center, 82, degrees), width: 20))
        strokes.append(line(from: point(center, 82, degrees), to: point(center, 132, degrees), width: 32))
    }
    let hub = NSBezierPath(ovalIn: NSRect(x: center.x - 32, y: center.y - 32, width: 64, height: 64))
    strokes.forEach { $0.transform(using: glyph as AffineTransform) }
    hub.transform(using: glyph as AffineTransform)

    // All of it white in a layer, then tinted with one warm gradient.
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext.current!.cgContext
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    NSColor.white.setStroke()
    NSColor.white.setFill()
    strokes.forEach { $0.stroke() }
    hub.fill()
    NSGraphicsContext.current!.compositingOperation = .sourceIn
    NSGradient(colors: [color(0xFDE68A), color(0xF97316)])!.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024), angle: -90)
    context.endTransparencyLayer()
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
