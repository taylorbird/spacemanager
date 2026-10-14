import AppKit
import Sparkle

// MARK: - Auto-update (live builds only)

/// Wraps Sparkle's standard updater. Only the live build's Info.plist carries
/// SUFeedURL (scripts/build-app.sh --release); a dev build has none, creates
/// no updater, and never offers to replace itself with the live release.
///
/// Gentle reminders: a menu bar app has no Dock icon or main window, so an
/// update alert from a background check can open unnoticed behind other apps.
/// Background finds instead set `pendingVersion` (a dot on the status item and
/// an "Update to …" menu row); Sparkle's own window appears only when the
/// update is in immediate focus (launch, or a manual check).
final class Updater: NSObject, SPUStandardUserDriverDelegate {
    private var controller: SPUStandardUpdaterController?

    /// Version string of an update found by a background check and not yet
    /// seen by the user; nil otherwise.
    private(set) var pendingVersion: String? {
        didSet { if pendingVersion != oldValue { onPendingChange?(pendingVersion) } }
    }
    var onPendingChange: ((String?) -> Void)?

    override init() {
        super.init()
        if Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil {
            controller = SPUStandardUpdaterController(startingUpdater: true,
                                                      updaterDelegate: nil,
                                                      userDriverDelegate: self)
        }
    }

    var isAvailable: Bool { controller != nil }

    func checkForUpdates() {
        // An accessory app isn't active by default; Sparkle's window would
        // open behind whatever app is frontmost.
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }

    // MARK: SPUStandardUserDriverDelegate

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                   forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        if handleShowingUpdate {
            NSApp.activate()
        } else if !state.userInitiated {
            pendingVersion = update.displayVersionString
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        pendingVersion = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        pendingVersion = nil
    }
}
