import AppKit
import SwiftUI

// MARK: - Switcher (Ctrl+Option+Cmd+? panel, horizontal tiles + inline space editing)

/// Tile row geometry. Shared so the context menu can sit exactly under the
/// tile it belongs to — the layout is fixed-size, so this stays exact.
/// Only the preview (and what's drawn over it) scales: `fitting` shrinks it
/// when the full row would run past the screen, e.g. 8–9 spaces on a laptop.
/// Text, padding and gaps keep their size; the scale never exceeds 1.
struct TileMetrics: Equatable {
    var scale: CGFloat = 1

    static let full = TileMetrics()
    static let designThumb = CGSize(width: 184, height: 113)
    static let hPadding: CGFloat = 10
    /// Divider (1pt) plus its 8.5pt padding either side.
    static let gap: CGFloat = 18
    static let rowInset: CGFloat = 16
    /// Fixed so the menu-card offset can account for it — the footer sits
    /// between the tiles row and the panel's bottom edge. Tall enough that
    /// hints float clear of the panel edge instead of hugging it.
    static let footerHeight: CGFloat = 28
    /// Per side: the panel's 30pt shadow padding inside the stage, plus
    /// clearance so the panel never meets the screen edge.
    static let stageMargin: CGFloat = 30 + 24
    /// Below this the numerals and previews stop reading; past it the row
    /// is allowed to overflow rather than shrink further.
    static let minScale: CGFloat = 0.5

    var thumb: CGSize {
        // Down, so a fitted row never rounds past the width it was fitted to.
        CGSize(width: (Self.designThumb.width * scale).rounded(.down),
               height: (Self.designThumb.height * scale).rounded(.down))
    }
    var width: CGFloat { thumb.width + Self.hPadding * 2 }
    /// Divider height: preview plus the name line under it (138pt at full size).
    var dividerHeight: CGFloat { thumb.height + 25 }
    /// 107pt ≈ 77pt cap height: ~68% of the preview height.
    var numeralSize: CGFloat { (107 * scale).rounded() }

    func leadingOffset(pos: Int) -> CGFloat {
        Self.rowInset + CGFloat(pos) * (width + Self.gap)
    }

    func rowWidth(tiles: Int) -> CGFloat {
        CGFloat(tiles) * width
            + CGFloat(max(0, tiles - 1)) * Self.gap
            + Self.rowInset * 2
    }

    /// The largest scale (capped at 1) at which `tiles` tiles fit a stage
    /// `stageWidth` wide.
    static func fitting(tiles: Int, stageWidth: CGFloat) -> TileMetrics {
        guard tiles > 0, stageWidth > 0 else { return .full }
        let n = CGFloat(tiles)
        let fixed = n * hPadding * 2 + (n - 1) * gap + rowInset * 2
        let available = stageWidth - stageMargin * 2 - fixed
        let scale = available / (n * designThumb.width)
        return TileMetrics(scale: min(1, max(minScale, scale)))
    }
}

/// Floating tile-menu card. Every dimension is fixed so the card's own height
/// is known before layout — that's what lets it be offset clear of the panel
/// without measuring anything, and it never resizes with its content.
enum MenuMetrics {
    static let width: CGFloat = 220
    static let rowHeight: CGFloat = 40
    static let inset: CGFloat = 7
    /// Breathing room between the panel's bottom edge and the card's top.
    static let gap: CGFloat = 12

    static let labelHeight: CGFloat = 18
    static let dividerPad: CGFloat = 5
    /// App cells are taller than text rows: centered icon with the name under it.
    static let appCellHeight: CGFloat = 72

    /// Chrome profile submenu: a second card cascading beside this one.
    static let submenuWidth: CGFloat = 300
    /// Horizontal space between the menu card and the submenu card.
    static let submenuGap: CGFloat = 8
    /// Profile rows carry a name and an email line, so they're taller than
    /// the card's text rows.
    static let profileRowHeight: CGFloat = 44
    /// Minimum clearance between the submenu and the screen's right edge
    /// before it flips to the menu card's left.
    static let screenMargin: CGFloat = 16

    /// Rename row, then any extra text rows (the move-window row), then (when
    /// apps exist) divider + label + one cell per app. Still fully computable
    /// before layout — see the type comment.
    static func cardHeight(apps: Int, extraRows: Int = 0) -> CGFloat {
        let appsBlock: CGFloat = apps > 0
            ? 1 + dividerPad * 2 + labelHeight + CGFloat(apps) * appCellHeight : 0
        return rowHeight + CGFloat(extraRows) * rowHeight + appsBlock + inset * 2
    }

    /// The Chrome profile submenu card: label, then one row per profile.
    /// Same fixed-before-layout contract as the menu card.
    static func submenuHeight(profiles: Int) -> CGFloat {
        inset * 2 + labelHeight + CGFloat(profiles) * profileRowHeight
    }

    /// Y of the top of the app cell at `pos`, measured from the menu card's
    /// top edge — mirrors `cardHeight`'s stacking (Rename, extra rows,
    /// divider block, label, cells). The submenu's top aligns with it.
    static func appCellTop(pos: Int, extraRows: Int) -> CGFloat {
        inset + rowHeight + CGFloat(extraRows) * rowHeight
            + 1 + dividerPad * 2 + labelHeight + CGFloat(pos) * appCellHeight
    }

    /// Tiles row width including its inset — shared by the card and submenu
    /// x math.
    static func rowWidth(tiles: Int, tile: TileMetrics = .full) -> CGFloat {
        tile.rowWidth(tiles: tiles)
    }

