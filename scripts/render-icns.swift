// Write a complete AppIcon.icns (16–1024, 1x and 2x) for a built app bundle.
// Usage: swift scripts/render-icns.swift <app-bundle> <out.icns>
// actool's .icns fallback only carries sizes up to 256px; launchers that read
// the .icns (Monarch, verified 2026-10-14) show a blank placeholder when asked
// for a larger size. The source image is the system's own rendering of the
// bundle's Liquid Glass icon (Assets.car), so both icon paths match.
import AppKit

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("usage: render-icns.swift <app-bundle> <out.icns>\n".data(using: .utf8)!)
    exit(2)
}
let icon = NSWorkspace.shared.icon(forFile: args[1])
let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("AppIcon-\(ProcessInfo.processInfo.processIdentifier).iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", args[2]]
try iconutil.run()
iconutil.waitUntilExit()
try? fm.removeItem(at: iconset)
exit(iconutil.terminationStatus)
