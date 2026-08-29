# Quick-Launch Profiles + Window Placement Implementation Plan

**Goal:** Quick-launch entries can open Chrome in a specific user profile and place the new window at a configured position — each layer independently and globally toggleable, with "off" meaning exactly today's behavior — configured through a new Preferences window.

**Architecture:** Two optional layers on top of the existing `QuickLauncher` flow (switch space → settle → open). Layer 1 (Chrome profiles): when an entry has a profile and the global toggle is on, launch via `NSWorkspace.openApplication` with `--profile-directory` args and `createsNewApplicationInstance = true` (works warm and cold via Chrome's singleton forwarding), replacing the ⌘N path for that entry. Layer 2 (placement): a `WindowPlacer` armed *before* triggering the window — AX snapshot diff + `AXObserver` + 50 ms poll to detect the new window, then size→position→size with the `AXEnhancedUserInterface` dance. All config lives in `Settings` (UserDefaults, `Codable`), edited in a new Preferences window following the `ActionsEditorController` pattern. No new private APIs, no new TCC permissions (Accessibility already granted).

**Tech Stack:** Swift / SPM executable, AppKit + SwiftUI, public HIServices AX APIs (`AXUIElementCreateApplication`, `AXObserverCreate`, `kAXPosition/SizeAttribute`), `NSWorkspace.OpenConfiguration`, XCTest for pure logic.

**Research provenance:** Mechanisms verified empirically on this machine 2026-08-27 (Chrome 151, macOS 26.6.2): singleton arg-forwarding works warm; detection latencies ⌘N→window 116–650 ms so fixed delays are forbidden; `AXUIElementSetAttributeValue` returns success even when it clamps, so read back with tolerance; poll beats notification by 74–90 ms and macOS 26 AX notifications have a known reliability regression, so the poll is mandatory, not defensive.

**Verification reality:** No test target exists today; Task 1 adds one for pure logic (JSON parsing, rect math). The AX/launch flows are permission- and timing-dependent and are verified by the human checklist in Task 9. Build check throughout is `swift build` (fast) with `scripts/build-app.sh` for the signed bundle (preserves TCC grants).

---

## Task 1 — Test target scaffold

**Files:**
- Modify: `Package.swift`
- Create: `Tests/SpaceManagerTests/ChromeProfilesTests.swift` (placeholder; real tests land with their features)

`Package.swift` becomes:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SpaceManager",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "SpaceManager", path: "Sources/SpaceManager"),
        .testTarget(name: "SpaceManagerTests",
                    dependencies: ["SpaceManager"],
                    path: "Tests/SpaceManagerTests")
    ]
)
```

Placeholder test file:

```swift
import XCTest
@testable import SpaceManager

final class ChromeProfilesTests: XCTestCase {
    func testScaffold() { XCTAssertTrue(true) }
}
```

**Test:** `swift test` → `Test Suite 'All tests' passed`. (Note: test targets may depend on executable targets since SwiftPM 5.5; `main.swift` top-level code does not run under test import. If linking fails here, stop and flag — don't restructure the package without discussion.)

**Commit:** `Add SPM test target scaffold`

---

## Task 2 — Chrome profile discovery (`ChromeProfiles.swift`)

**Files:**
- Create: `Sources/SpaceManager/ChromeProfiles.swift`
- Modify: `Tests/SpaceManagerTests/ChromeProfilesTests.swift`

Reads Chrome's `Local State` JSON. Structure (verified 2026-08-27): `profile.info_cache` maps directory names (`"Default"`, `"Profile 1"`) to `{name, user_name, is_ephemeral, ...}`; `profile.profiles_order` gives display order.

```swift
import Foundation