    /// Card centered under the highlighted tile, clamped to the row's edges
    /// so an end tile's card tucks inward (popover-style) instead of
    /// overhanging the panel. A card wider than the whole row centers on it.
    static func xOffset(pos: Int, tiles: Int, tile: TileMetrics = .full) -> CGFloat {
        let rowWidth = rowWidth(tiles: tiles, tile: tile)
        guard width <= rowWidth else { return (rowWidth - width) / 2 }
        let centered = tile.leadingOffset(pos: pos) + (tile.width - width) / 2
        return min(max(centered, 0), rowWidth - width)
    }

    /// Submenu card x, relative to the tiles row's leading edge (the same
    /// anchor `xOffset` uses): right of the menu card, or left of it when
    /// the right placement would come within `screenMargin` of the screen
    /// edge. The row is centered in a stage `stageWidth` wide.
    static func submenuXOffset(pos: Int, tiles: Int, stageWidth: CGFloat,
                               tile: TileMetrics = .full) -> CGFloat {
        let menuX = xOffset(pos: pos, tiles: tiles, tile: tile)
        let right = menuX + width + submenuGap
        let rowLeading = (stageWidth - rowWidth(tiles: tiles, tile: tile)) / 2
        guard rowLeading + right + submenuWidth > stageWidth - screenMargin else { return right }
        return menuX - submenuGap - submenuWidth
    }
}

/// One row of the per-tile context menu (Down on a highlighted tile).
enum TileMenuItem: Identifiable {
    case rename
    /// Move the window that was focused when the switcher opened onto this tile.
    case moveWindow(MovableWindow)
    case launch(QuickLaunchApp)

    var id: String {
        switch self {
        case .rename: return "rename"
        case .moveWindow: return "move"
        case .launch(let app): return app.id.uuidString
        }
    }

    var launchApp: QuickLaunchApp? {
        if case .launch(let app) = self { return app }
        return nil
    }

    var movableWindow: MovableWindow? {
        if case .moveWindow(let window) = self { return window }
        return nil
    }
}

final class SwitcherModel: ObservableObject {
    @Published var filter = ""
    @Published var highlight = 0

    // Inline edit mode: tiles stay visible, an edit bar appears below them.
    @Published var editing: SpaceItem?
    @Published var editName = ""
    @Published var editEmoji = ""
    @Published var editAccent: String?

    // Tile context menu: nil = closed. Opened by Down, anchored under the
    // highlighted tile (decision 2026-08-25: Down used to rename directly).
    @Published var menuFor: SpaceItem?
    @Published var menuSelection = 0

    // Chrome profile submenu (Right on a Chrome cell): nil = closed. Drawn as
    // a drill-in inside the same card, so the parent menu stays open under it.
    @Published var submenuProfiles: [ChromeProfiles.Profile]?
    @Published var submenuSelection = 0
    /// The Chrome entry the submenu was opened from. Kept here rather than
    /// re-read through `menuSelection`: the move row can appear late (async
    /// window capture) and shift the menu's indices under an open submenu.
    private(set) var submenuApp: QuickLaunchApp?
    /// Read once per menu open; empty when profile targeting is off or Chrome
    /// has no readable Local State.
    private(set) var cachedProfiles: [ChromeProfiles.Profile] = []

    /// The window that was focused when the switcher opened — nil when the
    /// feature is off, or when there was nothing worth moving. Captured once
    /// per open, because "frontmost" stops meaning anything useful the moment
    /// the panel is up.
    @Published var movable: MovableWindow?

    /// Tile size for this open, fitted to the screen and the total space
    /// count — not the filtered count, so tiles don't resize while typing.
    @Published var tile = TileMetrics.full

    let viewModel: SpacesViewModel
    let metadata: MetadataStore
    let settings: Settings

    init(viewModel: SpacesViewModel, metadata: MetadataStore, settings: Settings) {
        self.viewModel = viewModel
        self.metadata = metadata
        self.settings = settings
    }

    /// Quick-launch entries whose app is actually installed.
    var quickLaunchApps: [QuickLaunchApp] {
        settings.quickLaunch.filter { $0.url != nil }
    }

    func quickLaunchApp(matching c: Character) -> QuickLaunchApp? {
        let key = String(c).lowercased()
        return quickLaunchApps.first { $0.keyEquivalent == key }
    }

    var menuOpen: Bool { menuFor != nil }
    var submenuOpen: Bool { submenuProfiles != nil }

    static let chromeBundleID = "com.google.Chrome"

    /// Right drills into a profile list only on a Chrome cell, with profile
    /// targeting on and at least one profile found. Anything else keeps
    /// Right's pre-submenu behavior.
    func profileSubmenuAvailable(for item: TileMenuItem) -> Bool {
        guard let app = item.launchApp else { return false }
        return app.bundleID == Self.chromeBundleID
            && settings.chromeProfilesEnabled
            && !cachedProfiles.isEmpty
    }

    /// The captured window, if moving it onto `item` makes sense: there has to
    /// be a capture, the tile can't be the space we're already on, and neither
    /// end can be full-screen — a full-screen space has no room to drop a
    /// window into, and you can't drag a window out of one.
    func movableWindow(for item: SpaceItem) -> MovableWindow? {
        guard let window = movable,
              item.index != viewModel.currentIndex,
              !item.isFullScreen,
              viewModel.current?.isFullScreen == false else { return nil }
        return window
    }

