import AppKit
import SwiftUI

// MARK: - Switcher (Ctrl+0 Spotlight-style panel)

final class SwitcherModel: ObservableObject {
    @Published var filter = ""
    @Published var highlight = 0
    let store: SpaceStore

    init(store: SpaceStore) {
        self.store = store
    }

    /// Absolute space index + space, filtered by name. Prefix matches rank first.
    var filtered: [(index: Int, space: FakeSpace)] {
        let all = Array(store.spaces.enumerated()).map { (index: $0.offset, space: $0.element) }
        let f = filter.lowercased()
        guard !f.isEmpty else { return all }
        let matches = all.filter {
            $0.space.displayName(number: $0.index + 1).lowercased().contains(f)
        }
        let prefix = matches.filter {
            $0.space.displayName(number: $0.index + 1).lowercased().hasPrefix(f)
        }
        let rest = matches.filter {
            !$0.space.displayName(number: $0.index + 1).lowercased().hasPrefix(f)
        }
        return prefix + rest
    }

    func append(_ c: Character) {
        filter.append(c)
        highlight = 0
    }

    func backspace() {
        guard !filter.isEmpty else { return }
        filter.removeLast()
        highlight = 0
    }

    func moveHighlight(_ delta: Int) {
        let count = filtered.count
        guard count > 0 else { return }
        highlight = min(max(highlight + delta, 0), count - 1)
    }

    func reset() {
        filter = ""
        // Initial highlight = previous space: Ctrl+0 -> Enter is the back-toggle.
        highlight = store.previousIndex
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
    private let store: SpaceStore

    init(store: SpaceStore) {
        self.store = store
        model = SwitcherModel(store: store)
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 400),
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let view = SwitcherView(model: model) { [weak self] index in
            self?.select(absolute: index)
        }
        panel.contentView = NSHostingView(rootView: view)
        panel.keyHandler = { [weak self] event in self?.handle(event) ?? false }
        panel.onResign = { [weak self] in self?.close() }
    }

    var isOpen: Bool { panel.isVisible }

    func toggle() {
        isOpen ? close() : open()
    }

    func open() {
        model.reset()
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            // Spotlight-ish: centered horizontally, top edge ~25% down the screen.
            panel.setFrameTopLeftPoint(NSPoint(x: f.midX - panel.frame.width / 2,
                                               y: f.maxY - f.height * 0.22))
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }

    private func select(absolute index: Int) {
        close()
        store.switchTo(index)
    }

    private func selectHighlighted() {
        let rows = model.filtered
        guard rows.indices.contains(model.highlight) else { return }
        select(absolute: rows[model.highlight].index)
    }

    /// Returns true when the event was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: close(); return true                    // Esc
        case 36, 76: selectHighlighted(); return true    // Return / keypad Enter
        case 125: model.moveHighlight(1); return true    // Down
        case 126: model.moveHighlight(-1); return true   // Up
        case 51: model.backspace(); return true          // Delete
        default: break
        }

        guard let chars = event.charactersIgnoringModifiers, chars.count == 1,
              let c = chars.first else { return true }

        // Digits 1-9 ALWAYS jump immediately, even mid-filter (reserved keys).
        if let d = c.wholeNumberValue, (1...9).contains(d),
           event.modifierFlags.intersection([.command, .option]).isEmpty {
            if store.spaces.indices.contains(d - 1) { select(absolute: d - 1) }
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
    var onPick: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.5)
            rows
        }
        .frame(width: 440)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.1)))
                .shadow(color: .black.opacity(0.3), radius: 28, y: 10)
        )
        .padding(24) // room for the shadow inside the transparent panel
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            if model.filter.isEmpty {
                Text("Type to filter · 1–9 jumps · ⏎ selects")
                    .foregroundStyle(.tertiary)
            } else {
                Text(model.filter)
            }
            Spacer()
        }
        .font(.system(size: 15))
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var rows: some View {
        let filtered = model.filtered
        if filtered.isEmpty {
            Text("No matching spaces")
                .foregroundStyle(.secondary)
                .padding(16)
                .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 2) {
                ForEach(Array(filtered.enumerated()), id: \.element.space.id) { row, item in
                    SwitcherRow(space: item.space,
                                number: item.index + 1,
                                isCurrent: item.index == model.store.currentIndex,
                                isHighlighted: row == model.highlight)
                        .contentShape(Rectangle())
                        .onTapGesture { onPick(item.index) }
                }
            }
            .padding(8)
        }
    }
}

struct SwitcherRow: View {
    let space: FakeSpace
    let number: Int
    let isCurrent: Bool
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(isCurrent ? Color.white : Color.secondary)
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isCurrent ? space.accentColor : Color.primary.opacity(0.08))
                )

            Text(space.emoji ?? " ")
                .font(.system(size: 16))
                .frame(width: 22)

            Text(space.displayName(number: number))
                .font(.system(size: 14, weight: isCurrent ? .semibold : .regular))

            if space.isFullScreen {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 6) {
                ForEach(space.appSymbols, id: \.self) { symbol in
                    Image(systemName: symbol)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHighlighted ? space.accentColor.opacity(0.28) : .clear)
        )
    }
}
