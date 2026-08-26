import AppKit
import Combine

// MARK: - Menu bar item (current-space indicator + prototype controls)

final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let store: SpaceStore
    private let settings: HUDSettings
    private let replayHUD: () -> Void
    private let toggleSwitcher: () -> Void
    private var cancellables = Set<AnyCancellable>()

    init(store: SpaceStore, settings: HUDSettings,
         replayHUD: @escaping () -> Void, toggleSwitcher: @escaping () -> Void) {
        self.store = store
        self.settings = settings
        self.replayHUD = replayHUD
        self.toggleSwitcher = toggleSwitcher
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        store.$currentIndex
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateTitle() }
            .store(in: &cancellables)
        updateTitle()
    }

    private func updateTitle() {
        let space = store.current
        let name = space.displayName(number: store.currentIndex + 1)
        let title = space.emoji.map { "\($0) \(name)" } ?? name
        statusItem.button?.title = title
    }

    // Rebuild the menu each time it opens so checkmarks and the current
    // space marker are always fresh.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        for (i, space) in store.spaces.enumerated() {
            let name = space.displayName(number: i + 1)
            let label = space.emoji.map { "\($0)  \(name)" } ?? name
            let item = NSMenuItem(title: label, action: #selector(pickSpace(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.state = i == store.currentIndex ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let switcher = NSMenuItem(title: "Open Switcher", action: #selector(openSwitcher), keyEquivalent: "?")
        switcher.keyEquivalentModifierMask = [.control]
        switcher.target = self
        menu.addItem(switcher)

        let replay = NSMenuItem(title: "Replay Arrival HUD", action: #selector(replay), keyEquivalent: "")
        replay.target = self
        menu.addItem(replay)

        menu.addItem(.separator())
        menu.addItem(tuningMenu())
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Prototype", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func tuningMenu() -> NSMenuItem {
        let root = NSMenuItem(title: "HUD Tuning", action: nil, keyEquivalent: "")
        let sub = NSMenu()

        sub.addItem(sectionLabel("Duration"))
        for dur in HUDSettings.durations {
            let item = NSMenuItem(title: String(format: "%.1f s", dur),
                                  action: #selector(setDuration(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = dur
            item.state = abs(settings.duration - dur) < 0.01 ? .on : .off
            sub.addItem(item)
        }

        sub.addItem(.separator())
        sub.addItem(sectionLabel("Position"))
        for pos in HUDPosition.allCases {
            let item = NSMenuItem(title: pos.label, action: #selector(setPosition(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = pos.rawValue
            item.state = settings.position == pos ? .on : .off
            sub.addItem(item)
        }

        sub.addItem(.separator())
        sub.addItem(sectionLabel("Animation"))
        for style in HUDStyle.allCases {
            let item = NSMenuItem(title: style.label, action: #selector(setStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style.rawValue
            item.state = settings.style == style ? .on : .off
            sub.addItem(item)
        }

        sub.addItem(.separator())
        sub.addItem(sectionLabel("Layout"))
        for layout in HUDLayout.allCases {
            let item = NSMenuItem(title: layout.label, action: #selector(setLayout(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = layout.rawValue
            item.state = settings.layout == layout ? .on : .off
            sub.addItem(item)
        }

        sub.addItem(.separator())
        let indicator = NSMenuItem(title: "Position Indicator (N of M / dots)",
                                   action: #selector(toggleIndicator), keyEquivalent: "")
        indicator.target = self
        indicator.state = settings.showIndicator ? .on : .off
        sub.addItem(indicator)

        root.submenu = sub
        return root
    }

    private func sectionLabel(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: Actions — every tuning change replays the HUD as a live preview.

    @objc private func pickSpace(_ sender: NSMenuItem) {
        store.switchTo(sender.tag)
    }

    @objc private func openSwitcher() { toggleSwitcher() }
    @objc private func replay() { replayHUD() }

    @objc private func setDuration(_ sender: NSMenuItem) {
        if let dur = sender.representedObject as? Double { settings.duration = dur }
        replayHUD()
    }

    @objc private func setPosition(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String,
           let pos = HUDPosition(rawValue: raw) { settings.position = pos }
        replayHUD()
    }

    @objc private func setStyle(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String,
           let style = HUDStyle(rawValue: raw) { settings.style = style }
        replayHUD()
    }

    @objc private func setLayout(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String,
           let layout = HUDLayout(rawValue: raw) { settings.layout = layout }
        replayHUD()
    }

    @objc private func toggleIndicator() {
        settings.showIndicator.toggle()
        replayHUD()
    }
}
