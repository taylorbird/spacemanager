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
    /// space. Seeded; edited in Preferences.
    @Published var quickLaunch: [QuickLaunchApp] { didSet { save() } }
    /// Master switches. Off = quick-launch behaves exactly as before this
    /// feature existed (⌘N / plain cold launch, no window moving) — the off
    /// state is the escape hatch for machines where AX side effects matter.
    @Published var chromeProfilesEnabled: Bool { didSet { save() } }
    @Published var windowPlacementEnabled: Bool { didSet { save() } }
    /// Off = the switcher's "Move ‹app› window here" row never appears and no
    /// focused window is captured when the switcher opens.
    @Published var moveWindowEnabled: Bool { didSet { save() } }
    /// Snapshot of Chrome's profile list, taken only when the user clicks
    /// Refresh in Preferences (reading Chrome's folder is TCC-gated). Every
    /// runtime caller uses this, never a live read.
    @Published var chromeProfiles: [ChromeProfiles.Profile] { didSet { save() } }

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
        chromeProfilesEnabled = d.object(forKey: "quickLaunchProfilesEnabled") == nil
            ? true : d.bool(forKey: "quickLaunchProfilesEnabled")
        windowPlacementEnabled = d.object(forKey: "quickLaunchPlacementEnabled") == nil
            ? true : d.bool(forKey: "quickLaunchPlacementEnabled")
        moveWindowEnabled = d.object(forKey: "moveWindowEnabled") == nil
            ? true : d.bool(forKey: "moveWindowEnabled")
        if let data = d.data(forKey: "chromeProfiles"),
           let decoded = try? JSONDecoder().decode([ChromeProfiles.Profile].self, from: data) {
            chromeProfiles = decoded
        } else {
            chromeProfiles = []
        }
    }

    /// The one place Chrome's Local State is read. An empty read (denied,
    /// Chrome missing) leaves the existing snapshot untouched.
    func refreshChromeProfiles() {
        let fresh = ChromeProfiles.load()
        guard !fresh.isEmpty else {
            Log.chrome.notice("refresh found no profiles; keeping snapshot of \(self.chromeProfiles.count, privacy: .public)")
            return
        }
        chromeProfiles = ChromeProfiles.merge(existing: chromeProfiles, fresh: fresh)
        Log.chrome.notice("refresh stored \(self.chromeProfiles.count, privacy: .public) profiles")
    }

    /// Guard against launching with a stale directory name: Chrome silently
    /// CREATES a junk profile for an unknown --profile-directory value.
    func chromeProfileExists(_ directory: String) -> Bool {
        chromeProfiles.contains { $0.directory == directory }
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
        d.set(chromeProfilesEnabled, forKey: "quickLaunchProfilesEnabled")
        d.set(windowPlacementEnabled, forKey: "quickLaunchPlacementEnabled")
        d.set(moveWindowEnabled, forKey: "moveWindowEnabled")
        if let data = try? JSONEncoder().encode(chromeProfiles) {
            d.set(data, forKey: "chromeProfiles")
        }
    }
}
