import AppKit
import ScreenCaptureKit

/// Session-only cache of space screenshots, captured shortly after arriving
/// on a space (post-transition, so never mid-fade). Stale by design: a tile
/// shows the space as of your last visit. Never persisted to disk.
final class PreviewStore: ObservableObject {
    @Published private(set) var images: [String: NSImage] = [:]

    func set(_ image: NSImage, for uuid: String) {
        images[uuid] = image
    }

    func image(for uuid: String) -> NSImage? {
        images[uuid]
    }
}

enum ScreenCapture {
    static var authorized: Bool { CGPreflightScreenCaptureAccess() }

    /// One-time system prompt; later calls are silent no-ops until the user
    /// flips the toggle in System Settings (which requires an app relaunch).
    static func requestIfNeeded() {
        if !authorized { CGRequestScreenCaptureAccess() }
    }

    /// Third-resolution screenshot of the main display — plenty for tiles.
    static func captureMainDisplay() async -> NSImage? {
        guard authorized else {
            NSLog("preview: skipped — Screen Recording not authorized")
            return nil
        }
        do {
            let content = try await SCShareableContent
                .excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                ?? content.displays.first else {
                NSLog("preview: no display in shareable content")
                return nil
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = display.width / 3
            config.height = display.height / 3
            config.showsCursor = false
            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config)
            NSLog("preview: captured %dx%d", cgImage.width, cgImage.height)
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        } catch {
            NSLog("preview: capture failed: %@", String(describing: error))
            return nil
        }
    }
}
