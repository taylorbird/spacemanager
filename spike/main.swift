// spacemanager spike — prove SLSCopyManagedDisplaySpaces + activeSpaceDidChangeNotification
// on macOS 26.6, and characterize snapshot/diff latency.
//
// Modes:
//   ./spike --dump    one-shot: print raw + parsed space structure, exit
//   ./spike           watch: log every space change with snapshot+diff latency (Ctrl+C to quit)

import AppKit

setvbuf(stdout, nil, _IONBF, 0)  // unbuffered: output must land immediately when piped to a file

// MARK: - SkyLight private symbols (dlopen/dlsym: no link-time private-framework dependency)

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

// MARK: - Snapshot model

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

func printParsed(_ snapshot: [DisplaySnapshot]) {
    for d in snapshot {
        print("display \(d.displayID)  (\(d.spaces.count) spaces)")
        for (i, s) in d.spaces.enumerated() {
            let marker = s.uuid == d.currentSpaceUUID ? "  ◀ current" : ""
            print(String(format: "  %d. managedID=%-6d type=%d  %@%@", i + 1, s.managedID, s.type, s.uuid, marker))
        }
    }
}

let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()

// MARK: - Modes

print("SkyLight connection id: \(cid)")

if CommandLine.arguments.contains("--dump") {
    guard let cfArray = SLSCopyManagedDisplaySpaces(cid)?.takeRetainedValue() else {
        fputs("FATAL: SLSCopyManagedDisplaySpaces returned NULL\n", stderr)
        exit(1)
    }
    print("=== raw ===")
    print(cfArray as NSArray)
    print("=== parsed ===")
    if let snapshot = takeSnapshot() { printParsed(snapshot) }
    exit(0)
}

// Watch mode
guard var previous = takeSnapshot() else {
    fputs("FATAL: initial snapshot failed\n", stderr)
    exit(1)
}
print("initial state:")
printParsed(previous)
print("\nwatching for space changes — switch spaces now (Ctrl+C to quit)…")

NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
) { _ in
    let t0 = CFAbsoluteTimeGetCurrent()
    guard let now = takeSnapshot() else {
        print("[\(timeFormatter.string(from: Date()))] notification fired but snapshot FAILED")
        return
    }
    let elapsedMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
    var changes = 0
    for d in now {
        let prevD = previous.first { $0.displayID == d.displayID }
        guard prevD?.currentSpaceUUID != d.currentSpaceUUID else { continue }
        changes += 1
        let fromIdx = prevD?.spaces.firstIndex { $0.uuid == prevD?.currentSpaceUUID }.map { "\($0 + 1)" } ?? "?"
        let toIdx = d.spaces.firstIndex { $0.uuid == d.currentSpaceUUID }.map { "\($0 + 1)" } ?? "?"
        print(String(format: "[%@] display %@: space %@ → %@  (uuid %@, snapshot+diff %.2f ms)",
                     timeFormatter.string(from: Date()), d.displayID, fromIdx, toIdx,
                     d.currentSpaceUUID ?? "<none>", elapsedMs))
    }
    if changes == 0 {
        print(String(format: "[%@] notification fired, no current-space change detected (%.2f ms)",
                     timeFormatter.string(from: Date()), elapsedMs))
    }
    previous = now
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
app.run()
