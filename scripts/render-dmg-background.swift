// Render the DMG window background (640x400 window; 1x and 2x).
// Usage: swift scripts/render-dmg-background.swift [out-dir]   (default assets/dmg)
// Writes background.png and background@2x.png; package-dmg.sh combines them
// into a HiDPI TIFF. Icon positions in scripts/dmg-settings.py must match
// appX/appsX/iconY below.
import AppKit

let width: CGFloat = 640, height: CGFloat = 400
let appX: CGFloat = 170, appsX: CGFloat = 470, iconY: CGFloat = 196   // icon centers, top-left origin
let paper = NSColor(srgbRed: 0xF4 / 255, green: 0xF5 / 255, blue: 0xF7 / 255, alpha: 1)
let ink = NSColor(srgbRed: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255, alpha: 1)

func render(scale: CGFloat, to url: URL) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale),
                               pixelsHigh: Int(height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // Top-left origin, matching Finder's icon coordinates.
    let flip = NSAffineTransform()
    flip.translateX(by: 0, yBy: height)
    flip.scaleX(by: 1, yBy: -1)
    flip.concat()

    paper.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()

    // Wordmark: the caption treatment (SF Pro 400, uppercase, 0.06em, 60% ink).
    drawCentered("SPACE MANAGER", y: 52, size: 13, weight: .regular, tracking: 0.06, alpha: 0.6)

    // Arrow from the app to Applications, between the two 128pt icons.
    let arrow = NSBezierPath()
    let y = iconY - 6, x0 = appX + 84, x1 = appsX - 84
    arrow.move(to: NSPoint(x: x0, y: y))
    arrow.line(to: NSPoint(x: x1, y: y))
    arrow.move(to: NSPoint(x: x1 - 11, y: y - 9))
    arrow.line(to: NSPoint(x: x1, y: y))
    arrow.line(to: NSPoint(x: x1 - 11, y: y + 9))
    arrow.lineWidth = 2.5
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    ink.withAlphaComponent(0.3).setStroke()
    arrow.stroke()

    // Above y≈340: Finder's path bar, when the viewer has it on, covers the bottom.
    drawCentered("Drag Space Manager to Applications", y: 300, size: 12, weight: .regular,
                 tracking: 0, alpha: 0.45)

    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

func drawCentered(_ text: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight,
                  tracking: CGFloat, alpha: CGFloat) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: ink.withAlphaComponent(alpha),
        .kern: size * tracking,
    ]
    let string = NSAttributedString(string: text, attributes: attrs)
    let measured = string.size()
    // Text draws upright inside the flipped context only with its own flip.
    NSGraphicsContext.saveGraphicsState()
    let t = NSAffineTransform()
    t.translateX(by: (width - measured.width) / 2, yBy: y + measured.height / 2)
    t.scaleX(by: 1, yBy: -1)
    t.concat()
    string.draw(at: .zero)
    NSGraphicsContext.restoreGraphicsState()
}

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "assets/dmg")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
try render(scale: 1, to: out.appendingPathComponent("background.png"))
try render(scale: 2, to: out.appendingPathComponent("background@2x.png"))
print("Rendered DMG background to \(out.path)")
