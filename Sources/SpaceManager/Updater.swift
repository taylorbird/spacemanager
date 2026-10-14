import AppKit
import Sparkle

// MARK: - Auto-update (live builds only)

/// Wraps Sparkle's standard updater. Only the live build's Info.plist carries
/// SUFeedURL (scripts/build-app.sh --release); a dev build has none, creates
/// no updater, and never offers to replace itself with the live release.
final class Updater {
    private let controller: SPUStandardUpdaterController?

    init() {
        if Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil {
            controller = SPUStandardUpdaterController(startingUpdater: true,
                                                      updaterDelegate: nil,
                                                      userDriverDelegate: nil)
        } else {
            controller = nil
        }
    }

    var isAvailable: Bool { controller != nil }

    func checkForUpdates() {
        // An accessory app isn't active by default; Sparkle's window would
        // open behind whatever app is frontmost.
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }
}
