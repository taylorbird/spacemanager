// spacemanager spike — space-switch latency + render-through-freeze harness (THROWAWAY)
//
// Answers two questions about trackpad-swipe space switches on macOS 26:
//
//   (A) Detection timing — does the "Current Space" flag inside
//       SLSCopyManagedDisplaySpaces flip BEFORE NSWorkspace.activeSpaceDidChangeNotification
//       fires, and by how much? A 50 Hz poller timestamps the flag flip, the
//       notification observer timestamps the notification, and the two are paired
//       nearest-in-time to produce a signed DELTA.
//
//   (B) Render-through-freeze — does an always-on-top .canJoinAllSpaces/.stationary
//       panel keep drawing live content DURING the space-slide animation, or is it
//       baked into WindowServer's frozen transition snapshot? A borderless panel
//       shows a 60 Hz millisecond counter and flips its background color on every
//       detected space change. Human observation during the slide is the readout:
//       counter ticking / color already changed mid-slide => renders live.
//
// Build:  swiftc -O -o spike/latency spike/latency.swift
// Run:    ./spike/latency            (Ctrl+C to quit; optionally tee to a log file)
//
// Private API surface is deliberately limited to SLSMainConnectionID +
// SLSCopyManagedDisplaySpaces, loaded via dlopen/dlsym exactly as spike/main.swift
// does — no link-time private-framework dependency, no permissions required.

import AppKit

setvbuf(stdout, nil, _IONBF, 0)  // unbuffered: output must land immediately when piped to a file

// MARK: - Monotonic clock

// mach_absolute_time-backed (DispatchTime.uptimeNanoseconds); never Date, which can jump.
let launchUptimeNs = DispatchTime.now().uptimeNanoseconds

@inline(__always) func msSinceLaunch() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds &- launchUptimeNs) / 1_000_000.0
}

// MARK: - Logging (serialized so poller/main-thread lines never interleave)

let logQueue = DispatchQueue(label: "latency.log")

let wallClock: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()

func log(_ message: String) {
    let stamp = wallClock.string(from: Date())
    logQueue.async { print("[\(stamp)] \(message)") }
}

// MARK: - SkyLight private symbols (dlopen/dlsym — same approach as spike/main.swift)

typealias MainConnectionIDFn = @convention(c) () -> Int32
typealias CopyManagedDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?

let skylightPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
guard let skylight = dlopen(skylightPath, RTLD_NOW) else {
    fputs("FATAL: dlopen(\(skylightPath)) failed\n", stderr)
    exit(1)
}
guard let cidSym = dlsym(skylight, "SLSMainConnectionID"),
      let copySym = dlsym(skylight, "SLSCopyManagedDisplaySpaces") else {
    fputs("FATAL: dlsym failed — SLS symbols missing on this macOS build\n", stderr)
    exit(1)
}
let SLSMainConnectionID = unsafeBitCast(cidSym, to: MainConnectionIDFn.self)
let SLSCopyManagedDisplaySpaces = unsafeBitCast(copySym, to: CopyManagedDisplaySpacesFn.self)

let cid = SLSMainConnectionID()

// MARK: - Snapshot model (parsing lifted from spike/main.swift)

struct SpaceInfo {
    let managedID: Int
    let uuid: String
    let type: Int
}

struct DisplaySnapshot {
    let displayID: String
    let currentSpaceUUID: String?
    let spaces: [SpaceInfo]
}

func takeSnapshot() -> [DisplaySnapshot]? {
    guard let cfArray = SLSCopyManagedDisplaySpaces(cid)?.takeRetainedValue(),
          let displays = cfArray as? [[String: Any]] else { return nil }
    return displays.map { display in
        DisplaySnapshot(
            displayID: display["Display Identifier"] as? String ?? "<unknown>",
            currentSpaceUUID: (display["Current Space"] as? [String: Any])?["uuid"] as? String,
            spaces: (display["Spaces"] as? [[String: Any]] ?? []).map { s in
                SpaceInfo(managedID: s["ManagedSpaceID"] as? Int ?? -1,
                          uuid: s["uuid"] as? String ?? "<none>",
                          type: s["type"] as? Int ?? -1)
            }
        )
    }
}

func prefix8(_ uuid: String?) -> String {
    guard let uuid, !uuid.isEmpty else { return "<none>" }
    return String(uuid.prefix(8))
}

