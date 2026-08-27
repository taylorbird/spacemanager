import AppKit
import SwiftUI

// MARK: - Preferences (quick-launch entries, Chrome profiles, window placement)

final class PreferencesController {
    private let settings: Settings
    private var window: NSWindow?

    init(settings: Settings) { self.settings = settings }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: .zero,
                             styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
            w.title = "SpaceManager Preferences"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: PreferencesView(settings: settings))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct PreferencesView: View {
    @ObservedObject var settings: Settings
    private let profiles = ChromeProfiles.load()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Quick Launch").font(.headline)

            Toggle("Open Chrome in a specific profile", isOn: $settings.chromeProfilesEnabled)
            Toggle("Position new windows", isOn: $settings.windowPlacementEnabled)
            Text("Both off = plain launches, exactly as before these features existed.")
                .font(.system(size: 11)).foregroundStyle(.secondary)

            Divider()

            ForEach($settings.quickLaunch) { $app in
                QuickLaunchRow(app: $app, profiles: profiles,
                               profilesEnabled: settings.chromeProfilesEnabled,
                               placementEnabled: settings.windowPlacementEnabled,
                               onDelete: {
                                   settings.quickLaunch.removeAll { $0.id == app.id }
                               })
            }

            Button { addApp() } label: { Label("Add App", systemImage: "plus") }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
        let label = url.deletingPathExtension().lastPathComponent
        settings.quickLaunch = QuickLaunchApp.normalized(
            settings.quickLaunch + [QuickLaunchApp(label: label, bundleID: id)])
    }
}

struct QuickLaunchRow: View {
    @Binding var app: QuickLaunchApp
    let profiles: [ChromeProfiles.Profile]
    let profilesEnabled: Bool
    let placementEnabled: Bool
    var onDelete: () -> Void

    private var isChrome: Bool { app.bundleID == "com.google.Chrome" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let icon = app.icon {
                    Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                }
                Text(app.label)
                Text("⌘").foregroundStyle(.secondary)
                TextField("", text: Binding(
                    get: { app.keyEquivalent.uppercased() },
                    set: { app.keyEquivalent = String($0.lowercased().suffix(1)) }
                ))
                .textFieldStyle(.roundedBorder).frame(width: 32)
                Spacer()
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }.buttonStyle(.borderless)
            }

            if isChrome, !profiles.isEmpty {
                Picker("Profile", selection: Binding(
                    get: { app.chromeProfile ?? "" },
                    set: { app.chromeProfile = $0.isEmpty ? nil : $0 }
                )) {
                    Text("Last used (default)").tag("")
                    ForEach(profiles) { p in Text(p.label).tag(p.directory) }
                }
                .disabled(!profilesEnabled)
            }

            HStack(spacing: 8) {
                Picker("Position", selection: Binding(
                    get: { app.placement?.preset.rawValue ?? "" },
                    set: { raw in
                        if raw.isEmpty { app.placement = nil }
                        else if let preset = PlacementSpec.Preset(rawValue: raw) {
                            var spec = app.placement ?? PlacementSpec()
                            spec.preset = preset
                            app.placement = spec
                        }
                    }
                )) {
                    Text("Don't position").tag("")
                    ForEach(PlacementSpec.Preset.allCases, id: \.rawValue) { p in
                        Text(p.label).tag(p.rawValue)
                    }
                }
                if app.placement?.preset == .custom {
                    Button("Capture Current Window") {
                        if let frame = WindowPlacer.currentWindowFrame(bundleID: app.bundleID) {
                            app.placement?.customRect = frame
                        }
                    }
                    if app.placement?.customRect == nil {
                        Text("app must be running with a window")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(!placementEnabled)
        }
        .font(.system(size: 12))
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }
}
