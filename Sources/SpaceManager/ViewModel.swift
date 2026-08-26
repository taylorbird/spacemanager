import AppKit
import Combine
import SwiftUI

/// One space as the UI sees it: engine state resolved through metadata.
struct SpaceItem: Identifiable, Equatable {
    let uuid: String
    let index: Int // 0-based position on the main display (Mission Control order)
    let name: String
    let emoji: String?
    let accent: Color?
    let isFullScreen: Bool

    var id: String { uuid }
    var number: Int { index + 1 }
    var accentColor: Color { accent ?? .secondary }
    var hasAccent: Bool { accent != nil }
    var menuLabel: String { emoji.map { "\($0)  \(name)" } ?? name }
}

final class SpacesViewModel: ObservableObject {
    @Published private(set) var items: [SpaceItem] = []
    @Published private(set) var currentIndex = 0
    @Published private(set) var previousIndex = 0

    /// Set by the app delegate; performs (or refuses) a real space switch.
    var requestSwitch: ((Int) -> Void)?

    let engine: SpaceEngine
    let metadata: MetadataStore
    private var cancellables = Set<AnyCancellable>()

    init(engine: SpaceEngine, metadata: MetadataStore) {
        self.engine = engine
        self.metadata = metadata
        rebuild()
        engine.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.rebuild() }
            .store(in: &cancellables)
        metadata.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.rebuild() }
            .store(in: &cancellables)
    }

    var current: SpaceItem? {
        items.indices.contains(currentIndex) ? items[currentIndex] : nil
    }

    func item(for uuid: String) -> SpaceItem? {
        items.first { $0.uuid == uuid }
    }

    func rebuild() {
        guard let display = engine.mainDisplay else {
            items = []
            return
        }
        items = display.spaces.enumerated().map { i, s in
            let meta = metadata.meta(for: s.uuid)
            // Unverified assumption (flagged in questions.md): full-screen
            // spaces have type != 0. All observed normal spaces are type 0.
            let isFS = s.type != 0
            let defaultName = isFS
                ? (metadata.fullScreenLabels[s.uuid] ?? "Full Screen")
                : "Desktop \(i + 1)"
            return SpaceItem(uuid: s.uuid,
                             index: i,
                             name: meta.name ?? defaultName,
                             emoji: meta.emoji,
                             accent: Palette.color(meta.accent) ?? Palette.autoColor(for: i),
                             isFullScreen: isFS)
        }
        currentIndex = items.firstIndex { $0.uuid == engine.currentUUID } ?? 0
        previousIndex = items.firstIndex { $0.uuid == engine.previousUUID } ?? currentIndex
    }
}
