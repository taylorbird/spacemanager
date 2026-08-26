import AppKit
import ApplicationServices

/// Tracks the two system-level requirements for switching:
/// Accessibility trust, and the native "Switch to Desktop N" shortcuts
/// (symbolic hotkeys 118-126; absent from the plist = never enabled).
final class SetupStatus: ObservableObject {
    @Published private(set) var axTrusted = AXIsProcessTrusted()
    @Published private(set) var enabledDesktopShortcuts: Set<Int> = []

    init() { recheck() }

    func recheck() {
        axTrusted = AXIsProcessTrusted()
        enabledDesktopShortcuts = Self.readEnabledShortcuts()
    }

    func canSwitch(toIndex index: Int) -> Bool {
        axTrusted && enabledDesktopShortcuts.contains(index + 1)
    }

    func isReady(spaceCount: Int) -> Bool {
        guard axTrusted else { return false }
        let needed = min(spaceCount, Switching.maxSpaces)
        return (1...max(needed, 1)).allSatisfy { enabledDesktopShortcuts.contains($0) }
    }

    /// Triggers the one-time system Accessibility prompt.
    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Desktop numbers (1-9) whose "Switch to Desktop N" shortcut is enabled.
    private static func readEnabledShortcuts() -> Set<Int> {
        guard let hotkeys = UserDefaults(suiteName: "com.apple.symbolichotkeys")?
            .dictionary(forKey: "AppleSymbolicHotKeys") else { return [] }
        var enabled = Set<Int>()
        for n in 1...9 {
            // Symbolic hotkey IDs: 118 = Switch to Desktop 1, ..., 126 = Desktop 9.
            guard let entry = hotkeys["\(117 + n)"] as? [String: Any] else { continue }
            let flag = (entry["enabled"] as? NSNumber)?.boolValue ?? false
            if flag { enabled.insert(n) }
        }
        return enabled
    }
}
