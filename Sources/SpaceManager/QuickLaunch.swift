import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// One quick-launch entry: an app openable from the switcher onto whichever
/// space is highlighted. Pressed as ⌘ + keyEquivalent, or clicked in the
/// switcher's footer row.
struct QuickLaunchApp: Codable, Identifiable, Equatable {
    var id = UUID()
    var label = ""
    var bundleID = ""
    /// Single letter, lowercased; fires with ⌘ held.
    var keyEquivalent = ""
    /// Virtual key that opens a new window in this app, pressed with ⌘.
    /// Optional (nil = ⌘N) so entries persisted before this field existed
    /// still decode instead of resetting the whole list to defaults.
    var newWindowKey: Int?
    /// Chrome profile directory ("Default", "Profile 1"); nil = no targeting.
    var chromeProfile: String?
    /// Where the new window should land; nil = leave it where the app puts it.
    var placement: PlacementSpec?

    static let defaults: [QuickLaunchApp] = normalized([
        QuickLaunchApp(label: "Ghostty", bundleID: "com.mitchellh.ghostty"),
        QuickLaunchApp(label: "Chrome", bundleID: "com.google.Chrome")
    ])

    /// nil when the app isn't installed — those entries stay hidden.
    var url: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    var shortcut: String { "⌘\(keyEquivalent.uppercased())" }

    /// Cached: menu rows re-render on every hover and keystroke, and this is a
    /// Launch Services hit. Main-thread only, like all the UI that reads it.
    private static var iconCache: [String: NSImage] = [:]

    var icon: NSImage? {
        if let cached = Self.iconCache[bundleID] { return cached }
        guard let url else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        Self.iconCache[bundleID] = image
        return image
    }

    var newWindowKeyCode: CGKeyCode { CGKeyCode(newWindowKey ?? kVK_ANSI_N) }

    /// The already-running instance, if any.
    var runningInstance: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    /// Fills blank key equivalents from the label's first unclaimed letter, so
    /// entries added later get a shortcut without one having to be typed.
    static func normalized(_ apps: [QuickLaunchApp]) -> [QuickLaunchApp] {
        var taken = Set(apps.map { $0.keyEquivalent.lowercased() }.filter { !$0.isEmpty })
        return apps.map { app in
            var copy = app
            guard app.keyEquivalent.isEmpty else {
                copy.keyEquivalent = app.keyEquivalent.lowercased()
                return copy
            }
            for c in app.label.lowercased() where c.isLetter && !taken.contains(String(c)) {
                taken.insert(String(c))
                copy.keyEquivalent = String(c)
                break
            }
            return copy
        }
    }
}

/// Opens a quick-launch app on a chosen space. When that space isn't the
/// current one we switch first and wait for the real arrival plus the settle
/// interval, so the app lands on the destination instead of where we started.
final class QuickLauncher {
    private let settings: Settings
    private let viewModel: SpacesViewModel
    private var pending: (uuid: String, app: QuickLaunchApp)?
    private var timeout: DispatchWorkItem?

    init(settings: Settings, viewModel: SpacesViewModel) {
        self.settings = settings
        self.viewModel = viewModel
    }

    func launch(_ app: QuickLaunchApp, onSpaceIndex index: Int) {
        guard viewModel.items.indices.contains(index) else { return }
        guard index != viewModel.currentIndex else {
            open(app)
            return
        }
        pending = (viewModel.items[index].uuid, app)
        // Drop the request if the switch never lands (refused, or you went
        // somewhere else in the meantime).
        let bail = DispatchWorkItem { [weak self] in self?.pending = nil }
        timeout = bail
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: bail)
        viewModel.requestSwitch?(index)
    }

    /// Called from the app delegate's arrival hook.
    func arrived(at uuid: String) {
        guard let pending, pending.uuid == uuid else { return }
        self.pending = nil
        timeout?.cancel()
        let app = pending.app
        DispatchQueue.main.asyncAfter(deadline: .now() + settings.settleSeconds) { [weak self] in
            self?.open(app)
        }
    }

    /// "Open X on this space" has to mean a NEW window here, so the two cases
    /// need different mechanisms.
    private func open(_ app: QuickLaunchApp) {
        // Already running: openApplication would only activate it — no window —
        // and activating an app whose windows all live on other spaces pulls us
        // straight back off the space we just landed on. Ask the app itself for
        // a window instead.
        if let running = app.runningInstance, !running.isTerminated {
            newWindow(in: running, key: app.newWindowKeyCode)
            return
        }
        guard let url = app.url else { return }
        // Cold launch: the first window opens on the active (target) space.
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
    }

    /// ⌘ + key delivered straight to the app's own process. Same CGEvent style
    /// as Switching.swift, but posted to a PID rather than the HID tap, so the
    /// global Ctrl+digit space shortcuts are never in play. Flags are assigned,
    /// not OR-ed, so the event carries ONLY command — no stray Ctrl/Option from
    /// the hotkey the user may still be holding.
    private func newWindow(in running: NSRunningApplication, key: CGKeyCode) {
        let pid = running.processIdentifier
        guard AXIsProcessTrusted(), pid > 0 else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(pid)
        up.postToPid(pid)
        // Focus once the window exists. Empty options is load-bearing:
        // NSApplicationActivationOptions documents that activation brings only
        // the main and key windows forward, and .activateAllWindows is what
        // would haul this app's windows over from other spaces. The window we
        // just asked for is on this space and is now the app's key window, so
        // this focuses in place.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            running.activate(options: [])
        }
    }
}
