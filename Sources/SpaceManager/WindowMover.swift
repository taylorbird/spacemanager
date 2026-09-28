import AppKit
import ApplicationServices

/// Accessibility calls are synchronous IPC into another app, and a busy app
/// (Chrome, mostly) can sit on them. The timeout is per element — setting it
/// on the application element does NOT cover a window or hit-test element
/// copied out of it, which fall back to the ~6s global default — so every
/// element gets it explicitly, and none of this runs on the main thread.
enum AX {
    static let timeout: Float = 0.5

    /// Serial: AX work for one capture/move stays ordered.
    static let queue = DispatchQueue(label: "com.taylorbird.spacemanager.ax",
                                     qos: .userInitiated)

    @discardableResult
    static func bounded(_ element: AXUIElement) -> AXUIElement {
        AXUIElementSetMessagingTimeout(element, timeout)
        return element
    }

    static func app(_ pid: pid_t) -> AXUIElement {
        bounded(AXUIElementCreateApplication(pid))
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success
        else { return nil }
        return ref as? String
    }

    static func frame(of window: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        var pos = CGPoint.zero, size = CGSize.zero
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef)
                == .success, let p = posRef,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef)
                == .success, let s = sizeRef else { return nil }
        AXValueGetValue(p as! AXValue, .cgPoint, &pos)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }

    static func windowCount(_ app: AXUIElement) -> Int? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref)
                == .success else { return nil }
        return (ref as? [AXUIElement])?.count
    }

    static func ms(since start: DispatchTime) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
    }
}

/// The window the switcher can move: captured when the switcher opens, so the
/// move acts on whatever you were working in — by the time you pick the menu
/// row, "frontmost" would answer with the switcher's own panel's app.
struct MovableWindow {
    let pid: pid_t
    let appName: String
    let icon: NSImage?
    /// The app's focused window as of capture time.
    let element: AXUIElement
    /// CG top-left coordinates — the space AX and CGDisplayBounds share, so
    /// there's no NSScreen flip anywhere here (same as PlacementGeometry).
    let frame: CGRect

    /// Delivers nil whenever there's nothing sensible to move: no frontmost
    /// app, our own windows (Preferences etc.), no focused window, or a
    /// non-standard window — dialogs, sheets and floating panels don't drag
    /// between spaces. The frontmost app is read on the caller's (main)
    /// thread; the AX queries run on `AX.queue` so a slow app can't freeze
    /// the switcher. `completion` runs on main.
    static func captureFocusedWindow(completion: @escaping (MovableWindow?) -> Void) {
        guard AXIsProcessTrusted(),
              let running = NSWorkspace.shared.frontmostApplication else {
            completion(nil)
            return
        }
        let pid = running.processIdentifier
        guard pid > 0, running.bundleIdentifier != Bundle.main.bundleIdentifier else {
            completion(nil)
            return
        }
        let name = running.localizedName ?? "Window"
        let icon = running.icon

        AX.queue.async {
            let start = DispatchTime.now()
            let result = capture(pid: pid, name: name, icon: icon)
            Log.mover.notice("capture took \(AX.ms(since: start), privacy: .public)ms")
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func capture(pid: pid_t, name: String, icon: NSImage?) -> MovableWindow? {
        let app = AX.app(pid)
        var winRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &winRef)
        guard err == .success, let win = winRef else {
            Log.mover.notice("no capture, \(name, privacy: .public) focused window unavailable (AX error \(err.rawValue, privacy: .public))")
            return nil
        }
        let window = AX.bounded(win as! AXUIElement)

        let subrole = AX.string(window, kAXSubroleAttribute) ?? "nil"
        guard subrole == kAXStandardWindowSubrole else {
            Log.mover.notice("no capture, \(name, privacy: .public) focused window subrole=\(subrole, privacy: .public)")
            return nil
        }
        // A window too small to have a grabbable title bar isn't worth a drag.
        guard let frame = AX.frame(of: window), frame.width > 80, frame.height > 40 else {
            Log.mover.notice("no capture, \(name, privacy: .public) window frame unreadable or too small")
            return nil
        }
        Log.mover.notice("captured \(name, privacy: .public) pid=\(pid, privacy: .public) frame=\(frame.logDescription, privacy: .public)")
        return MovableWindow(pid: pid, appName: name, icon: icon, element: window, frame: frame)
    }
}

/// The synthesized left button. Main releases it on every normal exit; a
/// watchdog on this class's own queue releases it too if main never gets
/// there, so a stalled main thread can never leave the system in a
/// held-button drag (which reads as the whole machine locking up).
private final class HeldButton {
    private let lock = NSLock()
    private var heldToken: Int?
    private var nextToken = 0
    private let queue = DispatchQueue(label: "com.taylorbird.spacemanager.button",
                                      qos: .userInteractive)

