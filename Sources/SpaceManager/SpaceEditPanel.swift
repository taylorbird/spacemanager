import AppKit
import SwiftUI

// MARK: - Edit a space (name + emoji + accent) — glass card, keyboard-first

final class SpaceEditController {
    private let metadata: MetadataStore
    private var panel: KeyPanel?

    private let stageSize = NSSize(width: 560, height: 340)

    init(metadata: MetadataStore) {
        self.metadata = metadata
    }

    func edit(item: SpaceItem) {
        dismiss()

        let p = KeyPanel(contentRect: NSRect(origin: .zero, size: stageSize),
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .popUpMenu
        p.hidesOnDeactivate = false
        p.animationBehavior = .none
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let view = SpaceEditView(
            item: item,
            meta: metadata.meta(for: item.uuid),
            onSave: { [weak self] meta in
                self?.metadata.update(meta, for: item.uuid)
                self?.dismiss()
            },
            onCancel: { [weak self] in self?.dismiss() }
        )
        p.contentView = NSHostingView(rootView: view)
        p.keyHandler = { [weak self] event in
            if event.keyCode == 53 { self?.dismiss(); return true } // Esc always cancels
            return false // everything else reaches the text fields
        }
        p.onResign = { [weak self] in self?.dismiss() } // click-away dismisses

        if let screen = NSScreen.main {
            // Same spot the switcher occupies, so edit feels like a mode change.
            let f = screen.visibleFrame
            p.setFrame(NSRect(x: f.midX - stageSize.width / 2,
                              y: f.maxY - f.height * 0.22 - stageSize.height,
                              width: stageSize.width, height: stageSize.height),
                       display: true)
        }
        panel = p
        p.makeKeyAndOrderFront(nil)
    }

    private func dismiss() {
        guard let p = panel else { return }
        panel = nil // clear first: orderOut triggers resignKey -> onResign
        p.orderOut(nil)
    }
}

struct SpaceEditView: View {
    let item: SpaceItem
    @State private var name: String
    @State private var emoji: String
    @State private var accent: String?
    var onSave: (SpaceMeta) -> Void
    var onCancel: () -> Void

    @FocusState private var nameFocused: Bool

    init(item: SpaceItem, meta: SpaceMeta,
         onSave: @escaping (SpaceMeta) -> Void, onCancel: @escaping () -> Void) {
        self.item = item
        _name = State(initialValue: meta.name ?? "")
        _emoji = State(initialValue: meta.emoji ?? "")
        _accent = State(initialValue: meta.accent)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var defaultName: String {
        item.isFullScreen ? "Full Screen" : "Desktop \(item.number)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text("\(item.number)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(item.accentColor))
                Text("Edit Space")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack(spacing: 10) {
                TextField("😀", text: $emoji)
                    .frame(width: 46)
                    .multilineTextAlignment(.center)
                TextField(defaultName, text: $name)
                    .focused($nameFocused)
                    .onSubmit { save() }
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 14))

            HStack(spacing: 8) {
                swatch(nil, color: nil)
                ForEach(Palette.ordered, id: \.key) { entry in
                    swatch(entry.key, color: Color(nsColor: entry.color))
                }
                Spacer()
            }

            HStack {
                Text("⏎ save · esc cancel")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 400)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.1)))
                .shadow(color: .black.opacity(0.3), radius: 28, y: 10)
        )
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            // Panel needs a beat to become key before focus lands.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { nameFocused = true }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedEmoji = emoji.trimmingCharacters(in: .whitespaces)
        onSave(SpaceMeta(name: trimmedName.isEmpty ? nil : trimmedName,
                         emoji: trimmedEmoji.isEmpty ? nil : trimmedEmoji,
                         accent: accent))
    }

    @ViewBuilder
    private func swatch(_ key: String?, color: Color?) -> some View {
        let selected = accent == key
        Button {
            accent = key
        } label: {
            ZStack {
                Circle()
                    .fill(color ?? Color.primary.opacity(0.08))
                    .frame(width: 22, height: 22)
                if color == nil {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                if selected {
                    Circle().strokeBorder(Color.primary, lineWidth: 2)
                        .frame(width: 28, height: 28)
                }
            }
            .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help(key.map { $0.capitalized } ?? "Auto color")
    }
}
