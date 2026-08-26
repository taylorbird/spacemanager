import AppKit

struct SpaceAction: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case app, shell
        var label: String {
            switch self {
            case .app: return "Open App"
            case .shell: return "Shell Command"
            }
        }
    }

    var id = UUID()
    var title = ""
    var kind: Kind = .app
    /// App: full path to the .app bundle. Shell: the command line.
    var target = ""
    var onArrive = false
    /// Only meaningful when onArrive: fire every visit (false) or once per
    /// app session (true). Default per decision 2026-08-20: every visit.
    var oncePerSession = false

    var displayTitle: String {
        if !title.isEmpty { return title }
        if kind == .app { return (target as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "") }
        return target
    }
}

/// Per-space actions, keyed by space UUID. UserDefaults per the
/// no-config-files constraint; edited only through the in-app editor.
final class ActionsStore: ObservableObject {
    @Published private(set) var byUUID: [String: [SpaceAction]] = [:]

    private static let key = "spaceActions"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([String: [SpaceAction]].self, from: data) {
            byUUID = decoded
        }
    }

    func actions(for uuid: String) -> [SpaceAction] {
        byUUID[uuid] ?? []
    }

    func set(_ actions: [SpaceAction], for uuid: String) {
        if actions.isEmpty {
            byUUID.removeValue(forKey: uuid)
        } else {
            byUUID[uuid] = actions
        }
        if let data = try? JSONEncoder().encode(byUUID) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

final class ActionRunner {
    private var firedThisSession = Set<UUID>()

    func runManually(_ action: SpaceAction) {
        run(action)
    }

    func runOnArrive(actions: [SpaceAction]) {
        for action in actions where action.onArrive {
            if action.oncePerSession {
                guard !firedThisSession.contains(action.id) else { continue }
                firedThisSession.insert(action.id)
            }
            run(action)
        }
    }

    private func run(_ action: SpaceAction) {
        switch action.kind {
        case .app:
            let url = URL(fileURLWithPath: action.target)
            NSWorkspace.shared.openApplication(at: url,
                                               configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        case .shell:
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", action.target]
            try? process.run()
        }
    }
}

/// Debounces on-arrive actions: they fire only after you've stayed on the
/// space for the settle interval, so rapid flipping doesn't trigger spaces
/// you passed through.
final class ArrivalScheduler {
    private let settings: Settings
    private let store: ActionsStore
    private let runner: ActionRunner
    private var pending: DispatchWorkItem?

    init(settings: Settings, store: ActionsStore, runner: ActionRunner) {
        self.settings = settings
        self.store = store
        self.runner = runner
    }

    func arrived(at uuid: String) {
        pending?.cancel()
        let actions = store.actions(for: uuid)
        guard actions.contains(where: { $0.onArrive }) else { return }
        let work = DispatchWorkItem { [runner] in
            runner.runOnArrive(actions: actions)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settings.settleSeconds, execute: work)
    }
}