    /// Posts the mouse-down. Returns the token that releases it, or nil when
    /// the event couldn't be made (nothing was posted).
    func press(at point: CGPoint, releaseAt release: CGPoint, source: CGEventSource?,
               ceiling: TimeInterval) -> Int? {
        guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                                 mouseCursorPosition: point, mouseButton: .left) else { return nil }
        lock.lock()
        nextToken += 1
        let token = nextToken
        heldToken = token
        lock.unlock()
        down.post(tap: .cghidEventTap)

        queue.asyncAfter(deadline: .now() + ceiling) { [weak self] in
            if self?.release(token, at: release, source: source) == true {
                Log.mover.error("button released by off-main watchdog after \(ceiling, format: .fixed(precision: 1), privacy: .public)s — main never finished the move")
            }
        }
        return token
    }

    func isHeld(_ token: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return heldToken == token
    }

    /// Posts the mouse-up if this token still holds the button. false = it
    /// was already released (by the other path).
    @discardableResult
    func release(_ token: Int, at point: CGPoint, source: CGEventSource?) -> Bool {
        lock.lock()
        guard heldToken == token else { lock.unlock(); return false }
        heldToken = nil
        lock.unlock()
        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        return true
    }
}

/// Moves an existing window to another space by automating the one gesture
/// macOS itself supports: while a window is held in a drag, the native
/// space-switch shortcut carries that window along. No private API is
/// involved — this is a synthesized mouse drag plus the same Ctrl+digit
/// keystroke the app already posts for every switch. The user lands on the
/// destination space with the window; that's inherent to the mechanism.
final class WindowMover {
    /// Injected so a move goes through the app's single switching gate
    /// (setup recheck + keystroke). false = the keystroke never went out.
    private let performSwitch: (Int) -> Bool
    private let button = HeldButton()

    // Timing is about the drag's own state machine, not the transition: the
    // window must genuinely be "in a drag" before the space switch, or macOS
    // leaves it behind.
    private static let dragDelay: TimeInterval = 0.06
    private static let switchDelay: TimeInterval = 0.12
    private static let settleDelay: TimeInterval = 0.15
    /// Hard ceiling on holding the button down when arrival never comes.
    private static let bailout: TimeInterval = 2.5
    /// Off-main backstop for `bailout`, in case main is what's stuck.
    private static let buttonCeiling: TimeInterval = 3.5
    /// How far the drag event travels — enough to enter drag mode, small
    /// enough that the window doesn't visibly jump.
    private static let dragDistance: CGFloat = 3
    /// How long to wait for our own windows (the switcher) to actually leave
    /// the screen before the mouse-down. orderOut returns before WindowServer
    /// has taken the window away; a mouse-down in that gap lands on the
    /// switcher, and the mouse-up then brings it back without key focus.
    private static let clearTimeout: TimeInterval = 0.5

    private struct Move {
        let uuid: String
        let window: MovableWindow
        /// Where the drag left the cursor; the mouse-up posts here too.
        let release: CGPoint
        let restoreCursor: CGPoint
        let source: CGEventSource?
        let token: Int
        var switchRequested = false
        var bail: DispatchWorkItem?
    }

    /// One at a time: a second request while a drag is held would strand the
    /// first one's mouse button. `preparing` covers the off-main grab-point
    /// work before the move exists.
    private var inFlight: Move?
    private var preparing = false

    init(performSwitch: @escaping (Int) -> Bool) {
        self.performSwitch = performSwitch
    }

