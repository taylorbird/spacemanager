import AppKit
import ApplicationServices

/// Flashes the HUD at the moment Ctrl+Left/Right is pressed, predicting the
/// destination, instead of waiting for the space-change notification that
/// only fires after the slide animation lands. Listen-only CGEvent tap
/// (public API); requires the Accessibility trust the app already has for
/// switching. If the tap can't be created, the feature silently stays off
/// and the HUD still shows on arrival.
final class TraversalPeek {
    /// Direction of the traversal keypress: -1 (left) or +1 (right).
    var onPeek: ((Int) -> Void)?
    /// A Ctrl+digit press (user's own, or synthesized by our switcher/menu):
    /// 0-based space index. Fires the HUD instantly for direct jumps too.
    var onDigit: ((Int) -> Void)?

    // ANSI digit keycode → 0-based space index (Ctrl+1 ... Ctrl+9).
    private static let digitIndex: [Int64: Int] = [
        18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8,
    ]

    private var tap: CFMachPort?

    func startIfPossible() {
        guard tap == nil, AXIsProcessTrusted() else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                if let userInfo {
                    let peek = Unmanaged<TraversalPeek>.fromOpaque(userInfo).takeUnretainedValue()
                    peek.handle(type: type, event: event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: userInfo
        )
        guard let tap else { return }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type == .keyDown else { return }
        let flags = event.flags
        guard flags.contains(.maskControl),
              !flags.contains(.maskCommand),
              !flags.contains(.maskAlternate) else { return }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if keyCode == 123 || keyCode == 124 { // Left / Right
            let direction = keyCode == 124 ? 1 : -1
            DispatchQueue.main.async { [weak self] in self?.onPeek?(direction) }
        } else if let index = Self.digitIndex[keyCode] {
            DispatchQueue.main.async { [weak self] in self?.onDigit?(index) }
        }
    }
}
