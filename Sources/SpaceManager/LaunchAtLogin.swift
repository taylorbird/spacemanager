import Foundation
import ServiceManagement

/// Launch-at-login via the app's own login item. macOS owns the state — the
/// user can also flip it in System Settings > General > Login Items — so it
/// is read live from SMAppService and never mirrored into UserDefaults.
final class LaunchAtLogin: ObservableObject {
    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var lastError: String?

    private var service: SMAppService { .mainApp }

    init() { refresh() }

    var isEnabled: Bool { status == .enabled }
    /// Registered but the user has to allow it in System Settings.
    var needsApproval: Bool { status == .requiresApproval }

    func refresh() {
        status = service.status
    }

    func setEnabled(_ on: Bool) {
        do {
            if on { try service.register() } else { try service.unregister() }
            lastError = nil
            Log.login.notice("launch at login \(on ? "registered" : "unregistered", privacy: .public)")
        } catch {
            lastError = error.localizedDescription
            Log.login.error("launch at login \(on ? "register" : "unregister", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
