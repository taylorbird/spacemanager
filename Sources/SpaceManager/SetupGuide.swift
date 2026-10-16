import AppKit
import SwiftUI

// MARK: - One-time setup guide (Accessibility + native shortcuts)

final class SetupGuideController {
    private let status: SetupStatus
    private let viewModel: SpacesViewModel
    private var window: NSWindow?

    init(status: SetupStatus, viewModel: SpacesViewModel) {
        self.status = status
        self.viewModel = viewModel
    }

    func show() {
        status.recheck()
        if window == nil {
            let w = NSWindow(contentRect: .zero,
                             styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
            w.title = "SpaceManager Setup"
            w.isReleasedWhenClosed = false
            // Normal level, not floating: every button here sends the user to
            // System Settings or a macOS permission prompt, which must be able
            // to come to the front over this window.
            // Follow the user: without this the window stays on the space it
            // first opened on, and reopening it from another space shows nothing.
            w.collectionBehavior = [.moveToActiveSpace]
            let host = NSHostingView(rootView: SetupGuideView(status: status, viewModel: viewModel))
            w.contentView = host
            // Size before centering — centered at zero size, it parks off-center.
            host.layoutSubtreeIfNeeded()
            w.setContentSize(host.fittingSize)
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if let window {
            Log.setup.notice("setup guide shown, frame \(window.frame.logDescription, privacy: .public)")
        }
    }
}

struct SetupGuideView: View {
    @ObservedObject var status: SetupStatus
    @ObservedObject var viewModel: SpacesViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Switching spaces needs two macOS settings. Reads (names, HUD, menu) work without them.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            row(done: status.axTrusted,
                title: "Accessibility permission",
                detail: "Lets SpaceManager press the native Ctrl+N shortcuts for you.") {
                Button("Request…") {
                    status.requestAccessibility()
                    SetupStatus.openAccessibilitySettings()
                }
            }

            row(done: shortcutsDone,
                title: "“Switch to Desktop” shortcuts (\(status.enabledDesktopShortcuts.count) of \(neededCount) enabled)",
                detail: "System Settings → Keyboard → Keyboard Shortcuts… → Mission Control: check “Switch to Desktop 1…\(neededCount)”.") {
                Button("Open Keyboard Settings") { SetupStatus.openKeyboardSettings() }
            }

            row(done: ScreenCapture.authorized,
                title: "Screen Recording (optional)",
                detail: "Enables switcher tile previews — a screenshot of each space from your last visit. macOS requires relaunching SpaceManager after granting.") {
                Button("Open Screen Recording Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Recheck") { status.recheck() }
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var neededCount: Int {
        min(max(viewModel.items.count, 1), Switching.maxSpaces)
    }

    private var shortcutsDone: Bool {
        (1...neededCount).allSatisfy { status.enabledDesktopShortcuts.contains($0) }
    }

    private func row<Action: View>(done: Bool, title: String, detail: String,
                                   @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? Color.green : Color.secondary)
                .font(.system(size: 16))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !done { action().padding(.top, 3) }
            }
            Spacer(minLength: 0)
        }
    }
}