    /// `obstructions`: our own windows that must be off screen before the
    /// mouse-down (the switcher panel, which the caller has just closed).
    func move(_ window: MovableWindow, toSpaceUUID uuid: String, index: Int,
              obstructions: [CGWindowID]) {
        guard inFlight == nil, !preparing else {
            Log.mover.notice("ignoring move to \(uuid, privacy: .public), one already in flight")
            return
        }
        guard AXIsProcessTrusted() else {
            Log.mover.notice("not armed (AX not trusted)")
            return
        }
        preparing = true
        let previous = CGEvent(source: nil)?.location

        AX.queue.async { [weak self] in
            let start = DispatchTime.now()
            let grab = Self.grabPoint(for: window)
            let grabMs = AX.ms(since: start)
            let clearStart = DispatchTime.now()
            let clear = Self.waitUntilOffScreen(obstructions)
            let clearMs = AX.ms(since: clearStart)
            Log.mover.notice("prepared: grab point \(grabMs, privacy: .public)ms, switcher off screen \(clear ? "yes" : "NO", privacy: .public) after \(clearMs, privacy: .public)ms")
            DispatchQueue.main.async {
                guard let self else { return }
                self.preparing = false
                guard clear else {
                    Log.mover.error("aborted: switcher still on screen after \(Int(Self.clearTimeout * 1000), privacy: .public)ms; not clicking on our own window")
                    return
                }
                self.arm(window, grab: grab, previous: previous ?? grab, uuid: uuid, index: index)
            }
        }
    }