    /// The move row for the tile the menu is open on, if any.
    var moveRow: TileMenuItem? {
        guard let target = menuFor, let window = movableWindow(for: target) else { return nil }
        return .moveWindow(window)
    }

    var menuItems: [TileMenuItem] {
        [.rename] + (moveRow.map { [$0] } ?? []) + quickLaunchApps.map { .launch($0) }
    }

    func openMenu(_ item: SpaceItem) {
        menuFor = item
        menuSelection = 0 // Rename is the default, as Down always was
        cachedProfiles = settings.chromeProfilesEnabled ? settings.chromeProfiles.filter(\.enabled) : []
        Log.switcher.notice("menu opened: \(self.menuItems.count, privacy: .public) items, profilesEnabled=\(self.settings.chromeProfilesEnabled, privacy: .public), profiles=\(self.cachedProfiles.count, privacy: .public)")
    }

    func closeMenu() {
        closeSubmenu()
        menuFor = nil
        menuSelection = 0
        cachedProfiles = []
    }

    /// Starts on the entry's configured default profile, so Right-then-Enter
    /// does what plain Enter would have.
    func openSubmenu() {
        let items = menuItems
        guard items.indices.contains(menuSelection),
              profileSubmenuAvailable(for: items[menuSelection]),
              let app = items[menuSelection].launchApp else { return }
        submenuApp = app
        submenuProfiles = cachedProfiles
        submenuSelection = cachedProfiles.firstIndex { $0.directory == app.chromeProfile } ?? 0
    }

    /// Back to the parent menu, Chrome cell still selected.
    func closeSubmenu() {
        submenuProfiles = nil
        submenuApp = nil
        submenuSelection = 0
    }

    func moveSubmenuSelection(_ delta: Int) {
        let count = submenuProfiles?.count ?? 0
        guard count > 0 else { return }
        submenuSelection = (submenuSelection + delta + count) % count
    }

    /// Wraps: a short vertical list reads like a menu, not like the tiles.
    func moveMenuSelection(_ delta: Int) {
        let count = menuItems.count
        guard count > 0 else { return }
        menuSelection = (menuSelection + delta + count) % count
    }

    /// Items matching the filter. Prefix matches rank first.
    var filtered: [SpaceItem] {
        let all = viewModel.items
        let f = filter.lowercased()
        guard !f.isEmpty else { return all }
        let matches = all.filter { $0.name.lowercased().contains(f) }
        let prefix = matches.filter { $0.name.lowercased().hasPrefix(f) }
        let rest = matches.filter { !$0.name.lowercased().hasPrefix(f) }
        return prefix + rest
    }

    // The menu belongs to one tile, so anything that can change which tile is
    // highlighted dismisses it.
    func append(_ c: Character) {
        closeMenu()
        filter.append(c)
        highlight = 0
    }

    func backspace() {
        guard !filter.isEmpty else { return }
        closeMenu()
        filter.removeLast()
        highlight = 0
    }

    func moveHighlight(_ delta: Int) {
        closeMenu()
        let count = filtered.count
        guard count > 0 else { return }
        highlight = min(max(highlight + delta, 0), count - 1)
    }

    func reset() {
        filter = ""
        editing = nil
        closeMenu()
        // Initial highlight = current space (decision 2026-08-21: the original
        // previous-space back-toggle read as a wrong selection in practice).
        highlight = viewModel.currentIndex
    }

    func beginEdit(_ item: SpaceItem) {
        let meta = metadata.meta(for: item.uuid)
        editName = meta.name ?? ""
        editEmoji = meta.emoji ?? ""
        editAccent = meta.accent
        editing = item
    }

    func saveEdit() {
        guard let item = editing else { return }
        let name = editName.trimmingCharacters(in: .whitespaces)
        let emoji = editEmoji.trimmingCharacters(in: .whitespaces)
        metadata.update(SpaceMeta(name: name.isEmpty ? nil : name,
                                  emoji: emoji.isEmpty ? nil : emoji,
                                  accent: editAccent),
                        for: item.uuid)
        editing = nil
    }

    func cancelEdit() {
        editing = nil
    }
}

final class KeyPanel: NSPanel {
    var keyHandler: ((NSEvent) -> Bool)?
    var onResign: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyHandler?(event) == true { return }
        super.sendEvent(event)
    }

    override func resignKey() {
        super.resignKey()
        onResign?()
    }
}

final class SwitcherController {
    private let panel: KeyPanel
    private let model: SwitcherModel
    private let viewModel: SpacesViewModel
    private let launcher: QuickLauncher
    private let settings: Settings
    private let mover: WindowMover
    /// ⌘, from inside the switcher; wired by the app delegate.
    var onPreferences: (() -> Void)?

    /// Initial size only — `open()` sizes the stage to the screen.
    private let stageSize = NSSize(width: 1200, height: 540)
    /// The panel's top edge sits this fraction of the screen below the top.
    private static let topInset: CGFloat = 0.18

    /// Open/closed as far as this controller is concerned. Not
    /// `panel.isVisible`: WindowServer can re-order a closed panel back on
    /// screen (a click that landed on it while it was leaving comes back on
    /// mouse-up), and a toggle keyed off visibility would then close a panel
    /// the user can't type into instead of opening a usable one.
    private(set) var isOpen = false
    /// Bumped per open, so a capture that finishes after the switcher was
    /// closed (or reopened) is dropped instead of landing on the wrong session.
    private var session = 0
    private var occlusionObserver: NSObjectProtocol?

