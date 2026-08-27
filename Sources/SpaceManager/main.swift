import AppKit
import Carbon.HIToolbox

// SpaceManager — native menu bar app augmenting macOS Spaces.
// Private-API surface: SLSCopyManagedDisplaySpaces only (see SkyLight.swift).

private var hotKeyRefs: [EventHotKeyRef?] = []
private var hotKeyAction: (() -> Void)?

// Switcher hotkey: Ctrl+Option+Cmd+? — registered with and without shift so the
// shift for "?" doesn't matter. (Decision 2026-08-24, supersedes Ctrl+?.)
private func registerSwitcherHotKey(_ action: @escaping () -> Void) {
    hotKeyAction = action
    var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                  eventKind: OSType(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
        DispatchQueue.main.async { hotKeyAction?() }
        return noErr
    }, 1, &eventType, nil, nil)
    let base = controlKey | optionKey | cmdKey
    for (id, modifiers) in [(1, base), (2, base | shiftKey)] {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: 0x53504D47, id: UInt32(id)) // 'SPMG'
        RegisterEventHotKey(UInt32(kVK_ANSI_Slash), UInt32(modifiers), hotKeyID,
                            GetApplicationEventTarget(), 0, &ref)
        hotKeyRefs.append(ref)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = Settings()
    let metadata = MetadataStore()
    let actionsStore = ActionsStore()
    let runner = ActionRunner()
    let setupStatus = SetupStatus()
    let peek = TraversalPeek()
    let previews = PreviewStore()
    /// Last predicted destination during a Ctrl+arrow traversal; reset on landing.
    private var peekIndex: Int?
    /// Prevents preview captures from piling up during rapid switching —
    /// SCShareableContent enumeration is slow enough to queue otherwise.
    private var captureInFlight = false

    var engine: SpaceEngine!
    var viewModel: SpacesViewModel!
    var hud: HUDController!
    var switcher: SwitcherController!
    var statusBar: StatusBarController!
    var scheduler: ArrivalScheduler!
    var quickLauncher: QuickLauncher!
    var editController: SpaceEditController!
    var actionsEditor: ActionsEditorController!
    var preferences: PreferencesController!
    var setupGuide: SetupGuideController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let engine = SpaceEngine() else {
            let alert = NSAlert()
            alert.messageText = "SpaceManager can't read Spaces"
            alert.informativeText = "SLSCopyManagedDisplaySpaces is unavailable on this macOS build. The app cannot run."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        self.engine = engine

        viewModel = SpacesViewModel(engine: engine, metadata: metadata)
        hud = HUDController(settings: settings)
        quickLauncher = QuickLauncher(settings: settings, viewModel: viewModel)
        switcher = SwitcherController(viewModel: viewModel, previews: previews, metadata: metadata,
                                      settings: settings, launcher: quickLauncher)
        scheduler = ArrivalScheduler(settings: settings, store: actionsStore, runner: runner)
        editController = SpaceEditController(metadata: metadata)
        actionsEditor = ActionsEditorController(viewModel: viewModel, store: actionsStore, settings: settings)
        preferences = PreferencesController(settings: settings)
        setupGuide = SetupGuideController(status: setupStatus, viewModel: viewModel)

        statusBar = StatusBarController(
            viewModel: viewModel,
            settings: settings,
            actionsStore: actionsStore,
            setupStatus: setupStatus,
            handlers: .init(
                toggleSwitcher: { [weak self] in self?.switcher.toggle() },
                replayHUD: { [weak self] in self?.showHUDForCurrent() },
                editSpace: { [weak self] item in self?.editController.edit(item: item) },
                editActions: { [weak self] in self?.actionsEditor.show() },
                openPreferences: { [weak self] in self?.preferences.show() },
                openSetup: { [weak self] in self?.setupGuide.show() },
                runAction: { [weak self] action in self?.runner.runManually(action) }
            )
        )

        // Real arrivals: HUD + on-arrive actions + full-screen label capture.
        engine.onArrive = { [weak self] info, index in
            guard let self else { return }
            self.peekIndex = nil
            self.peek.startIfPossible() // retries after AX gets granted
            self.viewModel.rebuild()
            if let item = self.viewModel.item(for: info.uuid) {
                self.hud.show(item: item, total: self.viewModel.items.count)
            }
            self.scheduler.arrived(at: info.uuid)
            self.quickLauncher.arrived(at: info.uuid)
            self.capturePreviewSoon(for: info.uuid)
            if info.type != 0 {
                // Full-screen space: the frontmost app IS the space's app.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    if let name = NSWorkspace.shared.frontmostApplication?.localizedName {
                        self?.metadata.noteFullScreenApp(name, for: info.uuid)
                    }
                }
            }
        }

        // Switching: real keystroke synthesis, or the setup guide if blocked.
        viewModel.requestSwitch = { [weak self] index in
            guard let self, index != self.viewModel.currentIndex else { return }
            self.setupStatus.recheck()
            guard self.setupStatus.canSwitch(toIndex: index), Switching.switchTo(index: index) else {
                self.setupGuide.show()
                return
            }
        }

        // Traversal peek: flash the predicted destination the instant
        // Ctrl+Left/Right is pressed, instead of waiting for the landing.
        peek.onPeek = { [weak self] direction in
            guard let self, !self.switcher.isOpen else { return }
            let count = self.viewModel.items.count
            guard count > 0 else { return }
            let base = self.peekIndex ?? self.viewModel.currentIndex
            let target = min(max(base + direction, 0), count - 1)
            guard target != base else { return } // at the edge: no switch will happen
            self.peekIndex = target
            self.hud.show(item: self.viewModel.items[target], total: count)
        }
        // Ctrl+digit — the user's own presses AND the ones we synthesize for
        // switcher/menu switches — flashes the destination instantly too.
        peek.onDigit = { [weak self] index in
            guard let self, !self.switcher.isOpen else { return }
            guard self.viewModel.items.indices.contains(index),
                  index != (self.peekIndex ?? self.viewModel.currentIndex) else { return }
            self.peekIndex = index
            self.hud.show(item: self.viewModel.items[index], total: self.viewModel.items.count)
        }
        peek.startIfPossible()

        registerSwitcherHotKey { [weak self] in self?.switcher.toggle() }

        // Switcher tile previews: one-time Screen Recording prompt, then
        // capture the launch space once things settle.
        ScreenCapture.requestIfNeeded()
        if let uuid = engine.currentUUID { capturePreviewSoon(for: uuid) }

        // First-run: surface the setup guide if switching isn't possible yet.
        if !setupStatus.isReady(spaceCount: viewModel.items.count) {
            setupGuide.show()
        }
    }

    /// Screenshot the space ~0.7s after arriving (post-transition, HUD gone),
    /// so tiles show each space as of the last visit. Skipped if you've
    /// already moved on by then.
    private func capturePreviewSoon(for uuid: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self, self.engine.currentUUID == uuid, !self.captureInFlight else { return }
            self.captureInFlight = true
            Task { @MainActor [weak self] in
                defer { self?.captureInFlight = false }
                guard let self, self.engine.currentUUID == uuid else { return }
                if let image = await ScreenCapture.captureMainDisplay() {
                    self.previews.set(image, for: uuid)
                }
            }
        }
    }

    private func showHUDForCurrent() {
        if let current = viewModel.current {
            hud.show(item: current, total: viewModel.items.count)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