/// Chrome profile discovery. Reads Chrome's Local State file — read-only,
/// no Chrome APIs involved. Directory names are the exact values Chrome's
/// --profile-directory switch accepts.
enum ChromeProfiles {
    struct Profile: Identifiable, Equatable {
        let directory: String   // "Default", "Profile 1" — the switch value
        let name: String        // user-facing, e.g. "Taylor"
        let email: String?
        var id: String { directory }
        var label: String { email.map { "\(name) (\($0))" } ?? name }
    }

    static var localStateURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/Local State")
    }

    /// Empty array when Chrome isn't installed or the file is unreadable —
    /// callers treat that as "profile targeting unavailable", never an error.
    static func load(from url: URL = localStateURL) -> [Profile] {
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let profile = root["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: [String: Any]]
        else { return [] }
        let order = (profile["profiles_order"] as? [String]) ?? cache.keys.sorted()
        return order.compactMap { dir in
            guard let info = cache[dir],
                  (info["is_ephemeral"] as? Bool) != true else { return nil }
            let email = (info["user_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return Profile(directory: dir,
                           name: (info["name"] as? String) ?? dir,
                           email: email)
        }
    }

    /// Guard against launching with a stale directory name: Chrome silently
    /// CREATES a junk profile for an unknown --profile-directory value.
    static func exists(_ directory: String) -> Bool {
        load().contains { $0.directory == directory }
    }
}
```

Tests (replace placeholder body):

```swift
import XCTest
@testable import SpaceManager

final class ChromeProfilesTests: XCTestCase {
    private func write(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalState-\(UUID().uuidString)")
        try json.data(using: .utf8)!.write(to: url)
        return url
    }

    func testParsesProfilesInOrder() throws {
        let url = try write(#"""
        {"profile":{"profiles_order":["Profile 1","Default"],
          "info_cache":{
            "Default":{"name":"Taylor","user_name":"t@gmail.com"},
            "Profile 1":{"name":"Work","user_name":"t@work.com"}}}}
        """#)
        let profiles = ChromeProfiles.load(from: url)
        XCTAssertEqual(profiles.map(\.directory), ["Profile 1", "Default"])
        XCTAssertEqual(profiles[1].name, "Taylor")
        XCTAssertEqual(profiles[1].email, "t@gmail.com")
    }

    func testSkipsEphemeralAndHandlesMissingOrder() throws {
        let url = try write(#"""
        {"profile":{"info_cache":{
            "Default":{"name":"Taylor"},
            "Guest":{"name":"Guest","is_ephemeral":true}}}}
        """#)
        let profiles = ChromeProfiles.load(from: url)
        XCTAssertEqual(profiles.map(\.directory), ["Default"])
        XCTAssertNil(profiles[0].email)
    }

    func testUnreadableFileYieldsEmpty() {
        XCTAssertEqual(ChromeProfiles.load(from: URL(fileURLWithPath: "/nonexistent")), [])
    }
}
```

**Test:** `swift test` → all pass.

**Commit:** `Add Chrome profile discovery from Local State`

---

## Task 3 — Settings model: toggles, per-entry profile + placement

**Files:**
- Modify: `Sources/SpaceManager/QuickLaunch.swift` (struct `QuickLaunchApp`, lines 8–17)
- Modify: `Sources/SpaceManager/Settings.swift` (class `Settings`)
- Create: `Sources/SpaceManager/Placement.swift` (spec + geometry; engine comes in Task 5)
- Modify: `Tests/SpaceManagerTests/` — add `PlacementGeometryTests.swift`

New fields on `QuickLaunchApp` — both optional so previously-persisted entries keep decoding (same back-compat pattern as `newWindowKey`):

```swift
    /// Chrome profile directory ("Default", "Profile 1"); nil = no targeting.
    var chromeProfile: String?
    /// Where the new window should land; nil = leave it where the app puts it.
    var placement: PlacementSpec?
```

`Placement.swift` (spec + pure geometry only):

```swift
import AppKit

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

    /// Main display bounds minus the menu bar, in CG coordinates.
    static func mainVisibleRect() -> CGRect {
        let display = CGDisplayBounds(CGMainDisplayID())
        let menuBar = NSScreen.main.map { $0.frame.maxY - $0.visibleFrame.maxY } ?? 25
        return CGRect(x: display.minX, y: display.minY + menuBar,
                      width: display.width, height: display.height - menuBar)
    }
}
```

`Settings` additions (follow the existing `@Published { didSet { save() } }` + keyed-load pattern; note existing `hudIndicator` shows the default-true idiom):

```swift
    /// Master switches. Off = quick-launch behaves exactly as before this
    /// feature existed (⌘N / plain cold launch, no window moving) — the off
    /// state is the escape hatch for machines where AX side effects matter.
    @Published var chromeProfilesEnabled: Bool { didSet { save() } }
    @Published var windowPlacementEnabled: Bool { didSet { save() } }
```

In `init()`:

```swift
        chromeProfilesEnabled = d.object(forKey: "quickLaunchProfilesEnabled") == nil
            ? true : d.bool(forKey: "quickLaunchProfilesEnabled")
        windowPlacementEnabled = d.object(forKey: "quickLaunchPlacementEnabled") == nil
            ? true : d.bool(forKey: "quickLaunchPlacementEnabled")
```

In `save()`:

```swift
        d.set(chromeProfilesEnabled, forKey: "quickLaunchProfilesEnabled")
        d.set(windowPlacementEnabled, forKey: "quickLaunchPlacementEnabled")
```

`PlacementGeometryTests.swift`:

```swift
import XCTest
@testable import SpaceManager

final class PlacementGeometryTests: XCTestCase {
    let visible = CGRect(x: 0, y: 30, width: 3840, height: 1590)

    func testHalves() {
        let left = PlacementGeometry.targetRect(for: .init(preset: .leftHalf), visible: visible)
        XCTAssertEqual(left, CGRect(x: 0, y: 30, width: 1920, height: 1590))
        let right = PlacementGeometry.targetRect(for: .init(preset: .rightHalf), visible: visible)
        XCTAssertEqual(right, CGRect(x: 1920, y: 30, width: 1920, height: 1590))
    }

    func testCustomPassesThroughAndNilWhenUncaptured() {
        let rect = CGRect(x: 10, y: 40, width: 800, height: 600)
        XCTAssertEqual(PlacementGeometry.targetRect(
            for: .init(preset: .custom, customRect: rect), visible: visible), rect)
        XCTAssertNil(PlacementGeometry.targetRect(
            for: .init(preset: .custom, customRect: nil), visible: visible))
    }

    func testOldEntriesDecodeWithoutNewFields() throws {
        let json = #"[{"id":"00000000-0000-0000-0000-000000000000","label":"Chrome","bundleID":"com.google.Chrome","keyEquivalent":"c"}]"#
        let apps = try JSONDecoder().decode([QuickLaunchApp].self, from: json.data(using: .utf8)!)
        XCTAssertNil(apps[0].chromeProfile)
        XCTAssertNil(apps[0].placement)
    }
}
```

**Test:** `swift test` → all pass (the decode test is the back-compat guarantee — existing users' saved lists must not reset).

**Commit:** `Add placement spec/geometry and quick-launch config fields`

---

## Task 4 — Profile-targeted Chrome launch path

**Files:**
- Modify: `Sources/SpaceManager/QuickLaunch.swift` — `QuickLauncher.open(_:)` (lines 112–126) + one new method

Replace `open(_:)` and add `launchWithChromeProfile`:

```swift
    /// "Open X on this space" has to mean a NEW window here. Three mechanisms:
    /// profile-targeted Chrome launch (works warm AND cold), ⌘N synthesis
    /// (warm), plain cold launch. The profile path only engages when the
    /// global toggle is on, the entry has a profile, and that profile still
    /// exists — every other case falls through to the pre-existing behavior,
    /// which is what "turned off" means.
    private func open(_ app: QuickLaunchApp) {
        if settings.chromeProfilesEnabled,
           let dir = app.chromeProfile, ChromeProfiles.exists(dir) {
            launchWithChromeProfile(dir, app: app)
            return
        }
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

    /// Chrome honors --profile-directory warm or cold: a cold launch reads it
    /// as the startup profile; against a running Chrome the spawned process
    /// forwards its command line over Chrome's singleton socket and exits
    /// (no second instance survives). createsNewApplicationInstance = true is
    /// required — without it, LaunchServices just activates the running app
    /// and the arguments are silently dropped. NOTE: OpenConfiguration
    /// .arguments is ignored if this app is ever sandboxed — this whole path
    /// depends on staying un-sandboxed (we are: Developer ID only).
    private func launchWithChromeProfile(_ directory: String, app: QuickLaunchApp) {
        guard let url = app.url else { return }
        let wasRunning = app.runningInstance
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = ["--profile-directory=\(directory)",
                            "--ignore-profile-directory-if-not-exists"]
        config.createsNewApplicationInstance = true
        config.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: config) { launched, _ in
            // Focus the REAL instance, not the exiting messenger process.
            // Empty options is load-bearing (see newWindow above): it brings
            // only main+key windows, so other spaces' windows stay put.
            let target = wasRunning ?? launched
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                target?.activate(options: [])
            }
        }
    }
```

**Test:** `swift build` clean, then `bash scripts/build-app.sh` and a live check: set a profile on the Chrome entry via defaults for now (Preferences UI lands in Task 7):

```bash
# one-time test seed — read current value first, then re-save with profile via
# the running app after Task 7 instead if preferred
defaults read com.taylorbird.spacemanager proto.quickLaunch
```

Expected live behavior (with Chrome running): ⌘C on a non-current space switches, waits settle, and a new Chrome window in the configured profile appears on that space; Chrome's window title suffix shows the profile name. With `chromeProfilesEnabled` false: identical to today (⌘N, last-active profile).

**Commit:** `Quick-launch: profile-targeted Chrome launches behind global toggle`

---

## Task 5 — WindowPlacer engine

**Files:**
- Modify: `Sources/SpaceManager/Placement.swift` (append the engine)

Design constraints baked in (all measured, see provenance):
- Arm BEFORE triggering the window; snapshot first (Chrome emits spurious `kAXWindowCreated` for old windows — identity diff is mandatory).
- Observer (`kAXWindowCreated` + `kAXMainWindowChanged`) AND a 50 ms poll, 3 s deadline — the poll beat the notification in every measured run and survives the macOS 26 notification regression. Don't poll faster: each iteration is sync IPC (~30 ms on Chrome).
- Apply size→position→size (macOS clamps otherwise; the only attested ordering), inside the `AXEnhancedUserInterface` read→false→restore dance (restore-what-was-read: on a flag-false machine this never writes true and Chrome's a11y engine never wakes).
- The set calls return success even when they clamp — verify by read-back with tolerance, log only (placement is best-effort by design).
- AX calls off the main thread (the 3-call sequence costs ~100 ms on Chrome).

```swift
import ApplicationServices

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

    func placeNextWindow(pid: pid_t, frame: CGRect) {
        guard AXIsProcessTrusted(), pid > 0 else { return }
        cancel()
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0) // default 6s; these are sync IPC
        appElement = app
        before = Self.windows(of: app)
        target = frame
        deadline = Date().addingTimeInterval(3.0)
        active = true

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
    func armForColdLaunch(bundleID: String, frame: CGRect) {
        var token: NSObjectProtocol?
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let launched = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  launched.bundleIdentifier == bundleID else { return }
            if let token { NSWorkspace.shared.notificationCenter.removeObserver(token) }
            self?.placeNextWindow(pid: launched.processIdentifier, frame: frame)
        }
        // Don't wait forever if the launch fails.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            if let token { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        }
    }

    private func check() {
        guard active, let app = appElement else { return }
        guard Date() < deadline else { cancel(); return }
        let now = Self.windows(of: app)
        // Identity diff vs the pre-trigger snapshot. AXUIElement is a CFType:
        // CFEqual-based contains(). Ghostty tabs show as extra "windows" in
        // the snapshot — harmless, they were in `before` too.
        guard let fresh = now.first(where: { w in !before.contains(where: { CFEqual($0, w) }) })
        else { return }
        active = false
        let frame = target
        cancel()
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

        var check: CFTypeRef?
        var landed = CGPoint.zero
        if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &check)
            == .success, let v = check {
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
```

Also expose the capture helper (used by Preferences in Task 7) — append to `Placement.swift`:

```swift
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
```

**Test:** `swift build` clean. Engine is exercised live in Task 6's verification.

**Commit:** `Add WindowPlacer: AX new-window detection and best-effort placement`

---

## Task 6 — Wire placement into QuickLauncher

**Files:**
- Modify: `Sources/SpaceManager/QuickLaunch.swift` — `QuickLauncher` (add field + arm calls in `open(_:)`)

Add to `QuickLauncher`:

```swift
    private let placer = WindowPlacer()
```

At the TOP of `open(_:)` (before any launch branch — the placer must be armed before the window is triggered):

```swift
        // Arm placement first so the AX snapshot/observer predate the new
        // window. Global toggle off, or no placement on the entry, or an
        // uncaptured custom rect → no arming, windows land wherever the app
        // puts them (pre-feature behavior).
        if settings.windowPlacementEnabled, let spec = app.placement,
           let rect = PlacementGeometry.targetRect(
               for: spec, visible: PlacementGeometry.mainVisibleRect()) {
            if let running = app.runningInstance, !running.isTerminated {
                placer.placeNextWindow(pid: running.processIdentifier, frame: rect)
            } else {
                placer.armForColdLaunch(bundleID: app.bundleID, frame: rect)
            }
        }
```

**Test:** `swift build`, `bash scripts/build-app.sh`, relaunch. Live checks (seed a placement on the Ghostty entry via defaults until Task 7's UI):
- Warm Ghostty + left-half placement: ⌘G on another space → window appears, then snaps to left half within ~a quarter second.
- Toggle `windowPlacementEnabled` off (defaults write `quickLaunchPlacementEnabled -bool false` + relaunch) → window appears wherever Ghostty puts it, untouched.

**Commit:** `Quick-launch: arm window placement before opening, behind global toggle`

---

## Task 7 — Preferences window

**Files:**
- Create: `Sources/SpaceManager/Preferences.swift` (controller + SwiftUI view)
- Modify: `Sources/SpaceManager/Settings.swift` line 50–51 (stale "no editor yet" comment → "edited in Preferences")

Controller — same shape as `ActionsEditorController` (`ActionsEditor.swift:6–33`):

```swift
import AppKit
import SwiftUI

final class PreferencesController {
    private let settings: Settings
    private var window: NSWindow?

    init(settings: Settings) { self.settings = settings }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: .zero,
                             styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
            w.title = "SpaceManager Preferences"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: PreferencesView(settings: settings))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
```

View. Layout: master toggles up top (the off switches are the headline requirement), then the quick-launch list with per-entry editors. Chrome profile picker appears only for entries whose `bundleID == "com.google.Chrome"` and only when `ChromeProfiles.load()` is non-empty. Placement picker offers "Don't position" (nil) + the presets + Capture.

```swift
struct PreferencesView: View {
    @ObservedObject var settings: Settings
    private let profiles = ChromeProfiles.load()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Quick Launch").font(.headline)

            Toggle("Open Chrome in a specific profile", isOn: $settings.chromeProfilesEnabled)
            Toggle("Position new windows", isOn: $settings.windowPlacementEnabled)
            Text("Both off = plain launches, exactly as before these features existed.")
                .font(.system(size: 11)).foregroundStyle(.secondary)

            Divider()

            ForEach($settings.quickLaunch) { $app in
                QuickLaunchRow(app: $app, profiles: profiles,
                               profilesEnabled: settings.chromeProfilesEnabled,
                               placementEnabled: settings.windowPlacementEnabled,
                               onDelete: {
                                   settings.quickLaunch.removeAll { $0.id == app.id }
                               })
            }

            Button { addApp() } label: { Label("Add App", systemImage: "plus") }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
        let label = url.deletingPathExtension().lastPathComponent
        settings.quickLaunch = QuickLaunchApp.normalized(
            settings.quickLaunch + [QuickLaunchApp(label: label, bundleID: id)])
    }
}

struct QuickLaunchRow: View {
    @Binding var app: QuickLaunchApp
    let profiles: [ChromeProfiles.Profile]
    let profilesEnabled: Bool
    let placementEnabled: Bool
    var onDelete: () -> Void

    private var isChrome: Bool { app.bundleID == "com.google.Chrome" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let icon = app.icon {
                    Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                }
                Text(app.label)
                Text("⌘").foregroundStyle(.secondary)
                TextField("", text: Binding(
                    get: { app.keyEquivalent.uppercased() },
                    set: { app.keyEquivalent = String($0.lowercased().suffix(1)) }
                ))
                .textFieldStyle(.roundedBorder).frame(width: 32)
                Spacer()
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }.buttonStyle(.borderless)
            }

            if isChrome, !profiles.isEmpty {
                Picker("Profile", selection: Binding(
                    get: { app.chromeProfile ?? "" },
                    set: { app.chromeProfile = $0.isEmpty ? nil : $0 }
                )) {
                    Text("Last used (default)").tag("")
                    ForEach(profiles) { p in Text(p.label).tag(p.directory) }
                }
                .disabled(!profilesEnabled)
            }

            HStack(spacing: 8) {
                Picker("Position", selection: Binding(
                    get: { app.placement?.preset.rawValue ?? "" },
                    set: { raw in
                        if raw.isEmpty { app.placement = nil }
                        else if let preset = PlacementSpec.Preset(rawValue: raw) {
                            var spec = app.placement ?? PlacementSpec()
                            spec.preset = preset
                            app.placement = spec
                        }
                    }
                )) {
                    Text("Don't position").tag("")
                    ForEach(PlacementSpec.Preset.allCases, id: \.rawValue) { p in
                        Text(p.label).tag(p.rawValue)
                    }
                }
                if app.placement?.preset == .custom {
                    Button("Capture Current Window") {
                        if let frame = WindowPlacer.currentWindowFrame(bundleID: app.bundleID) {
                            app.placement?.customRect = frame
                        }
                    }
                    if app.placement?.customRect == nil {
                        Text("app must be running with a window")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(!placementEnabled)
        }
        .font(.system(size: 12))
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }
}
```

Binding note for the executor: `ForEach($settings.quickLaunch)` gives element bindings whose writes mutate the array, which fires `didSet` → `save()`. Verify a change actually persists across relaunch during testing; if element-binding writes don't propagate on this toolchain, fall back to index-based `ForEach(settings.quickLaunch.indices, ...)` with an explicit `settings.quickLaunch[i] = updated` setter (the `ActionsEditor.swift:87–100` onChange pattern).

**Test:** `swift build` clean; visual/behavioral check happens in Task 8's wiring.

**Commit:** `Add Preferences window: quick-launch list, Chrome profiles, placement`

---

## Task 8 — Wire Preferences into the app

**Files:**
- Modify: `Sources/SpaceManager/main.swift` — add `var preferences: PreferencesController!` next to line 52's `actionsEditor`; construct after line 73: `preferences = PreferencesController(settings: settings)`; add handler in the `StatusBarController` init block (line 81's `handlers:`): `openPreferences: { [weak self] in self?.preferences.show() }`
- Modify: `Sources/SpaceManager/StatusBar.swift` — add `var openPreferences: () -> Void` to `Handlers` (line 8–14); in `menuNeedsUpdate` after the "Edit Actions…" item (line 98), add:

```swift
        let prefs = NSMenuItem(title: "Preferences…", action: #selector(openPreferences(_:)),
                               keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)
```

and the action:

```swift
    @objc private func openPreferences(_ sender: NSMenuItem) { handlers.openPreferences() }
```

**Test:** `swift build`, `bash scripts/build-app.sh`, relaunch. Menu bar → Preferences… opens the window; toggles flip and persist across relaunch (`defaults read com.taylorbird.spacemanager quickLaunchProfilesEnabled`); Chrome row shows the profile picker with real profile names; adding/removing an app updates the switcher's footer immediately (it reads `settings.quickLaunch` live via `SwitcherUI.swift:90`).

**Commit:** `Wire Preferences window into status bar menu`

---

## Task 9 — Human verification checklist (gate before calling it shipped)

Run through with the rebuilt app. Config via Preferences UI only.

1. **Profile warm path:** Chrome running with a work-profile window. Set Chrome entry → profile "Taylor" (Default), placement off. Switcher → highlight non-current space → ⌘C. Expect: switch, settle, new Chrome window **in the personal profile** on that space (title suffix shows profile name). Confirm no second Chrome in Activity Monitor.
2. **Profile cold path:** Quit Chrome fully. Same ⌘C. Expect: Chrome cold-starts with a personal-profile window on the target space.
3. **Profile toggle off:** Preferences → toggle "Open Chrome in a specific profile" off. ⌘C. Expect: old behavior exactly (⌘N, last-active profile).
4. **Placement warm:** Ghostty entry → Left Half. ⌘G on another space. Expect: window appears, snaps to left half (a visible jump is normal — detection is 100–650 ms).
5. **Placement + profile together:** Chrome entry → profile + Right Half. ⌘C. Expect: personal-profile window on the right half of the target space.
6. **Custom capture:** Position a Ghostty window by hand, Preferences → Custom → Capture Current Window. Relaunch quick-launch flow. Expect: new window lands on the captured rect (±a few px; Ghostty's 1 px height delta is known and unexplained — not a failure).
7. **Placement toggle off:** flip "Position new windows" off. Expect: windows untouched.
8. **Both off:** behavior indistinguishable from the pre-feature build.
9. **Chrome a11y tripwire:** open `chrome://accessibility` after several placements. Expect: accessibility engine still off (the dance never wrote `true`).
10. **Persistence/back-compat:** relaunch the app. Expect: quick-launch list, profiles, placements intact; a pre-feature `proto.quickLaunch` blob (if you kept one) still decodes.
11. **Junk-profile guard:** in Local State terms, a stale directory name should refuse to fire the profile path (falls back to ⌘N) — simulate by setting a profile then renaming it in Chrome's profile manager.

Also still pending from before this feature (unchanged, verify opportunistically): the original ⌘N-to-PID path with Chrome running (this plan makes it the *fallback* path, so it still matters for toggle-off), and floating menu visuals.

**Commit** (after fixes the checklist shakes out): `Quick-launch profiles + placement: post-verification fixes`

---

## Execution notes

- Model economy: implementation goes to the `implementer` agent (Opus) with this file as the brief; it's written to be self-contained.
- Constraints honored: no new private APIs (AX + NSWorkspace are public; the single-private-API rule stands); all state in UserDefaults, edited in-app; no config files.
- Known risks for the executor: AXObserver callback signature pedantry (C function pointer — no captures; use the refcon `Unmanaged` pattern exactly as written); `AXValueGetValue` force-casts (`as! AXValue`) are the standard idiom here; SwiftUI element-binding persistence (see Task 7 note).
