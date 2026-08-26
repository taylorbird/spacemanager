import AppKit
import SwiftUI

// MARK: - Fake space model

struct FakeSpace: Identifiable {
    let id = UUID()
    var customName: String?
    var emoji: String?
    var accent: NSColor?
    var isFullScreen = false
    var fullScreenApp: String?
    var appSymbols: [String] = []

    // Unnamed spaces mirror macOS defaults: "Desktop N" positionally,
    // app name for full-screen spaces (constraint 2026-08-11).
    func displayName(number: Int) -> String {
        if let name = customName { return name }
        if isFullScreen, let app = fullScreenApp { return app }
        return "Desktop \(number)"
    }

    var accentColor: Color { accent.map(Color.init) ?? Color.secondary }
    var hasAccent: Bool { accent != nil }
}

enum FakeData {
    static let spaces: [FakeSpace] = [
        FakeSpace(customName: "Comms", emoji: "📥", accent: .systemBlue,
                  appSymbols: ["envelope.fill", "message.fill", "calendar"]),
        FakeSpace(customName: "Code", emoji: "💻", accent: .systemPurple,
                  appSymbols: ["terminal.fill", "hammer.fill", "safari.fill"]),
        FakeSpace(customName: "Design", emoji: "🎨", accent: .systemPink,
                  appSymbols: ["paintpalette.fill", "photo.fill"]),
        FakeSpace(appSymbols: ["folder.fill"]), // unnamed -> "Desktop 4"
        FakeSpace(customName: "Music", emoji: "🎧", accent: .systemGreen,
                  appSymbols: ["music.note"]),
        FakeSpace(isFullScreen: true, fullScreenApp: "Safari",
                  appSymbols: ["safari.fill"]),
    ]
}

// MARK: - Store (fake switching)

final class SpaceStore: ObservableObject {
    @Published var spaces: [FakeSpace]
    @Published var currentIndex: Int = 0
    @Published var previousIndex: Int = 1

    /// Called after a fake switch lands; drives the arrival HUD.
    var onSwitch: ((FakeSpace, Int) -> Void)?

    init(spaces: [FakeSpace]) {
        self.spaces = spaces
    }

    var current: FakeSpace { spaces[currentIndex] }

    func switchTo(_ index: Int) {
        guard spaces.indices.contains(index), index != currentIndex else { return }
        previousIndex = currentIndex
        currentIndex = index
        onSwitch?(spaces[index], index)
    }
}

// MARK: - HUD tuning settings (the knobs this prototype exists to answer)

enum HUDPosition: String, CaseIterable {
    case center, upperThird, bottom
    var label: String {
        switch self {
        case .center: return "Center"
        case .upperThird: return "Upper Third"
        case .bottom: return "Bottom (native bezel)"
        }
    }
}

enum HUDStyle: String, CaseIterable {
    case fade, scale, slide
    var label: String {
        switch self {
        case .fade: return "Fade"
        case .scale: return "Scale"
        case .slide: return "Slide Down"
        }
    }
}

enum HUDLayout: String, CaseIterable {
    case pill, bezel
    var label: String {
        switch self {
        case .pill: return "Pill (horizontal)"
        case .bezel: return "Bezel (square)"
        }
    }
}

final class HUDSettings: ObservableObject {
    static let durations: [Double] = [0.6, 1.0, 1.5, 2.5]

    @Published var duration: Double { didSet { save() } }
    @Published var position: HUDPosition { didSet { save() } }
    @Published var style: HUDStyle { didSet { save() } }
    @Published var layout: HUDLayout { didSet { save() } }
    @Published var showIndicator: Bool { didSet { save() } }

    private let d = UserDefaults.standard

    init() {
        let stored = d.double(forKey: "proto.hudDuration")
        duration = stored > 0 ? stored : 1.0
        position = HUDPosition(rawValue: d.string(forKey: "proto.hudPosition") ?? "") ?? .upperThird
        style = HUDStyle(rawValue: d.string(forKey: "proto.hudStyle") ?? "") ?? .scale
        layout = HUDLayout(rawValue: d.string(forKey: "proto.hudLayout") ?? "") ?? .pill
        showIndicator = d.object(forKey: "proto.hudIndicator") == nil
            ? true : d.bool(forKey: "proto.hudIndicator")
    }

    private func save() {
        d.set(duration, forKey: "proto.hudDuration")
        d.set(position.rawValue, forKey: "proto.hudPosition")
        d.set(style.rawValue, forKey: "proto.hudStyle")
        d.set(layout.rawValue, forKey: "proto.hudLayout")
        d.set(showIndicator, forKey: "proto.hudIndicator")
    }
}
