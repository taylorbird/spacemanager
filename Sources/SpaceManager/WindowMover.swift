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
///
/// A mouse-down doesn't always start a window drag (on Chrome a hit on a tab
/// just selects the tab), and switching without the window strands the user
/// on the destination. So each grab candidate is verified before the switch:
/// press, nudge, and read the window's AX position back — a window in a
/// native drag has moved by the nudge. No movement means release and try the
/// next candidate; none engaging means abort without switching.
final class WindowMover {
    /// Injected so a move goes through the app's single switching gate
    /// (setup recheck + keystroke). false = the keystroke never went out.
    private let performSwitch: (Int) -> Bool
    private let button = HeldButton()

    // Timing is about the drag's own state machine, not the transition: the
    // window must genuinely be "in a drag" before the space switch, or macOS
    // leaves it behind.
    private static let dragDelay: TimeInterval = 0.06
    /// Minimum time from mouse-down to the switch keystroke. The engagement
    /// check usually finishes inside it; the switch waits out the remainder.
    private static let switchDelay: TimeInterval = 0.12
    private static let settleDelay: TimeInterval = 0.15
    /// After the nudge, how long before reading the window's position back —
    /// and the gap before the one re-read (windows can lag a frame).
    private static let engageDelay: TimeInterval = 0.05
    /// Between releasing a candidate that didn't engage and pressing the next.
    private static let interPressGap: TimeInterval = 0.03
    /// Nominal cost of one candidate that doesn't engage: nudge, two reads,
    /// the gap (≈0.19s), plus allowance for the AX round trips.
    private static let perCandidateCost: TimeInterval =
        dragDelay + 2 * engageDelay + interPressGap + 0.03
    /// Ceiling on the whole retry phase. With `maxCandidates` × ~0.22s the
    /// nominal worst case is ~1.3s; the budget also stops retrying if slow AX
    /// reads (0.5s timeout each) eat the time instead.
    private static let retryBudget: TimeInterval = 1.5
    private static let maxCandidates = 6
    /// Hard ceiling on holding the button down when arrival never comes.
    /// Restarted on each press, so it bounds every individual hold.
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

    /// A title-bar point to try, with what the hit test found there.
    private struct Candidate {
        let point: CGPoint
        /// "accepted" (hit test says draggable) or "fallback" (rejected or
        /// unknown, tried only once the accepted ones are used up).
        let tier: String
        let role: String
    }

    private enum Stage {
        /// Between a candidate's release and the next one's press.
        case pressing
        /// Button down, waiting to see whether the window moved.
        case engaging
        /// Switch keystroke posted, waiting for `arrived(at:)`.
        case awaitingArrival
    }

    private struct Move {
        let uuid: String
        let index: Int
        let window: MovableWindow
        let candidates: [Candidate]
        let restoreCursor: CGPoint
        let source: CGEventSource?
        /// CGWindowIDs that matched the window before the move; whether any
        /// is on screen afterwards is the "did it travel" answer.
        let trackedIDs: [CGWindowID]
        let startedAt: DispatchTime
        var candidateIndex = 0
        var stage = Stage.pressing
        /// Where the drag left the cursor; the mouse-up posts here too.
        var release: CGPoint = .zero
        /// 0 = no press yet. Tokens are unique per press, so every delayed
        /// step checks it to know it still belongs to the current candidate.
        var token = 0
        var pressedAt = DispatchTime.now()
        var bail: DispatchWorkItem?

