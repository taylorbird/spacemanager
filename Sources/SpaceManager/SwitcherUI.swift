import AppKit
import SwiftUI

// MARK: - Switcher (Ctrl+Option+Cmd+? panel, horizontal tiles + inline space editing)

/// Tile row geometry. Shared so the context menu can sit exactly under the
/// tile it belongs to — the layout is fixed-size, so this stays exact.
enum TileMetrics {
    static let thumb = CGSize(width: 184, height: 113)
    static let hPadding: CGFloat = 10
    static let width = thumb.width + hPadding * 2
    /// Divider (1pt) plus its 8.5pt padding either side.
    static let gap: CGFloat = 18
    static let rowInset: CGFloat = 16
    /// Fixed so the menu-card offset can account for it — the footer sits
    /// between the tiles row and the panel's bottom edge. Tall enough that
    /// hints float clear of the panel edge instead of hugging it.
    static let footerHeight: CGFloat = 28

    static func leadingOffset(pos: Int) -> CGFloat {
        rowInset + CGFloat(pos) * (width + gap)
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

    /// Rename row, then (when apps exist) divider + label + one cell per app.
    /// Still fully computable before layout — see the type comment.
    static func cardHeight(apps: Int) -> CGFloat {
        let appsBlock: CGFloat = apps > 0
            ? 1 + dividerPad * 2 + labelHeight + CGFloat(apps) * appCellHeight : 0
        return rowHeight + appsBlock + inset * 2
    }

    /// Card centered under the highlighted tile, clamped to the row's edges
    /// so an end tile's card tucks inward (popover-style) instead of
    /// overhanging the panel. A card wider than the whole row centers on it.
    static func xOffset(pos: Int, tiles: Int) -> CGFloat {
        let rowWidth = CGFloat(tiles) * TileMetrics.width
            + CGFloat(max(0, tiles - 1)) * TileMetrics.gap
            + TileMetrics.rowInset * 2
        guard width <= rowWidth else { return (rowWidth - width) / 2 }
        let centered = TileMetrics.leadingOffset(pos: pos)
            + (TileMetrics.width - width) / 2
        return min(max(centered, 0), rowWidth - width)
    }
}

/// One row of the per-tile context menu (Down on a highlighted tile).
enum TileMenuItem: Identifiable {
    case rename
    case launch(QuickLaunchApp)

