import AppKit
import ApplicationServices

struct PlacementSpec: Codable, Equatable {
    enum Preset: String, Codable, CaseIterable {
        case leftHalf, rightHalf, maximized, centered, custom
        var label: String {
            switch self {
            case .leftHalf: return "Left Half"
            case .rightHalf: return "Right Half"
            case .maximized: return "Maximized"
            case .centered: return "Centered"
            case .custom: return "Custom (captured)"
            }
        }
    }
    var preset: Preset = .leftHalf
    /// CG global coordinates (top-left origin) — the space AX and
    /// CGDisplayBounds share. Only read when preset == .custom.
    var customRect: CGRect?
}

enum PlacementGeometry {
    /// AX and CGDisplayBounds share a top-left-origin coordinate space
    /// (AXAttributeConstants.h documents this), so no NSScreen flip exists
    /// anywhere in this feature. The menu-bar inset is a scalar height,
    /// not a coordinate conversion.
    static func targetRect(for spec: PlacementSpec, visible: CGRect) -> CGRect? {
        switch spec.preset {
        case .leftHalf:
            return CGRect(x: visible.minX, y: visible.minY,
                          width: visible.width / 2, height: visible.height)
        case .rightHalf:
            return CGRect(x: visible.midX, y: visible.minY,
                          width: visible.width / 2, height: visible.height)
        case .maximized:
            return visible
        case .centered:
            return visible.insetBy(dx: visible.width * 0.125, dy: visible.height * 0.125)
        case .custom:
            return spec.customRect
        }
    }

    /// Main display bounds minus menu bar and Dock, in CG coordinates.
    /// NSScreen's visibleFrame supplies the insets as scalar distances from
    /// the screen edges — still no coordinate flip, since only widths and
    /// edge offsets cross between the two spaces, never a y origin.
    static func mainVisibleRect() -> CGRect {
        let display = CGDisplayBounds(CGMainDisplayID())
        guard let screen = NSScreen.main else { return display }
        let top = screen.frame.maxY - screen.visibleFrame.maxY
        let bottom = screen.visibleFrame.minY - screen.frame.minY
        let left = screen.visibleFrame.minX - screen.frame.minX
        return CGRect(x: display.minX + left, y: display.minY + top,
                      width: screen.visibleFrame.width,
                      height: display.height - top - bottom)
    }
}

/// Places the NEXT window an app creates. One-shot: arm it immediately
/// before triggering the window (⌘N, profile launch, or cold launch).
/// Best-effort by design — a window that resists placement is left alone.
final class WindowPlacer {
    private let queue = DispatchQueue(label: "window-placer", qos: .userInteractive)
    private var observer: AXObserver?
    private var pollTimer: Timer?
    private var appElement: AXUIElement?
    private var before: [AXUIElement] = []
    private var target: CGRect = .zero
    private var deadline: Date = .distantPast
    private var active = false

    /// `wait` covers slower window sources: profile-forwarded Chrome launches
    /// load the profile before showing a window and can blow the default.
    func placeNextWindow(pid: pid_t, frame: CGRect, wait: TimeInterval = 3.0) {
        guard AXIsProcessTrusted(), pid > 0 else {
            NSLog("WindowPlacer: not armed (AX trusted=%d pid=%d)", AXIsProcessTrusted() ? 1 : 0, pid)
            return
        }
        cancel()
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0) // default 6s; these are sync IPC
        appElement = app
        before = Self.windows(of: app)
        target = frame
        deadline = Date().addingTimeInterval(wait)
        active = true
        NSLog("WindowPlacer: armed pid=%d snapshot=%d wait=%.1fs", pid, before.count, wait)