        var candidate: Candidate { candidates[candidateIndex] }
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
            let candidates = Self.grabCandidates(for: window)
            let grabMs = AX.ms(since: start)
            let clearStart = DispatchTime.now()
            let clear = Self.waitUntilOffScreen(obstructions)
            let clearMs = AX.ms(since: clearStart)
            Log.mover.notice("prepared: \(candidates.count, privacy: .public) grab candidate(s) \(grabMs, privacy: .public)ms, switcher off screen \(clear ? "yes" : "NO", privacy: .public) after \(clearMs, privacy: .public)ms")
            // Only meaningful once the switcher is gone — it would be on top.
            var tracked: [CGWindowID] = []
            if clear {
                Self.logTopmostWindow(at: candidates[0].point, for: window)
                tracked = Self.matchingWindowIDs(for: window)
                Log.mover.notice("tracking \(window.appName, privacy: .public) window id(s) [\(tracked.map(String.init).joined(separator: ", "), privacy: .public)] matching the captured frame")
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.preparing = false
                guard clear else {
                    Log.mover.error("aborted: switcher still on screen after \(Int(Self.clearTimeout * 1000), privacy: .public)ms; not clicking on our own window")
                    return
                }
                self.arm(window, candidates: candidates, previous: previous ?? candidates[0].point,
                         uuid: uuid, index: index, tracked: tracked)
            }
        }
    }

    private func arm(_ window: MovableWindow, candidates: [Candidate], previous: CGPoint,
                     uuid: String, index: Int, tracked: [CGWindowID]) {
        let source = CGEventSource(stateID: .hidSystemState)
        // Warping otherwise suppresses local (real) mouse input for 0.25s —
        // exactly the window in which we post the drag and the user may be
        // moving the mouse.
        source?.localEventsSuppressionInterval = 0

        inFlight = Move(uuid: uuid, index: index, window: window, candidates: candidates,
                        restoreCursor: previous, source: source, trackedIDs: tracked,
                        startedAt: DispatchTime.now())
        pressCurrentCandidate()
    }

    /// Warp, mouse-down and (after `dragDelay`) nudge at the current
    /// candidate, then hand off to the engagement check.
    private func pressCurrentCandidate() {
        guard var pending = inFlight, pending.stage == .pressing else { return }
        let candidate = pending.candidate
        let grab = candidate.point
        let release = CGPoint(x: grab.x + Self.dragDistance, y: grab.y)
        CGWarpMouseCursorPosition(grab)
        guard let token = button.press(at: grab, releaseAt: release, source: pending.source,
                                       ceiling: Self.buttonCeiling) else {
            if pending.token == 0 {
                // Nothing was ever pressed: nothing to finish.
                inFlight = nil
                Log.mover.error("could not synthesize mouse down; aborting")
                CGWarpMouseCursorPosition(pending.restoreCursor)
            } else {
                finish(reason: "aborted: could not synthesize mouse down for the next candidate",
                       failed: true)
            }
            return
        }

        pending.token = token
        pending.release = release
        pending.pressedAt = DispatchTime.now()
        pending.stage = .engaging
        pending.bail?.cancel()
        let bail = DispatchWorkItem { [weak self] in
            self?.finish(reason: "bailed out, arrival never came")
        }
        pending.bail = bail
        inFlight = pending

        Log.mover.notice("armed \(pending.window.appName, privacy: .public) pid=\(pending.window.pid, privacy: .public) grab=\(grab.logDescription, privacy: .public) candidate \(pending.candidateIndex + 1, privacy: .public)/\(pending.candidates.count, privacy: .public) tier=\(candidate.tier, privacy: .public) role=\(candidate.role, privacy: .public) dest=\(pending.uuid, privacy: .public) index=\(pending.index, privacy: .public)")
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.bailout, execute: bail)

        let source = pending.source
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dragDelay) { [weak self] in
            guard let self, self.isEngaging(token), self.button.isHeld(token) else { return }
            CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged,
                    mouseCursorPosition: release, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.engageDelay) { [weak self] in
                self?.checkEngaged(token, attempt: 1)
            }
        }
    }

    private func isEngaging(_ token: Int) -> Bool {
        inFlight?.token == token && inFlight?.stage == .engaging
    }

    /// Reads the window's position on `AX.queue` and compares it to the
    /// captured frame: a native drag has moved it by the nudge.
    private func checkEngaged(_ token: Int, attempt: Int) {
        guard let pending = inFlight, isEngaging(token) else { return }
        let element = pending.window.element
        AX.queue.async { [weak self] in
            let now = AX.frame(of: element)
            DispatchQueue.main.async {
                self?.engagementRead(token, attempt: attempt, frame: now)
            }
        }
    }

    private func engagementRead(_ token: Int, attempt: Int, frame: CGRect?) {
        guard let pending = inFlight, isEngaging(token) else { return }
        let was = pending.window.frame.origin
        let ms = AX.ms(since: pending.pressedAt)
        let grab = pending.candidate.point.logDescription

        if let frame {
            let dx = frame.origin.x - was.x, dy = frame.origin.y - was.y
            if abs(dx) >= 1 || abs(dy) >= 1 {
                Log.mover.notice("drag engaged at \(grab, privacy: .public) after \(ms, privacy: .public)ms (window moved \(String(format: "%+.0f, %+.0f", dx, dy), privacy: .public), read \(attempt, privacy: .public))")
                requestSwitch(token)
                return
            }
        }
        if attempt == 1 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.engageDelay) { [weak self] in
                self?.checkEngaged(token, attempt: 2)
            }
            return
        }
        guard frame != nil else {
            // Can't tell either way (app not answering AX). Switching is what
            // the move did before this check existed, so fall back to that.
            Log.mover.error("drag engagement unverifiable at \(grab, privacy: .public), window frame unreadable; switching anyway")
            requestSwitch(token)
            return
        }
        tryNextCandidate()
    }

    /// Switches once the drag has been held at least `switchDelay`.
    private func requestSwitch(_ token: Int) {
        guard let pending = inFlight, isEngaging(token) else { return }
        let target = pending.pressedAt.uptimeNanoseconds
            + UInt64((Self.dragDelay + Self.switchDelay) * 1_000_000_000)
        let now = DispatchTime.now().uptimeNanoseconds
        let wait = target > now ? TimeInterval(target - now) / 1_000_000_000 : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, self.isEngaging(token) else { return }
            self.inFlight?.stage = .awaitingArrival
            let index = pending.index
            if self.performSwitch(index) {
                Log.mover.notice("switch requested to index=\(index, privacy: .public)")
            } else {
                Log.mover.notice("switch refused for index=\(index, privacy: .public)")
                self.finish(reason: "released, switch refused")
            }
        }
    }

    /// The current candidate didn't start a window drag: release it (a
    /// down/up 3pt apart is just a click) and press the next, or abort
    /// without switching when none are left or the time budget is spent.
    private func tryNextCandidate() {
        guard var pending = inFlight else { return }
        let failed = pending.candidate
        button.release(pending.token, at: pending.release, source: pending.source)

        let next = pending.candidateIndex + 1
        let elapsed = TimeInterval(AX.ms(since: pending.startedAt)) / 1000
        guard next < pending.candidates.count,
              elapsed + Self.perCandidateCost <= Self.retryBudget else {
            let why = next < pending.candidates.count
                ? "retry budget spent after \(Int(elapsed * 1000))ms"
                : "no candidates left"
            Log.mover.notice("drag did not engage at \(failed.point.logDescription, privacy: .public) (role=\(failed.role, privacy: .public)), \(why, privacy: .public)")
            inFlight?.stage = .pressing  // released just above, not by the watchdog
            finish(reason: "aborted: no grab point engaged a window drag", failed: true)
            return
        }
        Log.mover.notice("drag did not engage at \(failed.point.logDescription, privacy: .public) (role=\(failed.role, privacy: .public)), trying next candidate")
        pending.candidateIndex = next
        pending.stage = .pressing
        inFlight = pending
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.interPressGap) { [weak self] in
            self?.pressCurrentCandidate()
        }
    }

    /// Called from the app delegate's real-arrival hook.
    func arrived(at uuid: String) {
        guard let pending = inFlight, pending.stage == .awaitingArrival,
              pending.uuid == uuid else { return }
        Log.mover.notice("arrived at \(uuid, privacy: .public)")
        let token = pending.token
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay) { [weak self] in
            guard let self, self.inFlight?.token == token else { return }
            self.finish(reason: "released on arrival")
        }
    }

    /// The single exit. Always releases the button and restores the cursor —
    /// leaving the button down would strand the user in a drag. `failed`
    /// logs the reason as an error (the move was abandoned, no switch).
    private func finish(reason: String, failed: Bool = false) {
        guard let pending = inFlight else { return }
        inFlight = nil
        pending.bail?.cancel()

        let window = pending.window
        // Diagnostic: which of the app's on-screen windows sit under the
        // release point right now. Chrome and Ghostty (tabs title bar) merge
        // a tab dropped on another window's tab strip into that window.
        let under = Self.onScreenWindows(pid: window.pid)
            .filter { $0.contains(pending.release) }.count
        // Token 0 = nothing pressed; otherwise false means the watchdog, or
        // the retry path, already let go.
        let releasedHere = pending.token != 0
            && button.release(pending.token, at: pending.release, source: pending.source)
        CGWarpMouseCursorPosition(pending.restoreCursor)
        let note = releasedHere || pending.stage == .pressing
            ? "" : " (button was already released by the watchdog)"
        if failed {
            Log.mover.error("\(reason, privacy: .public)\(note, privacy: .public); \(under, privacy: .public) on-screen \(window.appName, privacy: .public) window(s) under the release point")
        } else {
            Log.mover.notice("\(reason, privacy: .public)\(note, privacy: .public); \(under, privacy: .public) on-screen \(window.appName, privacy: .public) window(s) under the release point")
        }

        // Diagnostic only — where the window actually ended up. Nothing acts
        // on this; the move is best-effort by design. Off main: it's AX.
        let tracked = pending.trackedIDs
        AX.queue.asyncAfter(deadline: .now() + 0.2) {
            let landed = AX.frame(of: window.element)
            let windows = AX.windowCount(AX.app(window.pid))
            let onScreen = Set(Self.layerZeroWindows().map(\.number))
            let traveled = tracked.isEmpty ? "unknown (no window id tracked)"
                : tracked.contains(where: onScreen.contains) ? "yes" : "no"
            Log.mover.notice("\(window.appName, privacy: .public) window now at \(landed?.logDescription ?? "unreadable", privacy: .public) (was \(window.frame.logDescription, privacy: .public)); traveled: \(traveled, privacy: .public); app AX window count \(windows.map(String.init) ?? "?", privacy: .public)")
        }
    }

    /// Chrome's title bar IS its tab strip: a mouse-down on a tab selects or
    /// tears out the TAB instead of dragging the window. So candidates are
    /// ranked by AX hit test — points that land on window chrome first, then
    /// the rest as a last resort (the engagement check is the real judge).
    /// On Chrome the empty strip usually lies between the last tab and the
    /// tab-search control, hence the points counted in from the right. Runs
    /// on `AX.queue`.
    private static func grabCandidates(for window: MovableWindow) -> [Candidate] {
        let f = window.frame
        let y = f.minY + 12
        let xs = [f.midX, f.maxX - 160, f.maxX - 220, f.minX + 96, f.maxX - 28,
                  f.midX - 200, f.midX + 200]
        // Clamp into the window, and keep candidates well apart: two clicks
        // close together in quick succession would read as a double-click,
        // which zooms the window.
        var points: [CGPoint] = []
        for x in xs {
            let p = CGPoint(x: min(max(x, f.minX + 8), f.maxX - 8), y: y)
            if !points.contains(where: { abs($0.x - p.x) < 40 }) { points.append(p) }
        }
        // Roles that are safe to drag a window by. Everything else — AXButton,
        // AXTabGroup, AXTextField, AXPopUpButton, AXImage … — is a control
        // that would swallow the drag.
        let draggable: Set<String> = [kAXWindowRole, kAXToolbarRole,
                                      kAXStaticTextRole, kAXGroupRole, "AXUnknown"]

        var accepted: [Candidate] = [], fallback: [Candidate] = []
        let app = AX.app(window.pid)
        for p in points {
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(app, Float(p.x), Float(p.y), &hit)
                    == .success, let hit else {
                Log.mover.notice("grab point \(p.logDescription, privacy: .public) hit test failed")
                fallback.append(Candidate(point: p, tier: "fallback", role: "unknown"))
                continue
            }
            AX.bounded(hit)
            let isWindow = CFEqual(hit, window.element)
            let role = AX.string(hit, kAXRoleAttribute) ?? "nil"
            let ok = isWindow || draggable.contains(role)
            Log.mover.notice("grab point \(p.logDescription, privacy: .public) \(ok ? "accepted" : "rejected", privacy: .public)\(isWindow ? " (the window itself)" : "", privacy: .public) \(describe(hit, role: role), privacy: .public)")
            if ok {
                accepted.append(Candidate(point: p, tier: "accepted", role: role))
            } else if role == kAXButtonRole {
                // A click on a button does something (closes a tab, opens
                // tab search), so it isn't worth even a last-resort try.
                continue
            } else {
                fallback.append(Candidate(point: p, tier: "fallback", role: role))
            }
        }
        var ordered = Array((accepted + fallback).prefix(maxCandidates))
        if ordered.isEmpty {
            // Everything was a button: the middle is still the least bad.
            ordered = [Candidate(point: points[0], tier: "fallback", role: "none usable")]
        }
        let summary = ordered.enumerated().map { i, c in
            "\(i + 1). \(c.point.logDescription) \(c.tier) \(c.role)"
        }.joined(separator: "; ")
        Log.mover.notice("grab candidates in order: \(summary, privacy: .public)")
        return ordered
    }

    /// One line on what a hit-test element is: subrole, its title or
    /// description, and the roles of up to four ancestors. Runs on `AX.queue`.
    private static func describe(_ element: AXUIElement, role: String) -> String {
        let subrole = AX.string(element, kAXSubroleAttribute) ?? "nil"
        let label = [kAXTitleAttribute, kAXDescriptionAttribute]
            .lazy.compactMap { AX.string(element, $0) }.first { !$0.isEmpty } ?? ""
        var chain: [String] = []
        var current = element
        for _ in 0..<4 {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &ref)
                    == .success, let parentRef = ref,
                  CFGetTypeID(parentRef) == AXUIElementGetTypeID() else { break }
            let parent = AX.bounded(parentRef as! AXUIElement)
            chain.append(AX.string(parent, kAXRoleAttribute) ?? "nil")
            current = parent
        }
        return "role=\(role) subrole=\(subrole) label=\"\(label.prefix(40))\" parents=\(chain.isEmpty ? "none" : chain.joined(separator: ">"))"
    }

    /// Logs which window WindowServer has on top at the grab point — if it
    /// isn't the captured app's, the mouse-down goes to someone else.
    private static func logTopmostWindow(at point: CGPoint, for window: MovableWindow) {
        guard let top = layerZeroWindows().first(where: { $0.bounds.contains(point) }) else {
            Log.mover.error("no on-screen window under grab point \(point.logDescription, privacy: .public)")
            return
        }
        let same = matches(top.bounds, window.frame)
        Log.mover.notice("topmost window at grab point \(point.logDescription, privacy: .public): pid=\(top.pid, privacy: .public) owner=\(top.owner, privacy: .public) id=\(top.number, privacy: .public) bounds=\(top.bounds.logDescription, privacy: .public) matches captured frame: \(same ? "yes" : "no", privacy: .public)")
        if top.pid != window.pid {
            Log.mover.error("grab point is covered by another app's window (\(top.owner, privacy: .public) pid=\(top.pid, privacy: .public)); proceeding anyway")
        }
    }

    /// The app's on-screen normal-layer windows whose bounds match the
    /// captured frame — usually exactly the captured window.
    private static func matchingWindowIDs(for window: MovableWindow) -> [CGWindowID] {
        layerZeroWindows()
            .filter { $0.pid == window.pid && matches($0.bounds, window.frame) }
            .map(\.number)
    }

    private static func matches(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2
            && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
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

    private struct ScreenWindow {
        let pid: pid_t
        let owner: String
        let number: CGWindowID
        /// CG top-left coordinates.
        let bounds: CGRect
    }

    /// Every normal-layer window on screen right now, front to back.
    private static func layerZeroWindows() -> [ScreenWindow] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                              kCGNullWindowID) as? [[String: Any]] ?? []
        return info.compactMap { w in
            guard (w[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let number = (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let bounds = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return nil }
            return ScreenWindow(pid: pid, owner: w[kCGWindowOwnerName as String] as? String ?? "?",
                                number: number, bounds: rect)
        }
    }

    /// Bounds (CG top-left coordinates) of the app's normal-layer windows
    /// that are on screen right now.
    private static func onScreenWindows(pid: pid_t) -> [CGRect] {
        layerZeroWindows().filter { $0.pid == pid }.map(\.bounds)
    }
}
