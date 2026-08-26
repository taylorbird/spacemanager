import AppKit
import SwiftUI

// MARK: - Actions editor (plain in-app preferences; no config files)

final class ActionsEditorController {
    private let viewModel: SpacesViewModel
    private let store: ActionsStore
    private let settings: Settings
    private var window: NSWindow?

    init(viewModel: SpacesViewModel, store: ActionsStore, settings: Settings) {
        self.viewModel = viewModel
        self.store = store
        self.settings = settings
    }

    func show(spaceUUID: String? = nil) {
        if window == nil {
            let w = NSWindow(contentRect: .zero,
                             styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
            w.title = "Space Actions"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: ActionsEditorView(
                viewModel: viewModel, store: store, settings: settings))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct ActionsEditorView: View {
    @ObservedObject var viewModel: SpacesViewModel
    @ObservedObject var store: ActionsStore
    @ObservedObject var settings: Settings
    @State private var selectedUUID: String?

    private var selected: SpaceItem? {
        selectedUUID.flatMap { viewModel.item(for: $0) } ?? viewModel.current
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Space", selection: Binding(
                get: { selected?.uuid ?? "" },
                set: { selectedUUID = $0 }
            )) {
                ForEach(viewModel.items) { item in
                    Text("\(item.number)  \(item.menuLabel)").tag(item.uuid)
                }
            }

            if let item = selected {
                actionsList(for: item)
            } else {
                Text("No spaces detected.").foregroundStyle(.secondary)
            }

            Divider()

            HStack(spacing: 8) {
                Text("On-arrive settle time")
                Slider(value: $settings.settleSeconds, in: 0.25...3.0, step: 0.25)
                    .frame(width: 160)
                Text(String(format: "%.2f s", settings.settleSeconds))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12))

            Text("Actions run when you land on the space and stay past the settle time (on-arrive), or from the menu bar (manual).")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 560)
    }

    @ViewBuilder
    private func actionsList(for item: SpaceItem) -> some View {
        let actions = store.actions(for: item.uuid)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(actions) { action in
                ActionRowEditor(
                    action: action,
                    onChange: { updated in
                        var list = store.actions(for: item.uuid)
                        if let i = list.firstIndex(where: { $0.id == updated.id }) {
                            list[i] = updated
                            store.set(list, for: item.uuid)
                        }
                    },
                    onDelete: {
                        store.set(actions.filter { $0.id != action.id }, for: item.uuid)
                    }
                )
            }
            if actions.isEmpty {
                Text("No actions for this space yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Button {
                store.set(actions + [SpaceAction()], for: item.uuid)
            } label: {
                Label("Add Action", systemImage: "plus")
            }
        }
    }
}

struct ActionRowEditor: View {
    @State var action: SpaceAction
    var onChange: (SpaceAction) -> Void
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Title (optional)", text: $action.title)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                Picker("", selection: $action.kind) {
                    ForEach(SpaceAction.Kind.allCases, id: \.self) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
                .labelsHidden()
                Spacer()
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }

            HStack(spacing: 8) {
                if action.kind == .app {
                    Text(action.target.isEmpty ? "No app chosen" : action.target)
                        .font(.system(size: 11))
                        .foregroundStyle(action.target.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose App…") { chooseApp() }
                } else {
                    TextField("Shell command (runs via zsh -lc)", text: $action.target)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }
            }

            HStack(spacing: 14) {
                Toggle("Run on arrival", isOn: $action.onArrive)
                if action.onArrive {
                    Picker("", selection: $action.oncePerSession) {
                        Text("Every visit").tag(false)
                        Text("Once per session").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 210)
                    .labelsHidden()
                }
                Spacer()
            }
            .font(.system(size: 12))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        .onChange(of: action) { _, updated in onChange(updated) }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            action.target = url.path
        }
    }
}
