import AppKit
import Carbon.HIToolbox

// spacemanager UX prototype — fake data only, no private APIs, no permissions.
// Build: swiftc -O prototype/*.swift -o prototype/proto

private var hotKeyRefs: [EventHotKeyRef?] = []
private var hotKeyAction: (() -> Void)?

// Ctrl+? — registered as both Ctrl+/ and Ctrl+Shift+/ so the shift for "?"
// doesn't matter. (Was Ctrl+0; trying this by feel per prototype tuning.)
private func registerSwitcherHotKey(_ action: @escaping () -> Void) {
    hotKeyAction = action
    var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                  eventKind: OSType(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
        DispatchQueue.main.async { hotKeyAction?() }
        return noErr
    }, 1, &eventType, nil, nil)
    for (id, modifiers) in [(1, controlKey), (2, controlKey | shiftKey)] {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: 0x53504D47, id: UInt32(id)) // 'SPMG'
        RegisterEventHotKey(UInt32(kVK_ANSI_Slash), UInt32(modifiers), hotKeyID,
                            GetApplicationEventTarget(), 0, &ref)
        hotKeyRefs.append(ref)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = SpaceStore(spaces: FakeData.spaces)
    let settings = HUDSettings()
    var hud: HUDController!
    var switcher: SwitcherController!
    var statusBar: StatusBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        hud = HUDController(settings: settings)
        switcher = SwitcherController(store: store)
        statusBar = StatusBarController(
            store: store,
            settings: settings,
            replayHUD: { [weak self] in self?.showHUDForCurrent() },
            toggleSwitcher: { [weak self] in self?.switcher.toggle() }
        )

        store.onSwitch = { [weak self] space, index in
            guard let self else { return }
            self.hud.show(space: space, number: index + 1, total: self.store.spaces.count)
        }

        registerSwitcherHotKey { [weak self] in self?.switcher.toggle() }

        // Greet with the HUD once so the app visibly announces itself on launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.showHUDForCurrent()
        }
    }

    private func showHUDForCurrent() {
        hud.show(space: store.current,
                 number: store.currentIndex + 1,
                 total: store.spaces.count)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
