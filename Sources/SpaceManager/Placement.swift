import AppKit

struct PlacementSpec: Codable, Equatable {
    enum Preset: String, Codable, CaseIterable {
        case leftHalf, rightHalf, maximized, centered, custom
        var label: String {
            switch self {
            case .leftHalf: return "Left Half"
            case .rightHalf: return "Right Half"
            case .maximized: return "Maximized"
            case .centered: return "Centered"
            case .custom: return "Custom (captured)"
            }
        }
    }
    var preset: Preset = .leftHalf
    /// CG global coordinates (top-left origin) — the space AX and
    /// CGDisplayBounds share. Only read when preset == .custom.
    var customRect: CGRect?
}

enum PlacementGeometry {
    /// AX and CGDisplayBounds share a top-left-origin coordinate space
    /// (AXAttributeConstants.h documents this), so no NSScreen flip exists
    /// anywhere in this feature. The menu-bar inset is a scalar height,
    /// not a coordinate conversion.
    static func targetRect(for spec: PlacementSpec, visible: CGRect) -> CGRect? {
        switch spec.preset {
        case .leftHalf:
            return CGRect(x: visible.minX, y: visible.minY,
                          width: visible.width / 2, height: visible.height)
        case .rightHalf:
            return CGRect(x: visible.midX, y: visible.minY,
                          width: visible.width / 2, height: visible.height)
        case .maximized:
            return visible
        case .centered:
            return visible.insetBy(dx: visible.width * 0.125, dy: visible.height * 0.125)
        case .custom:
            return spec.customRect
        }
    }

    /// Main display bounds minus the menu bar, in CG coordinates.
    static func mainVisibleRect() -> CGRect {
        let display = CGDisplayBounds(CGMainDisplayID())
        let menuBar = NSScreen.main.map { $0.frame.maxY - $0.visibleFrame.maxY } ?? 25
        return CGRect(x: display.minX, y: display.minY + menuBar,
                      width: display.width, height: display.height - menuBar)
    }
}
