import AppKit
import Combine

// MARK: - Menu bar item (current-space indicator + app controls)

final class StatusBarController: NSObject, NSMenuDelegate {
    struct Handlers {
        var toggleSwitcher: () -> Void
        var replayHUD: () -> Void
        var editSpace: (SpaceItem) -> Void
        var editActions: () -> Void
        var openPreferences: () -> Void
        var openSetup: () -> Void
        var runAction: (SpaceAction) -> Void
    }

    private let statusItem: NSStatusItem
    private let viewModel: SpacesViewModel
    private let settings: Settings
    private let actionsStore: ActionsStore
    private let setupStatus: SetupStatus
    private let handlers: Handlers
    private var cancellables = Set<AnyCancellable>()

    init(viewModel: SpacesViewModel, settings: Settings, actionsStore: ActionsStore,
         setupStatus: SetupStatus, handlers: Handlers) {
        self.viewModel = viewModel
        self.settings = settings
        self.actionsStore = actionsStore
        self.setupStatus = setupStatus
        self.handlers = handlers
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        viewModel.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                DispatchQueue.main.async { self?.updateTitle() }
            }
            .store(in: &cancellables)
        updateTitle()
    }

    private func updateTitle() {
        guard let button = statusItem.button else { return }
        let current = viewModel.current
        button.image = spaceIcon(number: current?.number)
        button.imagePosition = .imageLeading
        // NSButton exposes no image/title spacing; a leading space is the gap.
        button.title = " " + (current?.menuLabel ?? "Spaces")
    }

    // MARK: Status item icon

    private static let displaySymbol = NSImage.SymbolConfiguration(pointSize: 15.5, weight: .medium)

    // Composition runs symbol rasterization plus string layout, and updateTitle
    // fires on every view-model change; key 0 is the no-current-space glyph.
    private var iconCache: [Int: NSImage] = [:]

    /// Monitor glyph with the current space's number inside its screen area.
    private func spaceIcon(number: Int?) -> NSImage? {
        let key = number ?? 0
        if let cached = iconCache[key] { return cached }
        guard let symbol = NSImage(systemSymbolName: "display", accessibilityDescription: "Current space")?
            .withSymbolConfiguration(Self.displaySymbol) else { return nil }

        let icon = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            guard let number else { return true }

            let digits = String(number) as NSString
            let points: CGFloat = digits.length > 1 ? 7.5 : 9
            let base = NSFont.systemFont(ofSize: points, weight: .bold)
            let font = base.fontDescriptor.withDesign(.rounded)
                .flatMap { NSFont(descriptor: $0, size: points) } ?? base
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
            let measured = digits.size(withAttributes: attrs)

            // The symbol's screen sits above its stand: at 15.5pt the interior
            // measures 16x10.7 in a 23x19 glyph, centered at 0.58 of the height.
            // Center on cap height, not the line box — digits have no descender.
            let center = rect.minY + rect.height * 0.58
            digits.draw(at: NSPoint(x: rect.midX - measured.width / 2,
                                    y: center - font.capHeight / 2 + font.descender),
                        withAttributes: attrs)
            return true
        }
        // Template rendering is what recolors the digits along with the glyph for
        // dark mode and the open-menu highlight; the symbol's screen interior is
        // empty, so black digits drawn there join the template shape.
        icon.isTemplate = true
        iconCache[key] = icon
        return icon
    }

    // Rebuild the menu each time it opens: fresh space list, checkmarks,
    // setup state, and current-space actions.
    func menuNeedsUpdate(_ menu: NSMenu) {
        viewModel.engine.refresh()
        setupStatus.recheck()
        menu.removeAllItems()

        for item in viewModel.items {
            let mi = NSMenuItem(title: "\(item.number)  \(item.menuLabel)",
                                action: #selector(pickSpace(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = item.index
            mi.state = item.index == viewModel.currentIndex ? .on : .off
            menu.addItem(mi)
        }

        menu.addItem(.separator())

        let switcher = NSMenuItem(title: "Open Switcher", action: #selector(openSwitcher), keyEquivalent: "?")
        switcher.keyEquivalentModifierMask = [.control]
        switcher.target = self
        menu.addItem(switcher)

        let rename = NSMenuItem(title: "Edit Current Space…", action: #selector(renameCurrent), keyEquivalent: "")
        rename.target = self
        menu.addItem(rename)

        // Manual actions for the current space.
        if let current = viewModel.current {
            let actions = actionsStore.actions(for: current.uuid)
            if !actions.isEmpty {
                let sub = NSMenu()
                for action in actions {
                    let mi = NSMenuItem(title: action.displayTitle,
                                        action: #selector(runAction(_:)), keyEquivalent: "")
                    mi.target = self
                    mi.representedObject = action
                    sub.addItem(mi)
                }
                let root = NSMenuItem(title: "Run Action", action: nil, keyEquivalent: "")
                root.submenu = sub
                menu.addItem(root)
            }
        }

        let editActions = NSMenuItem(title: "Edit Actions…", action: #selector(editActions(_:)), keyEquivalent: "")
        editActions.target = self
        menu.addItem(editActions)

        let prefs = NSMenuItem(title: "Preferences…", action: #selector(openPreferences(_:)),
                               keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)

        menu.addItem(.separator())

        let replay = NSMenuItem(title: "Replay Arrival HUD", action: #selector(replay), keyEquivalent: "")
        replay.target = self
        menu.addItem(replay)
        menu.addItem(tuningMenu())

        menu.addItem(.separator())

        if !setupStatus.isReady(spaceCount: viewModel.items.count) {
            let setup = NSMenuItem(title: "⚠️ Finish Setup…", action: #selector(openSetup), keyEquivalent: "")
            setup.target = self
            menu.addItem(setup)
        } else {
            let setup = NSMenuItem(title: "Setup…", action: #selector(openSetup), keyEquivalent: "")
            setup.target = self
            menu.addItem(setup)
        }

        menu.addItem(sectionLabel(Self.versionLabel))
        menu.addItem(NSMenuItem(title: "Quit Space Manager",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func tuningMenu() -> NSMenuItem {
        let root = NSMenuItem(title: "HUD Tuning", action: nil, keyEquivalent: "")
        let sub = NSMenu()

        sub.addItem(sectionLabel("Duration"))
        for dur in Settings.durations {
            let item = NSMenuItem(title: String(format: "%.1f s", dur),
                                  action: #selector(setDuration(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = dur
            item.state = abs(settings.hudDuration - dur) < 0.01 ? .on : .off
            sub.addItem(item)
        }

        sub.addItem(.separator())
        sub.addItem(sectionLabel("Position"))
        for pos in HUDPosition.allCases {
            let item = NSMenuItem(title: pos.label, action: #selector(setPosition(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = pos.rawValue
            item.state = settings.hudPosition == pos ? .on : .off
            sub.addItem(item)
        }

        sub.addItem(.separator())
        sub.addItem(sectionLabel("Animation"))
        for style in HUDStyle.allCases {
            let item = NSMenuItem(title: style.label, action: #selector(setStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style.rawValue
            item.state = settings.hudStyle == style ? .on : .off
            sub.addItem(item)
        }

        sub.addItem(.separator())
        sub.addItem(sectionLabel("Layout"))
        for layout in HUDLayout.allCases {
            let item = NSMenuItem(title: layout.label, action: #selector(setLayout(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = layout.rawValue
            item.state = settings.hudLayout == layout ? .on : .off
            sub.addItem(item)
        }

        sub.addItem(.separator())
        let indicator = NSMenuItem(title: "Position Indicator (N of M / dots)",
                                   action: #selector(toggleIndicator), keyEquivalent: "")
        indicator.target = self
        indicator.state = settings.hudIndicator ? .on : .off
        sub.addItem(indicator)

        root.submenu = sub
        return root
    }

    /// "Version 0.1.0 (42) · abc1234 · 2026-10-13 09:50", stamped by scripts/build-app.sh.
    private static let versionLabel: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        var parts = ["Version \(short) (\(build))"]
        if let commit = info["SMGitCommit"] as? String { parts.append(commit) }
        if let date = info["SMBuildDate"] as? String { parts.append(date) }
        return parts.joined(separator: " · ")
    }()

    private func sectionLabel(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: Actions — HUD tuning changes replay the HUD as a live preview.

    @objc private func pickSpace(_ sender: NSMenuItem) {
        viewModel.requestSwitch?(sender.tag)
    }

    @objc private func openSwitcher() { handlers.toggleSwitcher() }
    @objc private func replay() { handlers.replayHUD() }
    @objc private func openSetup() { handlers.openSetup() }
    @objc private func editActions(_ sender: NSMenuItem) { handlers.editActions() }
    @objc private func openPreferences(_ sender: NSMenuItem) { handlers.openPreferences() }

    @objc private func renameCurrent() {
        if let current = viewModel.current { handlers.editSpace(current) }
    }

    @objc private func runAction(_ sender: NSMenuItem) {
        if let action = sender.representedObject as? SpaceAction { handlers.runAction(action) }
    }

    @objc private func setDuration(_ sender: NSMenuItem) {
        if let dur = sender.representedObject as? Double { settings.hudDuration = dur }
        handlers.replayHUD()
    }

    @objc private func setPosition(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String,
           let pos = HUDPosition(rawValue: raw) { settings.hudPosition = pos }
        handlers.replayHUD()
    }

    @objc private func setStyle(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String,
           let style = HUDStyle(rawValue: raw) { settings.hudStyle = style }
        handlers.replayHUD()
    }

    @objc private func setLayout(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String,
           let layout = HUDLayout(rawValue: raw) { settings.hudLayout = layout }
        handlers.replayHUD()
    }

    @objc private func toggleIndicator() {
        settings.hudIndicator.toggle()
        handlers.replayHUD()
    }
}
