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

// Icon Services caches by path and can answer with a stale or generic icon.
// actool's own .icns (still at <out.icns> when this runs) comes straight from
// the icon package, so the system rendering must roughly match it.
func pixels(_ image: NSImage) -> [UInt8] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 64 * 4, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64))
    NSGraphicsContext.restoreGraphicsState()
    return Array(UnsafeBufferPointer(start: rep.bitmapData!, count: 64 * 64 * 4))
}
guard let reference = NSImage(contentsOfFile: args[2]) else {
    FileHandle.standardError.write("render-icns: no actool icon at \(args[2]) to check against\n".data(using: .utf8)!)
    exit(1)
}
let a = pixels(icon), b = pixels(reference)
let meanDiff = Double(zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(a.count)
guard meanDiff < 24 else {
    FileHandle.standardError.write("render-icns: system icon differs from actool's (mean diff \(meanDiff)); stale icon cache? Not writing \(args[2])\n".data(using: .utf8)!)
    exit(1)
}

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