    init(viewModel: SpacesViewModel, previews: PreviewStore, metadata: MetadataStore,
         settings: Settings, launcher: QuickLauncher, mover: WindowMover) {
        self.viewModel = viewModel
        self.launcher = launcher
        self.settings = settings
        self.mover = mover
        model = SwitcherModel(viewModel: viewModel, metadata: metadata, settings: settings)
        panel = KeyPanel(contentRect: NSRect(origin: .zero, size: stageSize),
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let view = SwitcherView(
            model: model,
            spaces: viewModel,
            previews: previews,
            onPick: { [weak self] index in self?.select(absolute: index) },
            onMenuPick: { [weak self] item in self?.activate(item) },
            onProfilePick: { [weak self] app, profile in self?.launch(app, profile: profile) },
            onMoveWindow: { [weak self] window, item in self?.moveWindow(window, to: item) }
        )
        panel.contentView = NSHostingView(rootView: view)
        panel.keyHandler = { [weak self] event in self?.handle(event) ?? false }
        panel.onResign = { [weak self] in self?.close() }
        panel.ignoresMouseEvents = true // closed until open() says otherwise

        // Backstop for the stuck-switcher bug: if WindowServer puts the panel
        // back on screen while we consider it closed, it has no key focus and
        // can't be dismissed with Esc — take it straight back off.
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: panel, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let visible = self.panel.occlusionState.contains(.visible)
            Log.switcher.notice("panel occlusion visible=\(visible, privacy: .public) isOpen=\(self.isOpen, privacy: .public) key=\(self.panel.isKeyWindow, privacy: .public)")
            guard !self.isOpen, visible else { return }
            Log.switcher.error("switcher panel reappeared while closed; ordering it out")
            self.panel.orderOut(nil)
        }
    }

    deinit {
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
    }

    func toggle() {
        isOpen ? close() : open()
    }

    func open() {
        viewModel.engine.refresh() // catch added/removed spaces before showing
        model.reset()
        session += 1
        let thisSession = session
        // The frontmost app is read now, before the panel shows (it's a
        // nonactivating panel so that shouldn't matter — but the capture must
        // not depend on it). The AX queries finish off the main thread and
        // land a moment later; ⇧⏎ in that gap simply has nothing to move.
        // Feature off = no capture at all.
        model.movable = nil
        if settings.moveWindowEnabled {
            MovableWindow.captureFocusedWindow { [weak self] window in
                guard let self, self.isOpen, self.session == thisSession else { return }
                self.model.movable = window
            }
        }
        if let screen = NSScreen.main {
            // Full-width transparent stage from the top inset to the bottom
            // of the screen, so the tile menu card below the panel always has
            // room — the card is drawn inside this window and would be
            // clipped by a shorter one. Transparent areas pass clicks through.
            let f = screen.visibleFrame
            model.tile = .fitting(tiles: viewModel.items.count, stageWidth: f.width)
            let top = f.maxY - f.height * Self.topInset
            panel.setFrame(NSRect(x: f.minX, y: f.minY,
                                  width: f.width, height: top - f.minY),
                           display: true)
        }
        isOpen = true
        panel.ignoresMouseEvents = false
        panel.makeKeyAndOrderFront(nil)
        Log.switcher.notice("opened, panel frame \(self.panel.frame.logDescription, privacy: .public) (Cocoa coordinates), tile scale \(self.model.tile.scale, privacy: .public)")
    }

    func close() {
        guard isOpen || panel.isVisible else { return }
        isOpen = false
        session += 1
        model.cancelEdit()
        model.closeMenu()
        model.movable = nil
        // Click-through before it leaves: a synthesized mouse-down that
        // arrives while WindowServer still shows the panel must pass through
        // to the window underneath instead of landing on us.
        panel.ignoresMouseEvents = true
        panel.orderOut(nil)
        Log.switcher.notice("closed")
    }

    private func select(absolute index: Int) {
        close()
        viewModel.requestSwitch?(index)
    }

    private func selectHighlighted() {
        let rows = model.filtered
        guard rows.indices.contains(model.highlight) else { return }
        select(absolute: rows[model.highlight].index)
    }

    /// Quick-launch onto a space (the current one included).
    private func quickLaunch(_ app: QuickLaunchApp, onSpaceIndex index: Int) {
        close()
        launcher.launch(app, onSpaceIndex: index)
    }

    /// The ⌘-key and footer-button path: acts on whatever tile is highlighted.
    private func quickLaunchHighlighted(_ app: QuickLaunchApp) {
        let rows = model.filtered
        guard rows.indices.contains(model.highlight) else { return }
        quickLaunch(app, onSpaceIndex: rows[model.highlight].index)
    }

    private func openMenuHighlighted() {
        let rows = model.filtered
        guard rows.indices.contains(model.highlight) else { return }
        model.openMenu(rows[model.highlight])
    }

    /// Acts on the space the menu was opened for, not the current highlight.
    private func activate(_ item: TileMenuItem) {
        guard let target = model.menuFor else { return }
        model.closeMenu()
        switch item {
        case .rename:
            model.beginEdit(target)
        case .moveWindow(let window):
            moveWindow(window, to: target)
        case .launch(let app):
            quickLaunch(app, onSpaceIndex: target.index)
        }
    }

    /// Closing first is load-bearing: the mover's synthesized mouse-down must
    /// land on the window's title bar, not on our own panel — so the mover
    /// also waits for the panel to be verifiably off screen before clicking.
    private func moveWindow(_ window: MovableWindow, to item: SpaceItem) {
        close()
        mover.move(window, toSpaceUUID: item.uuid, index: item.index,
                   obstructions: [CGWindowID(panel.windowNumber)])
    }

