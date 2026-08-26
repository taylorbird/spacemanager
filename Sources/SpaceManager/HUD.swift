import AppKit
import SwiftUI

// MARK: - Arrival HUD

final class HUDModel: ObservableObject {
    @Published var item: SpaceItem?
    @Published var total = 1
    @Published var shown = false
}

final class HUDController {
    private let panel: NSPanel
    private let model = HUDModel()
    private let settings: Settings
    private var hideWork: DispatchWorkItem?

    // Panel is a fixed transparent stage; the bezel draws centered inside it.
    private let stageSize = NSSize(width: 640, height: 360)

    init(settings: Settings) {
        self.settings = settings
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: stageSize),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = NSHostingView(rootView: HUDView(model: model, settings: settings))
    }

    func show(item: SpaceItem, total: Int) {
        hideWork?.cancel()
        model.item = item
        model.total = total
        position()
        panel.orderFrontRegardless()
        if !model.shown {
            // Let the panel land on screen before the entrance animation starts.
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.10)) { self.model.shown = true }
            }
        }
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settings.hudDuration + 0.10, execute: work)
    }

    private func hide() {
        withAnimation(.easeIn(duration: 0.20)) { model.shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { [weak self] in
            guard let self, !self.model.shown else { return }
            self.panel.orderOut(nil)
        }
    }

    private func position() {
        guard let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        let origin: NSPoint
        switch settings.hudPosition {
        case .topLeft:
            origin = NSPoint(x: f.minX, y: f.maxY - stageSize.height)
        case .topCenter:
            // visibleFrame.maxY sits just below the menu bar (notch height on
            // notched displays), so the bezel lands right under the notch.
            origin = NSPoint(x: f.midX - stageSize.width / 2, y: f.maxY - stageSize.height)
        case .center:
            origin = NSPoint(x: f.midX - stageSize.width / 2, y: f.midY - stageSize.height / 2)
        case .upperThird:
            origin = NSPoint(x: f.midX - stageSize.width / 2,
                             y: f.minY + f.height * 0.66 - stageSize.height / 2)
        case .bottom:
            origin = NSPoint(x: f.midX - stageSize.width / 2,
                             y: f.minY + f.height * 0.16 - stageSize.height / 2)
        }
        panel.setFrame(NSRect(origin: origin, size: stageSize), display: true)
    }
}

struct HUDView: View {
    @ObservedObject var model: HUDModel
    @ObservedObject var settings: Settings

    var body: some View {
        let topLeft = settings.hudPosition == .topLeft
        let topCenter = settings.hudPosition == .topCenter
        ZStack {
            if let item = model.item {
                content(item)
                    .opacity(model.shown ? 1 : 0)
                    .scaleEffect(settings.hudStyle == .scale ? (model.shown ? 1.0 : 0.86) : 1.0)
                    .offset(y: settings.hudStyle == .slide ? (model.shown ? 0 : -26) : 0)
            }
        }
        .padding(topLeft ? 38 : 0)
        .padding(.top, topCenter ? 10 : 0)
        .frame(width: 640, height: 360,
               alignment: topLeft ? .topLeading : (topCenter ? .top : .center))
    }

    @ViewBuilder
    private func content(_ item: SpaceItem) -> some View {
        switch settings.hudLayout {
        case .pill:
            HStack(spacing: 16) {
                badge(item, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.system(size: 28, weight: .semibold))
                    if settings.hudIndicator {
                        Text("Space \(item.number) of \(model.total)")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 18)
            .padding(.horizontal, 30)
            .background(bezelBackground(item, cornerRadius: 24))

        case .bezel:
            VStack(spacing: 12) {
                badge(item, size: 64)
                Text(item.name).font(.system(size: 20, weight: .semibold))
                if settings.hudIndicator { dots(item) }
            }
            .frame(width: 230)
            .padding(.vertical, 30)
            .background(bezelBackground(item, cornerRadius: 26))
        }
    }

    @ViewBuilder
    private func badge(_ item: SpaceItem, size: CGFloat) -> some View {
        if let emoji = item.emoji {
            Text(emoji).font(.system(size: size))
        } else {
            Text("\(item.number)")
                .font(.system(size: size * 0.6, weight: .bold, design: .rounded))
                .foregroundStyle(item.hasAccent ? item.accentColor : Color.primary.opacity(0.7))
                .frame(width: size * 1.05, height: size * 1.05)
                .background(
                    RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                        .fill(item.accentColor.opacity(0.18))
                )
        }
    }

    private func dots(_ item: SpaceItem) -> some View {
        HStack(spacing: 7) {
            ForEach(0..<model.total, id: \.self) { i in
                Circle()
                    .fill(i == item.index ? item.accentColor : Color.primary.opacity(0.22))
                    .frame(width: 6, height: 6)
            }
        }
    }

    private func bezelBackground(_ item: SpaceItem, cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return shape
            .fill(.ultraThinMaterial)
            .overlay(shape.fill(item.hasAccent ? item.accentColor.opacity(0.14) : .clear))
            .overlay(shape.strokeBorder(Color.white.opacity(0.09)))
            .shadow(color: .black.opacity(0.25), radius: 22, y: 8)
    }
}
