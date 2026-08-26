import AppKit
import SwiftUI

struct SpaceMeta: Codable, Equatable {
    var name: String?
    var emoji: String?
    var accent: String? // Palette key, so colors adapt to appearance changes

    var isEmpty: Bool { name == nil && emoji == nil && accent == nil }
}

enum Palette {
    static let ordered: [(key: String, label: String, color: NSColor)] = [
        ("blue", "Blue", .systemBlue),
        ("purple", "Purple", .systemPurple),
        ("pink", "Pink", .systemPink),
        ("red", "Red", .systemRed),
        ("orange", "Orange", .systemOrange),
        ("yellow", "Yellow", .systemYellow),
        ("green", "Green", .systemGreen),
        ("teal", "Teal", .systemTeal),
    ]

    static func color(_ key: String?) -> Color? {
        guard let key else { return nil }
        return ordered.first { $0.key == key }.map { Color(nsColor: $0.color) }
    }

    /// Auto-assignment order hops across the color wheel so neighboring
    /// spaces never get near-identical hues (spectrum order put pink next
    /// to red). The picker keeps `ordered` (spectrum) for its swatches.
    private static let autoKeys = ["blue", "orange", "purple", "green", "red", "teal", "yellow", "pink"]

    /// Auto-assigned accent for spaces without an explicit color choice:
    /// cycles the palette by position, so up to 8 spaces get distinct colors.
    static func autoColor(for index: Int) -> Color {
        let key = autoKeys[index % autoKeys.count]
        return color(key) ?? Color(nsColor: .systemBlue)
    }
}

/// UUID-keyed space metadata. Names survive space reordering because the key
/// is the space UUID, not the position. Stored in UserDefaults per the
/// no-config-files constraint.
final class MetadataStore: ObservableObject {
    @Published private(set) var byUUID: [String: SpaceMeta] = [:]
    /// Session-only cache: app name observed while visiting a full-screen
    /// space (public API can't map windows to other spaces).
    @Published private(set) var fullScreenLabels: [String: String] = [:]

    private static let key = "spaceMetadata"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([String: SpaceMeta].self, from: data) {
            byUUID = decoded
        }
    }

    func meta(for uuid: String) -> SpaceMeta {
        byUUID[uuid] ?? SpaceMeta()
    }

    func update(_ meta: SpaceMeta, for uuid: String) {
        if meta.isEmpty {
            byUUID.removeValue(forKey: uuid)
        } else {
            byUUID[uuid] = meta
        }
        persist()
    }

    func noteFullScreenApp(_ appName: String, for uuid: String) {
        guard fullScreenLabels[uuid] != appName else { return }
        fullScreenLabels[uuid] = appName
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(byUUID) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