    private func arm(_ window: MovableWindow, grab: CGPoint, previous: CGPoint,
                     uuid: String, index: Int) {
        let source = CGEventSource(stateID: .hidSystemState)
        // Warping otherwise suppresses local (real) mouse input for 0.25s —
        // exactly the window in which we post the drag and the user may be
        // moving the mouse.
        source?.localEventsSuppressionInterval = 0

        let release = CGPoint(x: grab.x + Self.dragDistance, y: grab.y)
        CGWarpMouseCursorPosition(grab)
        guard let token = button.press(at: grab, releaseAt: release, source: source,
                                       ceiling: Self.buttonCeiling) else {
            Log.mover.error("could not synthesize mouse down; aborting")
            CGWarpMouseCursorPosition(previous)
            return
        }

        var pending = Move(uuid: uuid, window: window, release: release,
                           restoreCursor: previous, source: source, token: token)
        let bail = DispatchWorkItem { [weak self] in
            self?.finish(reason: "bailed out, arrival never came")
        }
        pending.bail = bail
        inFlight = pending

        Log.mover.notice("armed \(window.appName, privacy: .public) pid=\(window.pid, privacy: .public) grab=\(grab.logDescription, privacy: .public) dest=\(uuid, privacy: .public) index=\(index, privacy: .public)")
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.bailout, execute: bail)

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dragDelay) { [weak self] in
            guard let self, self.inFlight?.uuid == uuid, self.button.isHeld(token) else { return }
            CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged,
                    mouseCursorPosition: release, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dragDelay + Self.switchDelay) {
            [weak self] in
            guard let self, self.inFlight?.uuid == uuid else { return }
            self.inFlight?.switchRequested = true
            if self.performSwitch(index) {
                Log.mover.notice("switch requested to index=\(index, privacy: .public)")
            } else {
                Log.mover.notice("switch refused for index=\(index, privacy: .public)")
                self.finish(reason: "released, switch refused")
            }
        }
    }

    /// Called from the app delegate's real-arrival hook.
    func arrived(at uuid: String) {
        guard let pending = inFlight, pending.switchRequested,
              pending.uuid == uuid else { return }
        Log.mover.notice("arrived at \(uuid, privacy: .public)")
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay) { [weak self] in
            guard let self, self.inFlight?.uuid == uuid else { return }
            self.finish(reason: "released on arrival")
        }
    }

    /// The single exit. Always releases the button and restores the cursor —
    /// leaving the button down would strand the user in a drag.
    private func finish(reason: String) {
        guard let pending = inFlight else { return }
        inFlight = nil
        pending.bail?.cancel()

        let window = pending.window
        // Diagnostic: which of the app's on-screen windows sit under the
        // release point right now. Chrome and Ghostty (tabs title bar) merge
        // a tab dropped on another window's tab strip into that window — the
        // suspected cause of moves failing when the destination already has
        // one of the app's windows.
        let under = Self.onScreenWindows(pid: window.pid)
            .filter { $0.contains(pending.release) }.count
        let releasedHere = button.release(pending.token, at: pending.release,
                                          source: pending.source)
        CGWarpMouseCursorPosition(pending.restoreCursor)
        Log.mover.notice("\(reason, privacy: .public)\(releasedHere ? "" : " (button was already released by the watchdog)", privacy: .public); \(under, privacy: .public) on-screen \(window.appName, privacy: .public) window(s) under the release point")

        // Diagnostic only — where the window actually ended up. Nothing acts
        // on this; the move is best-effort by design. Off main: it's AX.
        AX.queue.asyncAfter(deadline: .now() + 0.2) {
            let landed = AX.frame(of: window.element)
            let windows = AX.windowCount(AX.app(window.pid))
            let visible = Self.onScreenWindows(pid: window.pid)
                .contains { abs($0.width - window.frame.width) < 3
                    && abs($0.height - window.frame.height) < 3 }
            Log.mover.notice("\(window.appName, privacy: .public) window now at \(landed?.logDescription ?? "unreadable", privacy: .public) (was \(window.frame.logDescription, privacy: .public)); same-size window on screen: \(visible ? "yes" : "no", privacy: .public); app AX window count \(windows.map(String.init) ?? "?", privacy: .public)")
        }
    }

    /// Chrome's title bar IS its tab strip: a mouse-down on a tab tears the
    /// TAB out instead of dragging the window. So the grab point is chosen by
    /// AX hit test — the first candidate that lands on window chrome rather
    /// than on a control. Candidates walk the title bar from the middle
    /// outward; the fallback is the middle, which is right for everything
    /// that isn't a browser. Runs on `AX.queue`.
    private static func grabPoint(for window: MovableWindow) -> CGPoint {
        let f = window.frame
        let candidates = [CGPoint(x: f.midX, y: f.minY + 12),
                          CGPoint(x: f.maxX - 28, y: f.minY + 12),
                          CGPoint(x: f.minX + 96, y: f.minY + 12)]
        // Roles that are safe to drag a window by. Everything else — AXButton,
        // AXTabGroup, AXTextField, AXPopUpButton, AXImage … — is a control
        // that would swallow the drag.
        let draggable: Set<String> = [kAXWindowRole, kAXToolbarRole,
                                      kAXStaticTextRole, kAXGroupRole, "AXUnknown"]

        let app = AX.app(window.pid)
        for p in candidates {
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(app, Float(p.x), Float(p.y), &hit)
                    == .success, let hit else {
                Log.mover.notice("grab point \(p.logDescription, privacy: .public) hit test failed")
                continue
            }
            AX.bounded(hit)
            if CFEqual(hit, window.element) {
                Log.mover.notice("grab point \(p.logDescription, privacy: .public) is the window itself")
                return p
            }
            let role = AX.string(hit, kAXRoleAttribute) ?? "nil"
            if draggable.contains(role) {
                Log.mover.notice("grab point \(p.logDescription, privacy: .public) role=\(role, privacy: .public)")
                return p
            }
            Log.mover.notice("grab point \(p.logDescription, privacy: .public) rejected, role=\(role, privacy: .public)")
        }
        Log.mover.notice("no clean grab point, falling back to \(candidates[0].logDescription, privacy: .public)")
        return candidates[0]
    }

    /// Polls WindowServer (public CGWindowList) until none of `windows` is on
    /// screen. true = clear.
    private static func waitUntilOffScreen(_ windows: [CGWindowID]) -> Bool {
        guard !windows.isEmpty else { return true }
        let deadline = Date().addingTimeInterval(clearTimeout)
        repeat {
            let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] ?? []
            let ids = Set(onScreen.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
            if windows.allSatisfy({ !ids.contains($0) }) { return true }
            Thread.sleep(forTimeInterval: 0.01)
        } while Date() < deadline
        return false
    }

    /// Bounds (CG top-left coordinates) of the app's normal-layer windows
    /// that are on screen right now.
    private static func onScreenWindows(pid: pid_t) -> [CGRect] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                              kCGNullWindowID) as? [[String: Any]] ?? []
        return info.compactMap { w in
            guard (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (w[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return nil }
            return rect
        }
    }
}