    /// ⇧⏎: move the captured window onto the highlighted tile. False when
    /// there's nothing to move there — no capture, the current space, or a
    /// full-screen end (see `SwitcherModel.movableWindow(for:)`).
    private func moveHighlighted() -> Bool {
        let rows = model.filtered
        guard rows.indices.contains(model.highlight) else { return false }
        let item = rows[model.highlight]
        guard let window = model.movableWindow(for: item) else { return false }
        moveWindow(window, to: item)
        return true
    }

    private func activateSelectedMenuItem() {
        let items = model.menuItems
        guard items.indices.contains(model.menuSelection) else { return }
        activate(items[model.menuSelection])
    }

    private func activateSelectedProfile() {
        guard let app = model.submenuApp,
              let profiles = model.submenuProfiles,
              profiles.indices.contains(model.submenuSelection) else { return }
        launch(app, profile: profiles[model.submenuSelection])
    }

    /// One-off profile override onto the space the menu was opened for. The
    /// launcher's own exists() guard still covers a stale directory.
    private func launch(_ app: QuickLaunchApp, profile: ChromeProfiles.Profile) {
        guard let target = model.menuFor else { return }
        model.closeMenu()
        var pick = app
        pick.chromeProfile = profile.directory
        Log.switcher.notice("profile pick \(profile.directory, privacy: .public) for \(app.label, privacy: .public) onto space \(target.index + 1, privacy: .public)")
        quickLaunch(pick, onSpaceIndex: target.index)
    }

    /// Returns true when the event was consumed. The map, in priority order:
    /// edit mode owns everything but Esc; ⇧⏎ moves the captured window to the
    /// highlighted tile; the Chrome profile submenu owns Up/Down/Enter/Esc/←
    /// while open; the tile menu owns Up/Down/Enter/Esc (and → on a Chrome
    /// cell, which opens the submenu) while open; then
    /// Esc/⏎/←/→/⇥/↓/Delete, ⌘-keys, digits (⇧-digit moves instead of
    /// jumping), and finally letters into the filter.
    private func handle(_ event: NSEvent) -> Bool {
        // Edit mode: Esc backs out; every other key reaches the text fields
        // (Enter saves via the field's onSubmit).
        if model.editing != nil {
            if event.keyCode == 53 {
                model.cancelEdit()
                return true
            }
            return false
        }

        // ⇧⏎ moves the captured window to the highlighted tile. Ahead of the
        // tile menu so the menu's own Return can't swallow it, and it always
        // consumes the event: a ⇧⏎ with nothing to move must do nothing rather
        // than fall through to a plain select.
        if event.keyCode == 36 || event.keyCode == 76, event.modifierFlags.contains(.shift) {
            model.closeMenu()
            _ = moveHighlighted()
            return true
        }

        // Profile submenu: Esc/Left step back to the menu; every other key
        // dismisses both and then does its normal job.
        if model.submenuOpen {
            switch event.keyCode {
            case 53, 123: model.closeSubmenu(); return true         // Esc / Left
            case 125: model.moveSubmenuSelection(1); return true    // Down
            case 126: model.moveSubmenuSelection(-1); return true   // Up
            case 36, 76: activateSelectedProfile(); return true     // Return
            default: model.closeMenu()
            }
        }

        // Tile menu owns Up/Down/Enter/Esc while it's open, plus Right on a
        // Chrome cell (profile submenu). Every other key dismisses it and
        // then does its normal job.
        if model.menuOpen {
            let items = model.menuItems
            let selected = items.indices.contains(model.menuSelection)
                ? items[model.menuSelection] : nil
            switch event.keyCode {
            case 53: model.closeMenu(); return true              // Esc
            case 125: model.moveMenuSelection(1); return true    // Down
            case 126: model.moveMenuSelection(-1); return true   // Up
            case 36, 76: activateSelectedMenuItem(); return true // Return
            case 124 where selected.map(model.profileSubmenuAvailable) == true:
                model.openSubmenu(); return true                 // Right on Chrome
            case 124:
                Log.switcher.notice("Right in menu, selection \(self.model.menuSelection, privacy: .public) item \(selected?.id ?? "none", privacy: .public) bundle \(selected?.launchApp?.bundleID ?? "-", privacy: .public): submenu unavailable")
                model.closeMenu()
            default: model.closeMenu()
            }
        }

        switch event.keyCode {
        case 53: close(); return true                    // Esc
        case 36, 76: selectHighlighted(); return true    // Return / keypad Enter
        case 123: model.moveHighlight(-1); return true   // Left
        case 124: model.moveHighlight(1); return true    // Right
        case 125: openMenuHighlighted(); return true     // Down = tile menu
        case 48:                                         // Tab / ⇧Tab walk tiles
            model.moveHighlight(event.modifierFlags.contains(.shift) ? -1 : 1)
            return true
        case 126: return true                            // Up: reserved, no beep
        case 51: model.backspace(); return true          // Delete
        default: break
        }

        guard let chars = event.charactersIgnoringModifiers, chars.count == 1,
              let c = chars.first else { return true }

        // ⌘ + letter quick-launches that app onto the highlighted space —
        // works whether or not the tile menu is open. ⌘, is the standard
        // Preferences shortcut; it closes the switcher first so the window
        // isn't fighting a nonactivating panel for key status.
        if event.modifierFlags.contains(.command) {
            if c == "," {
                close()
                onPreferences?()
            } else if let app = model.quickLaunchApp(matching: c) {
                quickLaunchHighlighted(app)
            }
            return true
        }

        // Digits 1-9 ALWAYS jump immediately, even mid-filter (reserved keys),
        // and ⇧1-9 moves the captured window straight to that space instead.
        // The index comes off the key code because `charactersIgnoringModifiers`
        // does not ignore Shift — ⇧1 arrives as "!" — with the character as a
        // fallback so the numeric keypad still jumps.
        let digit = Switching.index(forDigitKeyCode: event.keyCode)
            ?? c.wholeNumberValue.flatMap { (1...9).contains($0) ? $0 - 1 : nil }
        if let d = digit, event.modifierFlags.intersection([.command, .option]).isEmpty {
            if event.modifierFlags.contains(.shift) {
                if viewModel.items.indices.contains(d),
                   let window = model.movableWindow(for: viewModel.items[d]) {
                    moveWindow(window, to: viewModel.items[d])
                }
            } else if viewModel.items.indices.contains(d) {
                select(absolute: d)
            }
            return true
        }

        // Letters/space filter, case-insensitive.
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           c.isLetter || c == " " {
            model.append(c)
            return true
        }

        return true // swallow everything else; no beeps
    }
}

