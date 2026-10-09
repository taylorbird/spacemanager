import AppKit
import SwiftUI

// MARK: - Preferences (quick-launch entries, Chrome profiles, window placement)

final class PreferencesController {
    private let settings: Settings
    private var window: NSWindow?

    init(settings: Settings) { self.settings = settings }

    func show() {
        let firstShow = window == nil
        if firstShow {
            let w = NSWindow(contentRect: .zero,
                             styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
            w.title = "SpaceManager Preferences"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: PreferencesView(settings: settings))
            window = w
        }
        if firstShow, let w = window {
            // The window is created zero-size and SwiftUI sizes it lazily —
            // ordering front does NOT force that layout synchronously, so
            // center() on a zero frame parks the window at the screen top.
            // Size it explicitly from the hosting view's ideal size, center,
            // and recenter next runloop in case layout adjusted the frame.
            // First show only — a position the user drags to later is kept.
            if let content = w.contentView {
                content.layoutSubtreeIfNeeded()
                w.setContentSize(content.fittingSize)
            }
            w.center()
            DispatchQueue.main.async { w.center() }
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct PreferencesView: View {
    @ObservedObject var settings: Settings
    @StateObject private var launchAtLogin = LaunchAtLogin()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("General").font(.headline)

            launchAtLoginSection

            Divider()

            Text("Quick Launch").font(.headline)

            Toggle("Open Chrome in a specific profile", isOn: $settings.chromeProfilesEnabled)
            Toggle("Position new windows", isOn: $settings.windowPlacementEnabled)
            Toggle("Move windows between spaces", isOn: $settings.moveWindowEnabled)
            Text("Both off = plain launches, exactly as before these features existed.")
                .font(.system(size: 11)).foregroundStyle(.secondary)

            chromeProfilesSection

            Divider()

            ForEach($settings.quickLaunch) { $app in
                QuickLaunchRow(app: $app, profiles: settings.chromeProfiles,
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

    /// Mirrors macOS's login-item state; re-read whenever the window comes
    /// forward, since the user may have changed it in System Settings.
    private var launchAtLoginSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Launch at login", isOn: Binding(
                get: { launchAtLogin.isEnabled || launchAtLogin.needsApproval },
                set: { launchAtLogin.setEnabled($0) }
            ))
            if launchAtLogin.needsApproval {
                HStack(spacing: 8) {
                    Text("Allow Space Manager in System Settings to finish turning this on.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("Open Login Items") { launchAtLogin.openLoginItemsSettings() }
                }
            }
            if let error = launchAtLogin.lastError {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            launchAtLogin.refresh()
        }
    }

    /// Snapshot of Chrome's profiles. Chrome's folder is read only when the
    /// user clicks Refresh — never at runtime.
    private var chromeProfilesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Chrome profiles")
            HStack(spacing: 8) {
                Text(settings.chromeProfiles.isEmpty
                     ? "No profiles yet"
                     : "Profiles found: \(settings.chromeProfiles.count)")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Refresh from Chrome") { settings.refreshChromeProfiles() }
            }
            Text("Reading Chrome's profile list may ask for permission to access Chrome's data. Nothing else is read.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            if !settings.chromeProfiles.isEmpty {
                ForEach($settings.chromeProfiles) { $profile in
                    Toggle(profile.label, isOn: $profile.enabled)
                }
                Text("Enabled profiles appear in the switcher's profile submenu (Right on the Chrome cell).")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12))
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        .disabled(!settings.chromeProfilesEnabled)
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
                // A stored profile missing from the snapshot shows as the
                // default rather than an untagged (blank) selection.
                Picker("Profile", selection: Binding(
                    get: {
                        guard let dir = app.chromeProfile,
                              profiles.contains(where: { $0.directory == dir }) else { return "" }
                        return dir
                    },
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
