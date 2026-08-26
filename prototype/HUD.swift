import AppKit
import SwiftUI

// MARK: - Arrival HUD

final class HUDModel: ObservableObject {
    @Published var space: FakeSpace?
    @Published var number = 1
    @Published var total = 1
    @Published var shown = false
}

final class HUDController {
    private let panel: NSPanel
    private let model = HUDModel()
    private let settings: HUDSettings
    private var hideWork: DispatchWorkItem?

    // Panel is a fixed transparent stage; the bezel draws centered inside it.
    private let stageSize = NSSize(width: 640, height: 360)

    init(settings: HUDSettings) {
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

    func show(space: FakeSpace, number: Int, total: Int) {
        hideWork?.cancel()
        model.space = space
        model.number = number
        model.total = total
        position()
        panel.orderFrontRegardless()
        if !model.shown {
            // Let the panel land on screen before the entrance animation starts.
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.18)) { self.model.shown = true }
            }
        }
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settings.duration + 0.18, execute: work)
    }

    private func hide() {
        withAnimation(.easeIn(duration: 0.28)) { model.shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in
            guard let self, !self.model.shown else { return }
            self.panel.orderOut(nil)
        }
    }

    private func position() {
        guard let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        let centerY: CGFloat
        switch settings.position {
        case .center: centerY = f.midY
        case .upperThird: centerY = f.minY + f.height * 0.66
        case .bottom: centerY = f.minY + f.height * 0.16
        }
        panel.setFrame(NSRect(x: f.midX - stageSize.width / 2,
                              y: centerY - stageSize.height / 2,
                              width: stageSize.width, height: stageSize.height),
                       display: true)
    }
}

struct HUDView: View {
    @ObservedObject var model: HUDModel
    @ObservedObject var settings: HUDSettings

    var body: some View {
        ZStack {
            if let space = model.space {
                content(space)
                    .opacity(model.shown ? 1 : 0)
                    .scaleEffect(settings.style == .scale ? (model.shown ? 1.0 : 0.86) : 1.0)
                    .offset(y: settings.style == .slide ? (model.shown ? 0 : -26) : 0)
            }
        }
        .frame(width: 640, height: 360)
    }

    @ViewBuilder
    private func content(_ space: FakeSpace) -> some View {
        let name = space.displayName(number: model.number)
        switch settings.layout {
        case .pill:
            HStack(spacing: 14) {
                badge(space, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.system(size: 24, weight: .semibold))
                    if settings.showIndicator {
                        Text("Space \(model.number) of \(model.total)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 26)
            .background(bezelBackground(space, cornerRadius: 22))

        case .bezel:
            VStack(spacing: 12) {
                badge(space, size: 64)
                Text(name).font(.system(size: 20, weight: .semibold))
                if settings.showIndicator { dots }
            }
            .frame(width: 230)
            .padding(.vertical, 30)
            .background(bezelBackground(space, cornerRadius: 26))
        }
    }

    @ViewBuilder
    private func badge(_ space: FakeSpace, size: CGFloat) -> some View {
        if let emoji = space.emoji {
            Text(emoji).font(.system(size: size))
        } else {
            Text("\(model.number)")
                .font(.system(size: size * 0.6, weight: .bold, design: .rounded))
                .foregroundStyle(space.hasAccent ? space.accentColor : Color.primary.opacity(0.7))
                .frame(width: size * 1.05, height: size * 1.05)
                .background(
                    RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                        .fill(space.accentColor.opacity(0.18))
                )
        }
    }

    private var dots: some View {
        HStack(spacing: 7) {
            ForEach(0..<model.total, id: \.self) { i in
                Circle()
                    .fill(i == model.number - 1
                          ? (model.space?.accentColor ?? .primary)
                          : Color.primary.opacity(0.22))
                    .frame(width: 6, height: 6)
            }
        }
    }

    private func bezelBackground(_ space: FakeSpace, cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return shape
            .fill(.ultraThinMaterial)
            .overlay(shape.fill(space.hasAccent ? space.accentColor.opacity(0.14) : .clear))
            .overlay(shape.strokeBorder(Color.white.opacity(0.09)))
            .shadow(color: .black.opacity(0.25), radius: 22, y: 8)
    }
}
