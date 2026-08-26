import Foundation
import Combine

enum HUDPosition: String, CaseIterable {
    case topLeft, topCenter, center, upperThird, bottom
    var label: String {
        switch self {
        case .topLeft: return "Top Left"
        case .topCenter: return "Top Center (under notch)"
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

/// App preferences. Reuses the prototype's "proto." HUD keys so tuning
/// choices made there carry straight over.
final class Settings: ObservableObject {
    static let durations: [Double] = [0.3, 0.6, 1.0, 1.5, 2.5]

    @Published var hudDuration: Double { didSet { save() } }
    @Published var hudPosition: HUDPosition { didSet { save() } }
    @Published var hudStyle: HUDStyle { didSet { save() } }
    @Published var hudLayout: HUDLayout { didSet { save() } }
    @Published var hudIndicator: Bool { didSet { save() } }
    /// How long you must stay on a space before on-arrive actions fire.
    @Published var settleSeconds: Double { didSet { save() } }
    /// Apps offered in the switcher's footer, launchable onto the highlighted
    /// space. Seeded; no editor yet.
    @Published var quickLaunch: [QuickLaunchApp] { didSet { save() } }

    private let d = UserDefaults.standard

    init() {
        let dur = d.double(forKey: "proto.hudDuration")
        hudDuration = dur > 0 ? dur : 1.0
        hudPosition = HUDPosition(rawValue: d.string(forKey: "proto.hudPosition") ?? "") ?? .upperThird
        hudStyle = HUDStyle(rawValue: d.string(forKey: "proto.hudStyle") ?? "") ?? .scale
        hudLayout = HUDLayout(rawValue: d.string(forKey: "proto.hudLayout") ?? "") ?? .pill
        hudIndicator = d.object(forKey: "proto.hudIndicator") == nil
            ? true : d.bool(forKey: "proto.hudIndicator")
        let settle = d.double(forKey: "settleSeconds")
        settleSeconds = settle > 0 ? settle : 0.75
        if let data = d.data(forKey: "proto.quickLaunch"),
           let decoded = try? JSONDecoder().decode([QuickLaunchApp].self, from: data) {
            quickLaunch = QuickLaunchApp.normalized(decoded)
        } else {
            quickLaunch = QuickLaunchApp.defaults
        }
    }

    private func save() {
        d.set(hudDuration, forKey: "proto.hudDuration")
        d.set(hudPosition.rawValue, forKey: "proto.hudPosition")
        d.set(hudStyle.rawValue, forKey: "proto.hudStyle")
        d.set(hudLayout.rawValue, forKey: "proto.hudLayout")
        d.set(hudIndicator, forKey: "proto.hudIndicator")
        d.set(settleSeconds, forKey: "settleSeconds")
        if let data = try? JSONEncoder().encode(quickLaunch) {
            d.set(data, forKey: "proto.quickLaunch")
        }
    }
}
