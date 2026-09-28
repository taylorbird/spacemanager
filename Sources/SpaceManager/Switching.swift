import AppKit
import ApplicationServices

/// Space switching = synthesizing the native "Switch to Desktop N" shortcuts
/// (Ctrl+1-9). Durable vs. Dock puppeteering; requires Accessibility trust
/// and the native shortcuts enabled in System Settings.
enum Switching {
    // ANSI virtual key codes for digits 1-9.
    private static let digitKeys: [CGKeyCode] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    static var maxSpaces: Int { digitKeys.count }

    /// 0-based space index for a digit-row key code, or nil if it isn't one.
    /// Callers need this because `charactersIgnoringModifiers` does not ignore
    /// Shift — Shift+1 arrives as "!", so digits have to be read off the key
    /// code instead of the character.
    static func index(forDigitKeyCode code: CGKeyCode) -> Int? {
        digitKeys.firstIndex(of: code)
    }

    @discardableResult
    static func switchTo(index: Int) -> Bool {
        guard AXIsProcessTrusted(), digitKeys.indices.contains(index) else { return false }
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: digitKeys[index], keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: digitKeys[index], keyDown: false)
        else { return false }
        down.flags = .maskControl
        up.flags = .maskControl
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
