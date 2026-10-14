// Render the app-icon layers from the mark geometry in assets/mark.svg.
// Usage: swift scripts/render-icon.swift [out-dir]   (default assets/icon/AppIcon.icon/Assets)
// Writes, both 1024x1024, for the Icon Composer package assets/icon/AppIcon.icon:
//   icon-backing.png   full-bleed Graphite backing
//   icon-mark.png      transparent mark at 68% of the canvas
// build-app.sh compiles the package with actool, which also emits the masked
// AppIcon.icns fallback for pre-Liquid-Glass macOS.
// Drawn with CoreGraphics rather than an SVG rasterizer: qlmanage bakes white
// behind transparency, and no other rasterizer is installed.
import AppKit

let size = 1024
let backing = CGColor(srgbRed: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255, alpha: 1)

// assets/mark.svg on its 24-unit grid; content center is (11.9, 12).
let panes: [(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, hex: UInt32, opacity: CGFloat)] = [
    (3.2, 6, 6.4, 12, 0x22D3EE, 0.78),
    (8.2, 4.5, 6.4, 15, 0x3B82F6, 0.85),
    (13.2, 6, 6.4, 12, 0x8B5CF6, 0.78),
]
let markScale: CGFloat = 0.68 * CGFloat(size) / 24

func color(_ hex: UInt32, _ alpha: CGFloat) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func render(_ name: String, in dir: URL, draw: (CGContext) -> Void) throws {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // SVG coordinates: origin top-left, y down.
    ctx.translateBy(x: 0, y: CGFloat(size))
    ctx.scaleBy(x: 1, y: -1)
    draw(ctx)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(name))
}

func drawBacking(_ ctx: CGContext) {
    ctx.setFillColor(backing)
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
}

func drawMark(_ ctx: CGContext) {
    ctx.saveGState()
    let c = CGFloat(size) / 2
    ctx.translateBy(x: c - 11.9 * markScale, y: c - 12 * markScale)
    ctx.scaleBy(x: markScale, y: markScale)
    // translate(2.2 0) skewX(-8)
    ctx.concatenate(CGAffineTransform(translationX: 2.2, y: 0))
    ctx.concatenate(CGAffineTransform(a: 1, b: 0, c: tan(-8 * .pi / 180), d: 1, tx: 0, ty: 0))
    for p in panes {
        ctx.addPath(CGPath(roundedRect: CGRect(x: p.x, y: p.y, width: p.w, height: p.h),
                           cornerWidth: 1.2, cornerHeight: 1.2, transform: nil))
        ctx.setFillColor(color(p.hex, p.opacity))
        ctx.fillPath()
    }
    ctx.restoreGState()
}

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "assets/icon/AppIcon.icon/Assets")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

try render("icon-backing.png", in: out, draw: drawBacking)
try render("icon-mark.png", in: out, draw: drawMark)
print("Rendered icon layers to \(out.path)")