struct SwitcherView: View {
    @ObservedObject var model: SwitcherModel
    // Observed directly so tiles re-render when names/colors/current change —
    // SwitcherModel doesn't republish the view-model's updates.
    @ObservedObject var spaces: SpacesViewModel
    @ObservedObject var previews: PreviewStore
    var onPick: (Int) -> Void
    var onMenuPick: (TileMenuItem) -> Void
    var onProfilePick: (QuickLaunchApp, ChromeProfiles.Profile) -> Void
    /// Right-click path: the target tile comes from the gesture, not from
    /// `model.menuFor`, which only the Down-menu sets.
    var onMoveWindow: (MovableWindow, SpaceItem) -> Void

    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            tiles
            if model.editing != nil {
                Divider().opacity(0.5)
                editBar
            }
            footer
        }
        .fixedSize()
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18)))
                .shadow(color: .black.opacity(0.5), radius: 34, y: 12)
        )
        .padding(30) // room for the shadow inside the transparent stage
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: model.editing == nil) { _, notEditing in
            if notEditing {
                nameFocused = false
            } else {
                // Give the field a beat to exist before focusing it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { nameFocused = true }
            }
        }
    }

    /// Key hints leading, preferences hint trailing, and — only when a window
    /// was captured on open — a centered chip naming it and its move keys.
    private var footer: some View {
        HStack {
            Text("1–9 jumps · ⏎ selects · ⇥ next · ↓ more")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 20)
            if let window = model.movable {
                moveHint(window)
                Spacer(minLength: 20)
            }
            Text("⌘, preferences")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
        .frame(height: TileMetrics.footerHeight, alignment: .center)
    }

    /// The captured window's app, plus the two keys that move it. Everything
    /// stays at 10pt so the footer keeps its fixed height — the menu card's
    /// offset math adds TileMetrics.footerHeight and would drift otherwise.
    private func moveHint(_ window: MovableWindow) -> some View {
        HStack(spacing: 5) {
            if let icon = window.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 12, height: 12)
            } else {
                Image(systemName: "macwindow")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Text("⇧⏎ move \(window.appName) here · ⇧1–9 to a number")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            if model.filter.isEmpty {
                Text("Type to filter")
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            } else {
                Text(model.filter)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: 380)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color.white.opacity(0.08)))
        .padding(.top, 14)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var tiles: some View {
        let filtered = model.filtered
        if filtered.isEmpty {
            Text("No matching spaces")
                .foregroundStyle(.secondary)
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .center)
        } else {
            HStack(spacing: 0) {
                ForEach(Array(filtered.enumerated()), id: \.element.id) { pos, item in
                    if pos > 0 { tileDivider }
                    SwitcherTile(item: item,
                                 metrics: model.tile,
                                 preview: previews.image(for: item.uuid),
                                 isCurrent: item.index == model.viewModel.currentIndex,
                                 isHighlighted: pos == model.highlight,
                                 isEditing: item.uuid == model.editing?.uuid,
                                 onEdit: { model.beginEdit(item) })
                        .contentShape(Rectangle())
                        .onTapGesture { onPick(item.index) }
                        .contextMenu {
                            Button("Rename “\(item.name)”…") { model.beginEdit(item) }
                            if let window = model.movableWindow(for: item) {
                                Button("Move \(window.appName) window here") {
                                    onMoveWindow(window, item)
                                }
                            }
                        }
                }
            }
            .padding(TileMetrics.rowInset)
            // Overlay, not a VStack row: overlays don't feed back into their
            // parent's size, so opening the menu can't resize the panel.
            // Anchored to the tiles row; only the fixed-height footer sits
            // between this row's bottom edge and the panel's, so adding
            // footerHeight floats the card clear of the panel without
            // measuring anything.
            .overlay(alignment: .bottomLeading) {
                if model.menuOpen {
                    menuCard
                        .offset(x: MenuMetrics.xOffset(pos: model.highlight,
                                                       tiles: model.filtered.count,
                                                       tile: model.tile),
                                y: menuCardHeight + MenuMetrics.gap + TileMetrics.footerHeight)
                    if let profiles = model.submenuProfiles, let app = model.submenuApp {
                        submenuCard(app: app, profiles: profiles)
                    }
                }
            }
            // The header is wider than a filtered-down row; without this the
            // row hugs the panel's leading edge. Applied after the overlay so
            // the menu card stays anchored to the row, not the panel.
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    /// 1px etched groove between tiles: light line fading at both ends so it
    /// reads as a divot in the glass, ~85% of tile height.
    private var tileDivider: some View {
        Rectangle()
            .fill(LinearGradient(
                colors: [.clear, .white.opacity(0.18), .white.opacity(0.18), .clear],
                startPoint: .top, endPoint: .bottom))
            .frame(width: 1, height: model.tile.dividerHeight)
            .padding(.horizontal, 8.5) // keeps the ~18pt tile gap
    }

    /// Shared by the card's frame and the overlay's offset — the two must
    /// agree or the card drifts off its tile.
    private var menuCardHeight: CGFloat {
        let items = model.menuItems
        return MenuMetrics.cardHeight(apps: items.compactMap(\.launchApp).count,
                                      extraRows: items.compactMap(\.movableWindow).count)
    }

    /// Floating satellite card for the highlighted tile: a Rename row, an
    /// optional "Move ‹app› window here" row, then the quick-launch apps as a
    /// centered icon strip under an "Open in" label. The label names the
    /// selected app — the icons carry no text, so keyboard navigation needs
    /// the name somewhere. Selection index 0 is Rename; the move row, when
    /// present, is 1, which is what shifts the apps to `pos + appBase`.
    /// A Chrome cell (profile targeting on, profiles found) carries a trailing
    /// chevron; Right on it opens the profile submenu as a second card that
    /// cascades to the right of this one, its top aligned with the Chrome
    /// cell, flipping to the left when it would run off the screen edge.
    /// This card is unchanged while it's open.
    private var menuCard: some View {
        menuContent(accent: model.menuFor?.accentColor ?? .secondary)
            .font(.system(size: 15))
            .padding(MenuMetrics.inset)
            // Pinned to the computed height the overlay offset uses, so the card
            // drawn and the card the layout math positions can't drift apart.
            .frame(width: MenuMetrics.width, height: menuCardHeight, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.thinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12)))
                    .shadow(color: .black.opacity(0.4), radius: 14, y: 5)
            )
    }

    /// Profile submenu card, positioned from the same `.bottomLeading` anchor
    /// as the menu card. With that anchor `.offset(y:)` moves a card's bottom
    /// edge y below the row's bottom, so the menu card's top sits at
    /// rowBottom + gap + footerHeight. Putting this card's top at that plus
    /// the Chrome cell's `appCellTop` means an offset of
    /// gap + footerHeight + appCellTop + submenuHeight.
    private func submenuCard(app: QuickLaunchApp, profiles: [ChromeProfiles.Profile]) -> some View {
        let items = model.menuItems
        let cellPos = items.compactMap(\.launchApp).firstIndex { $0.id == app.id } ?? 0
        let extraRows = items.compactMap(\.movableWindow).count
        let height = MenuMetrics.submenuHeight(profiles: profiles.count)
        let y = MenuMetrics.gap + TileMetrics.footerHeight
            + MenuMetrics.appCellTop(pos: cellPos, extraRows: extraRows) + height
        let x = MenuMetrics.submenuXOffset(pos: model.highlight,
                                           tiles: model.filtered.count,
                                           stageWidth: NSScreen.main?.visibleFrame.width ?? 0,
                                           tile: model.tile)
        return submenuContent(app: app, profiles: profiles,
                              accent: model.menuFor?.accentColor ?? .secondary)
            .font(.system(size: 13))
            .padding(MenuMetrics.inset)
            .frame(width: MenuMetrics.submenuWidth, height: height, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.thinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12)))
                    .shadow(color: .black.opacity(0.4), radius: 14, y: 5)
            )
            .offset(x: x, y: y)
    }

    /// "Open in profile" label, then one row per discovered profile (name
    /// over email). The entry's configured default carries a check.
    private func submenuContent(app: QuickLaunchApp, profiles: [ChromeProfiles.Profile],
                                accent: Color) -> some View {
        VStack(spacing: 0) {
            Text("Open in profile")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: MenuMetrics.labelHeight)

            ForEach(Array(profiles.enumerated()), id: \.element.id) { pos, profile in
                HStack(spacing: 10) {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(profile.name)
                            .font(.system(size: 13))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if let email = profile.email {
                            Text(email)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    Spacer(minLength: 0)
                    if app.chromeProfile == profile.directory {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 11)
                .frame(height: MenuMetrics.profileRowHeight)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(model.submenuSelection == pos ? accent.opacity(0.28) : .clear))
                .contentShape(Rectangle())
                .onTapGesture { onProfilePick(app, profile) }
                .onHover { if $0 { model.submenuSelection = pos } }
            }
        }
    }

    private func menuContent(accent: Color) -> some View {
        let apps: [QuickLaunchApp] = model.menuItems.compactMap(\.launchApp)
        let moveWindow: MovableWindow? = model.menuItems.compactMap(\.movableWindow).first
        let appBase = 1 + (moveWindow == nil ? 0 : 1)
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "pencil")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                Text("Rename…")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .frame(height: MenuMetrics.rowHeight)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(model.menuSelection == 0 ? accent.opacity(0.28) : .clear))
            .contentShape(Rectangle())
            .onTapGesture { onMenuPick(.rename) }
            .onHover { if $0 { model.menuSelection = 0 } }

            if let window = moveWindow {
                HStack(spacing: 10) {
                    if let icon = window.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 18, height: 18)
                            .frame(width: 24, height: 24)
                    } else {
                        Image(systemName: "macwindow")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                    }
                    Text("Move window here")
                        .help("Move the \(window.appName) window to this space")
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 11)
                .frame(height: MenuMetrics.rowHeight)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(model.menuSelection == 1 ? accent.opacity(0.28) : .clear))
                .contentShape(Rectangle())
                .onTapGesture { onMenuPick(.moveWindow(window)) }
                .onHover { if $0 { model.menuSelection = 1 } }
            }

            if !apps.isEmpty {
                Rectangle()
                    .fill(Color.white.opacity(0.10))
                    .frame(height: 1)
                    .padding(.vertical, MenuMetrics.dividerPad)
                    .padding(.horizontal, 4)

                Text("Open on display")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: MenuMetrics.labelHeight)

                ForEach(Array(apps.enumerated()), id: \.element.id) { pos, app in
                    let selected = model.menuSelection == pos + appBase
                    VStack(spacing: 4) {
                        if let icon = app.icon {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 40, height: 40)
                        } else {
                            Image(systemName: "app.dashed")
                                .font(.system(size: 22))
                                .foregroundStyle(.secondary)
                                .frame(width: 40, height: 40)
                        }
                        Text(app.label)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: MenuMetrics.appCellHeight)
                    .overlay(alignment: .trailing) {
                        if model.profileSubmenuAvailable(for: .launch(app)) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .padding(.trailing, 6)
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 7)
                        .fill(selected ? accent.opacity(0.28) : .clear))
                    .contentShape(Rectangle())
                    .onTapGesture { onMenuPick(.launch(app)) }
                    .onHover { if $0 { model.menuSelection = pos + appBase } }
                }
            }
        }
    }

    private var editBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if let item = model.editing {
                    Text("\(item.number)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(item.accentColor))
                }
                TextField("😀", text: $model.editEmoji)
                    .frame(width: 46)
                    .multilineTextAlignment(.center)
                TextField(editPlaceholder, text: $model.editName)
                    .focused($nameFocused)
                    .onSubmit { model.saveEdit() }
                    .frame(minWidth: 220)
                Text("⏎ save · esc back")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 13))

            HStack(spacing: 8) {
                swatch(nil, color: nil)
                ForEach(Palette.ordered, id: \.key) { entry in
                    swatch(entry.key, color: Color(nsColor: entry.color))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var editPlaceholder: String {
        guard let item = model.editing else { return "" }
        return item.isFullScreen ? "Full Screen" : "Desktop \(item.number)"
    }

    @ViewBuilder
    private func swatch(_ key: String?, color: Color?) -> some View {
        let selected = model.editAccent == key
        Button {
            model.editAccent = key
        } label: {
            ZStack {
                Circle()
                    .fill(color ?? Color.primary.opacity(0.08))
                    .frame(width: 20, height: 20)
                if color == nil {
                    Image(systemName: "sparkles")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                if selected {
                    Circle().strokeBorder(Color.primary, lineWidth: 2)
                        .frame(width: 26, height: 26)
                }
            }
            .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .help(key.map { $0.capitalized } ?? "Auto color")
    }
}

struct SwitcherTile: View {
    let item: SpaceItem
    let metrics: TileMetrics
    let preview: NSImage?
    let isCurrent: Bool
    let isHighlighted: Bool
    let isEditing: Bool
    var onEdit: () -> Void

    @State private var hovering = false

    private var thumbSize: CGSize { metrics.thumb }

    var body: some View {
        VStack(spacing: 10) {
            thumbnail.overlay(centerBadge)
            HStack(spacing: 5) {
                if let emoji = item.emoji {
                    Text(emoji).font(.system(size: 14))
                }
                Text(item.name)
                    .font(.system(size: 14, weight: isCurrent ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if item.isFullScreen {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: thumbSize.width)
        }
        .padding(.horizontal, TileMetrics.hPadding)
        .padding(.top, 10)
        .padding(.bottom, 11)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isHighlighted || isEditing
                      ? item.accentColor.opacity(0.28) : Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(isHighlighted || isEditing ? item.accentColor
                              : (isCurrent ? Color.primary.opacity(0.35) : .clear),
                              lineWidth: isHighlighted || isEditing ? 2 : 1)
        )
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(4)
                        .background(Circle().fill(.thinMaterial))
                }
                .buttonStyle(.plain)
                .padding(6)
                .help("Rename this space")
            }
        }
        .onHover { hovering = $0 }
    }

    /// Space number, centered over the preview: a big translucent numeral
    /// (watermark style), accent-tinted on the current space. The tight
    /// shadow keeps it readable over light screenshot content.
    private var centerBadge: some View {
        Text("\(item.number)")
            .font(.system(size: metrics.numeralSize, weight: .heavy, design: .default))
            .foregroundStyle(isCurrent ? item.accentColor.opacity(0.75) : Color.white.opacity(0.42))
            .shadow(color: .black.opacity(0.55), radius: 1, y: 1)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let preview {
            Image(nsImage: preview)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: thumbSize.width, height: thumbSize.height)
                .overlay(Color.black.opacity(0.35)) // dim scrim so the numeral pops
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.white.opacity(0.12)))
        } else {
            // Not visited yet this session (or Screen Recording not granted).
            // The centered number badge overlays this; tint alone suffices.
            RoundedRectangle(cornerRadius: 4)
                .fill(item.accentColor.opacity(0.10))
                .frame(width: thumbSize.width, height: thumbSize.height)
        }
    }
}