// MARK: - Panel (experiment B)

final class LatencyPanel {
    private let panel: NSPanel
    private let counterField: NSTextField
    private let spaceField: NSTextField

    // Bright, obviously-distinct cycle so a mid-slide swap is unmistakable.
    private static let colors: [NSColor] = [
        NSColor(srgbRed: 1.00, green: 0.20, blue: 0.20, alpha: 1),  // red
        NSColor(srgbRed: 0.10, green: 0.90, blue: 0.30, alpha: 1),  // green
        NSColor(srgbRed: 0.20, green: 0.45, blue: 1.00, alpha: 1),  // blue
        NSColor(srgbRed: 1.00, green: 0.60, blue: 0.00, alpha: 1),  // orange
        NSColor(srgbRed: 0.85, green: 0.30, blue: 1.00, alpha: 1),  // violet
        NSColor(srgbRed: 0.00, green: 0.90, blue: 0.90, alpha: 1),  // cyan
    ]
    private var colorIndex = 0

    init() {
        let size = NSSize(width: 460, height: 78)
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = true
        panel.isOpaque = true
        panel.hasShadow = false
        // .screenSaver is above .statusBar — the highest ordinary level, which gives
        // experiment B the best chance of drawing over a transition if anything can.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        content.layer?.backgroundColor = LatencyPanel.colors[0].cgColor
        panel.contentView = content

        counterField = LatencyPanel.makeLabel(
            frame: NSRect(x: 0, y: 26, width: size.width, height: 44),
            font: NSFont.monospacedDigitSystemFont(ofSize: 34, weight: .bold))
        spaceField = LatencyPanel.makeLabel(
            frame: NSRect(x: 0, y: 6, width: size.width, height: 20),
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium))
        content.addSubview(counterField)
        content.addSubview(spaceField)

        // Top-center, tucked just under the menu bar / notch band.
        if let screen = NSScreen.main {
            let menuBarBand = screen.frame.maxY - screen.visibleFrame.maxY
            let x = screen.frame.midX - size.width / 2
            let y = screen.frame.maxY - menuBarBand - size.height - 6
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        panel.orderFrontRegardless()
    }

    private static func makeLabel(frame: NSRect, font: NSFont) -> NSTextField {
        let f = NSTextField(frame: frame)
        f.isEditable = false
        f.isSelectable = false
        f.isBordered = false
        f.drawsBackground = false
        f.alignment = .center
        f.font = font
        f.textColor = .black
        f.stringValue = ""
        return f
    }

    func setCounter(_ ms: Double) {
        counterField.stringValue = String(format: "%.0f ms", ms)
    }

    func setSpaceLabel(_ text: String) {
        spaceField.stringValue = text
    }

    /// Advance to the next bright color. Called on every detected space change.
    func advanceColor() {
        colorIndex = (colorIndex + 1) % LatencyPanel.colors.count
        panel.contentView?.layer?.backgroundColor = LatencyPanel.colors[colorIndex].cgColor
    }
}

// MARK: - Poll/notification pairing (experiment A)

/// Pairs POLL flips with NOTIF fires nearest-in-time within a 2 s window, handling
/// either arriving first. All access is confined to `pairQueue`.
final class Pairer {
    private let pairQueue = DispatchQueue(label: "latency.pair")
    private let windowMs = 2000.0
    private var pendingPolls: [Double] = []
    private var pendingNotifs: [Double] = []

    func recordPoll(at t: Double) {
        pairQueue.async {
            self.pendingNotifs.removeAll { t - $0 > self.windowMs }
            if let match = self.nearest(t, in: &self.pendingNotifs) {
                self.emitDelta(pollMs: t, notifMs: match)
            } else {
                self.pendingPolls.append(t)
            }
        }
    }

    func recordNotif(at t: Double) {
        pairQueue.async {
            self.pendingPolls.removeAll { t - $0 > self.windowMs }
            if let match = self.nearest(t, in: &self.pendingPolls) {
                self.emitDelta(pollMs: match, notifMs: t)
            } else {
                self.pendingNotifs.append(t)
            }
        }
    }

