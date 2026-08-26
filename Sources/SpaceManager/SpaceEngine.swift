import AppKit
import Combine

struct SpaceInfo: Equatable {
    let managedID: Int
    let uuid: String
    let type: Int
}

struct DisplaySnapshot: Equatable {
    let displayID: String
    let currentSpaceUUID: String?
    let spaces: [SpaceInfo]
}

/// Detection pipeline proven in the 2026-08-11 spike: listen to the public
/// space-change notification, snapshot all displays via SkyLight, diff against
/// the previous snapshot. Measured 1.6–11.6 ms per switch.
final class SpaceEngine: ObservableObject {
    @Published private(set) var displays: [DisplaySnapshot] = []
    @Published private(set) var currentUUID: String?
    @Published private(set) var previousUUID: String?

    /// Fires after state is updated when the main display's space changed.
    var onArrive: ((SpaceInfo, Int) -> Void)?

    private let cid: Int32
    private let copyFn: SkyLight.CopyManagedDisplaySpacesFn
    private var observer: NSObjectProtocol?

    init?() {
        guard SkyLight.available,
              let cidFn = SkyLight.mainConnectionID,
              let copyFn = SkyLight.copyManagedDisplaySpaces else { return nil }
        self.cid = cidFn()
        self.copyFn = copyFn
        guard let snap = takeSnapshot() else { return nil }
        displays = snap
        currentUUID = mainDisplay(in: snap)?.currentSpaceUUID

        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    var mainDisplay: DisplaySnapshot? { mainDisplay(in: displays) }

    /// Prefer the display whose UUID matches CGMainDisplayID; single-display
    /// setups (the only validated case so far) fall back to the sole entry.
    private func mainDisplay(in snapshot: [DisplaySnapshot]) -> DisplaySnapshot? {
        guard snapshot.count > 1 else { return snapshot.first }
        if let cfUUID = CGDisplayCreateUUIDFromDisplayID(CGMainDisplayID())?.takeRetainedValue() {
            let uuid = CFUUIDCreateString(nil, cfUUID) as String
            if let match = snapshot.first(where: { $0.displayID.caseInsensitiveCompare(uuid) == .orderedSame }) {
                return match
            }
        }
        return snapshot.first
    }

    /// Re-snapshot and publish. Called on every space-change notification and
    /// opportunistically before UI opens (catches added/removed spaces, which
    /// have no notification of their own).
    func refresh() {
        guard let snap = takeSnapshot() else { return }
        let oldCurrent = currentUUID
        displays = snap
        guard let display = mainDisplay(in: snap),
              let cur = display.currentSpaceUUID else { return }
        if cur != oldCurrent {
            previousUUID = oldCurrent
            currentUUID = cur
            if let idx = display.spaces.firstIndex(where: { $0.uuid == cur }) {
                onArrive?(display.spaces[idx], idx)
            }
        }
    }

    private func takeSnapshot() -> [DisplaySnapshot]? {
        guard let cfArray = copyFn(cid)?.takeRetainedValue(),
              let rawDisplays = cfArray as? [[String: Any]] else { return nil }
        return rawDisplays.map { display in
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
}