        // Observer for low latency; the poll below is the reliability layer
        // (macOS 26 AX notifications can silently die — Phoenix #366).
        var obs: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<WindowPlacer>.fromOpaque(refcon).takeUnretainedValue().check()
        }
        if AXObserverCreate(pid, callback, &obs) == .success, let obs {
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            AXObserverAddNotification(obs, app, kAXWindowCreatedNotification as CFString, refcon)
            AXObserverAddNotification(obs, app, kAXMainWindowChangedNotification as CFString, refcon)
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
            observer = obs
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.check()
        }
    }

    /// Cold-launch arm: window detection can't start until the process
    /// exists. Registration succeeds well before the AX tree is readable
    /// (~0.7s vs ~2.3s measured on a cold launch), so hooking didLaunch
    /// reliably catches the first window.
    func armForColdLaunch(bundleID: String, frame: CGRect, wait: TimeInterval = 3.0) {
        // The token only exists after addObserver returns, so both the
        // observer body and the timeout below reach it through a box —
        // a captured `var` would be a mutated-after-capture race.
        let box = TokenBox()
        box.token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let launched = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  launched.bundleIdentifier == bundleID else { return }
            box.remove()
            self?.placeNextWindow(pid: launched.processIdentifier, frame: frame, wait: wait)
        }
        // Don't wait forever if the launch fails.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            box.remove()
        }
    }

    /// Main-thread-only holder for one didLaunch registration.
    private final class TokenBox {
        var token: NSObjectProtocol?
        func remove() {
            guard let token else { return }
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            self.token = nil
        }
    }

    private func check() {
        guard active, let app = appElement else { return }
        guard Date() < deadline else {
            NSLog("WindowPlacer: timed out, no new window detected")
            cancel()
            return
        }
        let now = Self.windows(of: app)
        // Identity diff vs the pre-trigger snapshot. AXUIElement is a CFType:
        // CFEqual-based contains(). Ghostty tabs show as extra "windows" in
        // the snapshot — harmless, they were in `before` too.
        guard let fresh = now.first(where: { w in !before.contains(where: { CFEqual($0, w) }) })
        else { return }
        active = false
        let frame = target
        cancel()
        NSLog("WindowPlacer: new window detected, applying %@", String(describing: frame))
        queue.async { Self.apply(frame: frame, to: fresh, appElement: app) }
    }

    private func cancel() {
        pollTimer?.invalidate(); pollTimer = nil
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(),
                                  AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        active = false
    }

    private static func windows(of app: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
                == .success else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    private static func apply(frame: CGRect, to window: AXUIElement, appElement: AXUIElement) {
        // AXEnhancedUserInterface dance: when true, AX moves animate and land
        // wrong (Chromium/Firefox bug). Read → false → work → restore what
        // was read. Writing `true` is what wakes Chrome's accessibility
        // engine (a persistent perf hit), so we only ever restore an
        // observed true — on a machine without assistive tech this whole
        // dance is a no-op.
        let enhancedKey = "AXEnhancedUserInterface" as CFString
        var enhancedValue: CFTypeRef?
        AXUIElementCopyAttributeValue(appElement, enhancedKey, &enhancedValue)
        let wasEnhanced = (enhancedValue as? Bool) == true
        if wasEnhanced {
            AXUIElementSetAttributeValue(appElement, enhancedKey, kCFBooleanFalse)
        }
        defer {
            if wasEnhanced {
                AXUIElementSetAttributeValue(appElement, enhancedKey, kCFBooleanTrue)
            }
        }

        var resizable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &resizable)

        var pos = frame.origin
        var size = frame.size
        guard let posValue = AXValueCreate(.cgPoint, &pos),
              let sizeValue = AXValueCreate(.cgSize, &size) else { return }
        // size → position → size: macOS enforces on-display sizes, so a
        // lone ordering ends up clamped. Return codes are meaningless here
        // (success even when clamped) — read-back is the only truth.
        if resizable.boolValue {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        }
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
        if resizable.boolValue {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        }

        var readBack: CFTypeRef?
        var landed = CGPoint.zero
        if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &readBack)
            == .success, let v = readBack {
            AXValueGetValue(v as! AXValue, .cgPoint, &landed)
        }
        // Tolerance, not equality: terminals quantize, and a consistent 1px
        // height delta on Ghostty is expected (cause unexplained — do not
        // "fix" it here).
        if abs(landed.x - frame.origin.x) > 8 || abs(landed.y - frame.origin.y) > 8 {
            NSLog("WindowPlacer: window landed at %@ instead of %@ (best-effort, leaving it)",
                  String(describing: landed), String(describing: frame.origin))
        }
    }
}

extension WindowPlacer {
    /// Frame of the app's focused window, in CG/AX coordinates — used by
    /// "Capture Current Window" in Preferences.
    static func currentWindowFrame(bundleID: String) -> CGRect? {
        guard AXIsProcessTrusted(),
              let running = NSRunningApplication
                  .runningApplications(withBundleIdentifier: bundleID).first
        else { return nil }
        let app = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 1.0)
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &winRef)
                == .success, let win = winRef else { return nil }
        let window = win as! AXUIElement
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
}