    private func nearest(_ t: Double, in bucket: inout [Double]) -> Double? {
        guard let idx = bucket.indices.min(by: { abs(bucket[$0] - t) < abs(bucket[$1] - t) }),
              abs(bucket[idx] - t) <= windowMs else { return nil }
        return bucket.remove(at: idx)
    }

    private func emitDelta(pollMs: Double, notifMs: Double) {
        let d = notifMs - pollMs
        if d >= 0 {
            log(String(format: "DELTA: poll led notification by %.1f ms  (poll t=%.1f, notif t=%.1f)",
                       d, pollMs, notifMs))
        } else {
            log(String(format: "DELTA: poll TRAILED notification by %.1f ms  (poll t=%.1f, notif t=%.1f)",
                       -d, pollMs, notifMs))
        }
    }
}

let pairer = Pairer()

// MARK: - App + panel bootstrap

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // no dock icon, no menu bar item

guard let initialSnapshot = takeSnapshot() else {
    fputs("FATAL: initial SLSCopyManagedDisplaySpaces snapshot failed\n", stderr)
    exit(1)
}

let panelUI = LatencyPanel()
panelUI.setCounter(0)

func spaceLabel(for snapshot: [DisplaySnapshot]) -> String {
    snapshot.map { d -> String in
        let idx = d.spaces.firstIndex { $0.uuid == d.currentSpaceUUID }.map { "\($0 + 1)" } ?? "?"
        return "\(prefix8(d.displayID)) space \(idx)/\(d.spaces.count) \(prefix8(d.currentSpaceUUID))"
    }.joined(separator: "  |  ")
}

panelUI.setSpaceLabel(spaceLabel(for: initialSnapshot))

// 60 Hz counter. .common mode so it keeps ticking through tracking/modal run loops.
let counterTimer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
    panelUI.setCounter(msSinceLaunch())
}
RunLoop.main.add(counterTimer, forMode: .common)

// MARK: - Poller (experiment A, 50 Hz)

// 20 ms poll interval is a spike-only choice: it is deliberately far more aggressive
// than production would ever be (production polls only on notification, or at ~1 Hz)
// so that the poll-vs-notification lead can be resolved to ~20 ms granularity.
let pollQueue = DispatchQueue(label: "latency.poll", qos: .userInteractive)
var previousByDisplay: [String: String?] = Dictionary(
    uniqueKeysWithValues: initialSnapshot.map { ($0.displayID, $0.currentSpaceUUID) })

let pollTimer = DispatchSource.makeTimerSource(queue: pollQueue)
pollTimer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20), leeway: .milliseconds(1))
pollTimer.setEventHandler {
    guard let now = takeSnapshot() else { return }
    let t = msSinceLaunch()  // timestamp taken immediately after the SLS read
    var flipped = false
    for d in now {
        let old = previousByDisplay[d.displayID] ?? nil
        guard old != d.currentSpaceUUID else { continue }
        previousByDisplay[d.displayID] = d.currentSpaceUUID
        flipped = true
        log(String(format: "POLL flip: %@ -> %@ t=%.1f  (display %@)",
                   prefix8(old), prefix8(d.currentSpaceUUID), t, prefix8(d.displayID)))
    }
    guard flipped else { return }
    pairer.recordPoll(at: t)
    DispatchQueue.main.async {
        panelUI.advanceColor()
        panelUI.setSpaceLabel(spaceLabel(for: now))
    }
}
pollTimer.resume()

// MARK: - Notification observer (experiment A)

NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
) { _ in
    let t = msSinceLaunch()
    log(String(format: "NOTIF fired: t=%.1f", t))
    pairer.recordNotif(at: t)
}

// MARK: - Banner

print("""
=== spacemanager space-switch latency harness ===
SkyLight connection id: \(cid)
Initial state: \(spaceLabel(for: initialSnapshot))

Swipe between spaces with the trackpad several times.
Watch the colored panel during the slide: does the counter keep ticking / color change mid-slide?
  - counter frozen + old color through the whole slide => baked into WindowServer's frozen snapshot
  - counter ticking or color already swapped mid-slide => the panel renders live during the transition

Log lines:
  POLL flip:  SLSCopyManagedDisplaySpaces current-space UUID changed (50 Hz poll)
  NOTIF fired: NSWorkspace.activeSpaceDidChangeNotification
  DELTA:      signed gap between the paired POLL/NOTIF for one transition

Ctrl+C to quit.
""")

app.run()