    var id: String {
        switch self {
        case .rename: return "rename"
        case .launch(let app): return app.id.uuidString
        }
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

    var menuItems: [TileMenuItem] {
        [.rename] + quickLaunchApps.map { .launch($0) }
    }

    func openMenu(_ item: SpaceItem) {
        menuFor = item
        menuSelection = 0 // Rename is the default, as Down always was
    }

    func closeMenu() {
        menuFor = nil
        menuSelection = 0
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
    /// ⌘, from inside the switcher; wired by the app delegate.
    var onPreferences: (() -> Void)?

    private let stageSize = NSSize(width: 1200, height: 540)

    init(viewModel: SpacesViewModel, previews: PreviewStore, metadata: MetadataStore,
         settings: Settings, launcher: QuickLauncher) {
        self.viewModel = viewModel
        self.launcher = launcher
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
            onMenuPick: { [weak self] item in self?.activate(item) }
        )
        panel.contentView = NSHostingView(rootView: view)
        panel.keyHandler = { [weak self] event in self?.handle(event) ?? false }
        panel.onResign = { [weak self] in self?.close() }
    }

    var isOpen: Bool { panel.isVisible }

    func toggle() {
        isOpen ? close() : open()
    }

    func open() {
        viewModel.engine.refresh() // catch added/removed spaces before showing
        model.reset()
        if let screen = NSScreen.main {
            // Full-width transparent stage; the card centers itself.
            let f = screen.visibleFrame
            panel.setFrame(NSRect(x: f.minX,
                                  y: f.maxY - f.height * 0.18 - stageSize.height,
                                  width: f.width, height: stageSize.height),
                           display: true)
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        guard panel.isVisible else { return }
        model.cancelEdit()
        model.closeMenu()
        panel.orderOut(nil)
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
        case .launch(let app):
            quickLaunch(app, onSpaceIndex: target.index)
        }
    }

    private func activateSelectedMenuItem() {
        let items = model.menuItems
        guard items.indices.contains(model.menuSelection) else { return }
        activate(items[model.menuSelection])
    }

    /// Returns true when the event was consumed.
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

        // Tile menu owns Up/Down/Enter/Esc while it's open. Every other key
        // dismisses it and then does its normal job.
        if model.menuOpen {
            switch event.keyCode {
            case 53: model.closeMenu(); return true              // Esc
            case 125: model.moveMenuSelection(1); return true    // Down
            case 126: model.moveMenuSelection(-1); return true   // Up
            case 36, 76: activateSelectedMenuItem(); return true // Return
            default: model.closeMenu()
            }
        }

        switch event.keyCode {
        case 53: close(); return true                    // Esc
        case 36, 76: selectHighlighted(); return true    // Return / keypad Enter
        case 123: model.moveHighlight(-1); return true   // Left
        case 124: model.moveHighlight(1); return true    // Right
        case 125: openMenuHighlighted(); return true     // Down = tile menu
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

        // Digits 1-9 ALWAYS jump immediately, even mid-filter (reserved keys).
        if let d = c.wholeNumberValue, (1...9).contains(d),
           event.modifierFlags.intersection([.command, .option]).isEmpty {
            if viewModel.items.indices.contains(d - 1) { select(absolute: d - 1) }
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

    /// Trailing hint, with the leading side left open for future hints.
    private var footer: some View {
        HStack {
            Spacer(minLength: 0)
            Text("⌘, preferences")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
        .frame(height: TileMetrics.footerHeight, alignment: .center)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            if model.filter.isEmpty {
                Text("Type to filter · 1–9 jumps · ⏎ selects · ↓ more")
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
                                 preview: previews.image(for: item.uuid),
                                 isCurrent: item.index == model.viewModel.currentIndex,
                                 isHighlighted: pos == model.highlight,
                                 isEditing: item.uuid == model.editing?.uuid,
                                 onEdit: { model.beginEdit(item) })
                        .contentShape(Rectangle())
                        .onTapGesture { onPick(item.index) }
                        .contextMenu {
                            Button("Rename “\(item.name)”…") { model.beginEdit(item) }
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
                                                       tiles: model.filtered.count),
                                y: MenuMetrics.cardHeight(apps: model.menuItems.count - 1)
                                    + MenuMetrics.gap + TileMetrics.footerHeight)
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
            .frame(width: 1, height: 138)
            .padding(.horizontal, 8.5) // keeps the ~18pt tile gap
    }

    /// Floating satellite card for the highlighted tile: a Rename row, then
    /// the quick-launch apps as a centered icon strip under an "Open in"
    /// label. The label names the selected app — the icons carry no text, so
    /// keyboard navigation needs the name somewhere. Selection indices are
    /// unchanged: 0 is Rename, 1… are the apps, Down/Up walks them all.
    private var menuCard: some View {
        let accent = model.menuFor?.accentColor ?? .secondary
        let apps: [QuickLaunchApp] = model.menuItems.compactMap {
            if case .launch(let app) = $0 { return app }
            return nil
        }
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
                    let selected = model.menuSelection == pos + 1
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
                    .background(RoundedRectangle(cornerRadius: 7)
                        .fill(selected ? accent.opacity(0.28) : .clear))
                    .contentShape(Rectangle())
                    .onTapGesture { onMenuPick(.launch(app)) }
                    .onHover { if $0 { model.menuSelection = pos + 1 } }
                }
            }
        }
        .font(.system(size: 15))
        .padding(MenuMetrics.inset)
        .frame(width: MenuMetrics.width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.thinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12)))
                .shadow(color: .black.opacity(0.4), radius: 14, y: 5)
        )
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
    let preview: NSImage?
    let isCurrent: Bool
    let isHighlighted: Bool
    let isEditing: Bool
    var onEdit: () -> Void

    @State private var hovering = false

    private static let thumbSize = TileMetrics.thumb

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
            .frame(maxWidth: Self.thumbSize.width)
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
            // 107pt ≈ 77pt cap height: ~68% of the 113pt preview.
            .font(.system(size: 107, weight: .heavy, design: .default))
            .foregroundStyle(isCurrent ? item.accentColor.opacity(0.75) : Color.white.opacity(0.42))
            .shadow(color: .black.opacity(0.55), radius: 1, y: 1)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let preview {
            Image(nsImage: preview)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: Self.thumbSize.width, height: Self.thumbSize.height)
                .overlay(Color.black.opacity(0.35)) // dim scrim so the numeral pops
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.white.opacity(0.12)))
        } else {
            // Not visited yet this session (or Screen Recording not granted).
            // The centered number badge overlays this; tint alone suffices.
            RoundedRectangle(cornerRadius: 4)
                .fill(item.accentColor.opacity(0.10))
                .frame(width: Self.thumbSize.width, height: Self.thumbSize.height)
        }
    }
}
