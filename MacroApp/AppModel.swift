import Combine
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var destination: SidebarDestination? = .macros
    @Published var macros: [MacroDefinition] = [] {
        didSet { scheduleLibraryPersistence() }
    }
    @Published var selectedMacroID: UUID?
    @Published var selectedTarget: TargetWindow?
    @Published var availableTargets: [TargetWindow] = []
    @Published var isRefreshingTargets = false
    @Published var targetDiscoveryMessage = "Window discovery has not run yet."
    @Published private(set) var activity: AppActivity = .idle
    @Published private(set) var playbackProgress: PlaybackProgress?
    @Published var recordedActionCount = 0
    @Published private(set) var recordingStartedAt: Date?
    @Published var recordingResultMessage: String?
    @Published var diagnosticMessage = "Select a target, then send a test input."
    @Published var diagnosticAction: TestInputAction = .pressE
    @Published var alertMessage: String?
    @Published private(set) var hotkeys = HotkeyPreferences()
    @Published private(set) var hotkeyRegistrationMessage = "Global hotkeys are active."
    @Published var logs: [LogEntry] = [
        LogEntry(date: .now, level: .info, message: "Macro is ready. Select a target to begin setup.")
    ]

    let permissionManager: PermissionManager
    let automationStore: AutomationStore

    private let targetManager: any TargetDiscovering
    private let storage: any MacroStoring
    private let engine = MacroEngine()
    private let simpleEngine = SimplePlaybackEngine()
    private let recorder = MacroRecorder()
    private let emergencyMonitor = EmergencyStopMonitor()
    private let hotkeyManager = GlobalHotkeyManager()
    private let backgroundInputBackend: any InputBackend = TargetedCGEventBackend(mousePlaybackMode: .background)
    private let compatibilityInputBackend: any InputBackend = TargetedCGEventBackend(mousePlaybackMode: .compatibility)
    private let hotkeyDefaultsKey = "GlobalHotkeyPreferences"
    private var persistenceTask: Task<Void, Never>?
    private var playbackPreparationID: UUID?
    private var targetNeedsReselection = false
    private var recordingCountdownTimer: DispatchSourceTimer?
    private var automationObservation: AnyCancellable?
    private lazy var automationEngine = AutomationEngine(
        store: automationStore,
        macroResolver: { [weak self] id in self?.macros.first { $0.id == id } },
        targetResolver: { [weak self] node, macro in self?.automationTarget(for: node, macro: macro) },
        backendResolver: { [weak self] mode in
            guard let self else { return TargetedCGEventBackend(mousePlaybackMode: mode) }
            return self.inputBackend(for: mode)
        },
        windowResolver: { [weak self] in
            guard let self else { return [] }
            return (try? self.targetManager.discoverWindows()) ?? []
        },
        permissionCheck: { [weak self] in
            self?.permissionManager.refresh()
            return self?.permissionManager.accessibilityGranted == true
        },
        logger: { [weak self] message, level in self?.log(message, level: level) }
    )

    var runState: RunState {
        switch automationStore.runState {
        case .running: .running
        case .paused: .paused
        case .idle: activity.runState
        }
    }
    var recording: Bool { activity.isRecording }
    var recordingCountdown: Int? { activity.countdownValue }
    var activityLabel: String {
        if automationStore.runState != .idle {
            let nodeName = automationStore.activeNodeID
                .flatMap { id in automationStore.selectedAutomation?.nodes.first { $0.id == id } }
                .map(automationNodeTitle)
            return nodeName.map { "\(automationStore.runState.rawValue) · \($0)" }
                ?? automationStore.runState.rawValue
        }
        return switch activity {
        case .idle: "Ready"
        case .recordingCountdown(let seconds): "Recording starts in \(seconds)"
        case .recording: "Recording \(recordedActionCount) actions"
        case .preparingPlayback: "Preparing playback"
        case .playing: playbackProgress.map { "Running · \($0.label)" } ?? "Running"
        case .paused: playbackProgress.map { "Paused · \($0.label)" } ?? "Paused"
        }
    }

    var canStart: Bool {
        activity == .idle && automationStore.runState == .idle
            && selectedMacroIndex.map { !macros[$0].actions.isEmpty } == true
    }
    var canStartAutomation: Bool {
        activity == .idle
            && automationStore.runState == .idle
            && automationStore.canRun(availableMacroIDs: Set(macros.map(\.id)))
    }
    var canPause: Bool {
        automationStore.runState != .idle || activity == .playing || activity == .paused
    }
    var canStop: Bool { activity != .idle || automationStore.runState != .idle }

    private func inputBackend(for mode: MousePlaybackMode) -> any InputBackend {
        switch mode {
        case .background: backgroundInputBackend
        case .compatibility: compatibilityInputBackend
        }
    }

    var selectedMacroIndex: Int? {
        macros.firstIndex { $0.id == selectedMacroID }
    }

    var selectedMacro: MacroDefinition? {
        guard let index = selectedMacroIndex else { return nil }
        return macros[index]
    }

    init(
        targetManager: any TargetDiscovering = TargetManager(),
        storage: any MacroStoring = MacroStorage(),
        automationStorage: any AutomationStoring = AutomationStorage(),
        permissionManager: PermissionManager? = nil
    ) {
        self.targetManager = targetManager
        self.storage = storage
        self.automationStore = AutomationStore(storage: automationStorage)
        self.permissionManager = permissionManager ?? PermissionManager()

        if let data = UserDefaults.standard.data(forKey: hotkeyDefaultsKey),
           let saved = try? JSONDecoder().decode(HotkeyPreferences.self, from: data) {
            hotkeys = saved
        }

        do {
            let saved = try storage.loadLibrary()
            if !saved.isEmpty { macros = saved }
        } catch {
            logs.append(LogEntry(date: .now, level: .error, message: "Could not load macro library: \(error.localizedDescription)"))
        }
        selectedMacroID = macros.first?.id
        automationObservation = automationStore.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }

        engine.onStateChange = { [weak self] state in self?.handleEngineState(state) }
        engine.onLog = { [weak self] message, level in self?.log(message, level: level) }
        engine.onProgress = { [weak self] progress in self?.playbackProgress = progress }
        simpleEngine.onStateChange = { [weak self] state in self?.handleEngineState(state) }
        simpleEngine.onLog = { [weak self] message, level in self?.log(message, level: level) }
        simpleEngine.onProgress = { [weak self] progress in self?.playbackProgress = progress }
        recorder.onActionCountChange = { [weak self] count in
            self?.recordedActionCount = count
        }
        installEmergencyStopMonitor()
        configureHotkeys()
    }

    func createMacro() {
        let macro = MacroDefinition(name: "Untitled Macro", actions: [])
        macros.append(macro)
        selectedMacroID = macro.id
        destination = .macros
        log("Created \(macro.name)")
    }

    func duplicateSelectedMacro() {
        guard let index = selectedMacroIndex else { return }
        var copy = macros[index]
        copy.id = UUID()
        copy.actions = copy.actions.map { action in
            var action = action
            action.id = UUID()
            return action
        }
        copy.isFavorite = false
        copy.name += " Copy"
        macros.append(copy)
        selectedMacroID = copy.id
        log("Duplicated macro as \(copy.name)")
    }

    func renameMacro(id: UUID, to name: String) {
        guard let index = macros.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        macros[index].name = trimmed
        selectedMacroID = id
        log("Renamed recording to \(trimmed)")
    }

    func toggleFavoriteMacro(id: UUID) {
        guard let index = macros.firstIndex(where: { $0.id == id }) else { return }
        macros[index].isFavorite.toggle()
    }

    func deleteSelectedMacro() {
        guard let index = selectedMacroIndex else { return }
        let name = macros[index].name
        macros.remove(at: index)
        selectedMacroID = macros.first?.id
        log("Deleted \(name)")
    }

    func addAction(_ type: MacroActionType) {
        guard let index = selectedMacroIndex else { return }
        let action: MacroAction
        switch type {
        case .wait: action = MacroAction(type: type, key: nil, duration: 1)
        case .holdKey: action = MacroAction(type: type, key: "w", duration: 1)
        case .keyDown, .keyUp, .keyPress: action = MacroAction(type: type, key: "e", duration: 0.1)
        case .move: action = MacroAction(type: type, key: nil, duration: 0, x: 100, y: 100)
        case .scroll: action = MacroAction(type: type, key: nil, duration: 0, x: 100, y: 100, scrollDeltaY: -100)
        default: action = MacroAction(type: type, key: nil, duration: 0.05, x: 100, y: 100)
        }
        macros[index].actions.append(action)
    }

    func removeActions(at offsets: IndexSet) {
        guard let index = selectedMacroIndex else { return }
        macros[index].actions.remove(atOffsets: offsets)
    }

    func saveLibrary() { scheduleLibraryPersistence(silent: false, debounce: false) }

    func reloadLibrary() {
        do {
            let saved = try storage.loadLibrary()
            macros = saved
            selectedMacroID = macros.first?.id
            log("Loaded \(macros.count) macros from disk")
        } catch {
            log("Could not load macro library: \(error.localizedDescription)", level: .error)
        }
    }

    func importMacro(from url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        do {
            let data = try Data(contentsOf: url)
            var imported: [MacroDefinition]
            if let one = try? MacroStorage.decoder.decode(MacroDefinition.self, from: data) {
                imported = [one]
            } else {
                imported = try MacroStorage.decoder.decode([MacroDefinition].self, from: data)
            }

            imported = imported.map { macro in
                var macro = macro
                macro.id = UUID()
                macro.actions = macro.actions.map { action in
                    var action = action
                    action.id = UUID()
                    return action
                }
                return macro
            }
            macros.append(contentsOf: imported)
            selectedMacroID = imported.last?.id
            log("Imported \(imported.count) \(imported.count == 1 ? "macro" : "macros")")
        } catch {
            log("Import failed: \(error.localizedDescription)", level: .error)
        }
    }

    func refreshTargets(allowAutoReconnect: Bool = true) {
        guard !isRefreshingTargets else { return }
        isRefreshingTargets = true
        defer { isRefreshingTargets = false }

        do {
            let hadSelectedTarget = selectedTarget != nil
            let discovered = try targetManager.discoverWindows()
            availableTargets = discovered
            reconnectSelectedTarget(in: discovered)
            if allowAutoReconnect && !hadSelectedTarget && selectedTarget == nil {
                reconnectTargetForSelectedMacro(in: discovered)
            }
            targetDiscoveryMessage = discovered.isEmpty
                ? "No application windows were found. Open the target app and refresh."
                : "Found \(discovered.count) windows across this Mac. Windows on other Spaces may require Compatibility playback."
            log(targetDiscoveryMessage)
        } catch {
            availableTargets = []
            if selectedTarget != nil && runState != .idle { engine.stop(); simpleEngine.stop() }
            if selectedTarget != nil { targetNeedsReselection = true }
            selectedTarget = nil
            targetDiscoveryMessage = error.localizedDescription
            log("Window discovery failed: \(error.localizedDescription)", level: .error)
        }
    }

    func selectTarget(id: TargetWindow.ID?) {
        guard let id, let target = availableTargets.first(where: { $0.id == id }) else { return }
        selectedTarget = target
        targetNeedsReselection = false
        if let index = selectedMacroIndex { macros[index].targetBundleIdentifier = target.bundleIdentifier }
        let mode = selectedMacro?.mousePlaybackMode ?? .background
        diagnosticMessage = "Ready to attempt input with \(inputBackend(for: mode).displayName)."
        log("Target selected: \(target.applicationName) — \(target.windowTitle)")
    }

    func clearTarget() {
        guard let selectedTarget else { return }
        self.selectedTarget = nil
        targetNeedsReselection = false
        diagnosticMessage = "Select a target, then send a test input."
        log("Target cleared: \(selectedTarget.applicationName)")
    }

    func start() {
        guard activity == .idle, automationStore.runState == .idle else {
            log("Play hotkey ignored because Macro is already busy", level: .warning)
            return
        }
        permissionManager.refresh()
        guard permissionManager.accessibilityGranted else {
            log("Cannot start: Accessibility permission is not granted", level: .error)
            alertMessage = "Accessibility permission is required. Open Macro → Settings → Permissions, enable the compiled Macro.app under Accessibility, then relaunch Macro."
            return
        }
        guard let macro = selectedMacro, !macro.actions.isEmpty else {
            log("Cannot start: the selected macro has no actions", level: .error)
            alertMessage = "The selected macro has no actions to play."
            return
        }

        // Refresh immediately before playback so the target frame reflects its
        // current position and size. Reusing a stale discovery result is a
        // common source of offset or scaled mouse playback after a window has
        // moved, resized, or been recreated.
        refreshTargets()
        guard let target = selectedTarget else {
            log("Cannot start: select a target window", level: .error)
            alertMessage = "No target window is selected. Open Target, click Refresh, highlight the target, and click Select Highlighted Window."
            destination = .target
            return
        }
        installEmergencyStopMonitor()

        let mode = macro.mousePlaybackMode
        let backend = inputBackend(for: mode)
        let playbackEngine: any MacroPlaybackControlling = SimplePlaybackEngine.useLegacyFallback ? engine : simpleEngine
        if mode == .background {
            playbackEngine.start(macro: macro, target: target, backend: backend)
            return
        }

        guard permissionManager.eventPostingGranted else {
            log("Cannot start \(mode.title) playback: synthetic event permission is not granted", level: .error)
            alertMessage = "\(mode.title) mouse playback needs macOS synthetic-event permission. Open Macro → Settings → Permissions, request Accessibility access again, then relaunch Macro."
            return
        }

        // Games commonly accept targeted keyboard events but require mouse
        // input from the system HID stream while they are frontmost. Wait for
        // the chosen target to actually become frontmost before posting input.
        let preparationID = UUID()
        playbackPreparationID = preparationID
        activity = .preparingPlayback
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await CompatibilityPlaybackPreparation.activate(target)
                guard self.playbackPreparationID == preparationID else { return }
                self.playbackPreparationID = nil
                playbackEngine.start(macro: macro, target: target, backend: backend)
            } catch is CancellationError {
                guard self.playbackPreparationID == preparationID else { return }
                self.playbackPreparationID = nil
                self.activity = .idle
            } catch {
                guard self.playbackPreparationID == preparationID else { return }
                self.playbackPreparationID = nil
                self.activity = .idle
                self.alertMessage = error.localizedDescription
                self.log("Compatibility playback preparation failed: \(error.localizedDescription)", level: .error)
            }
        }
    }

    func startAutomation() {
        guard canStartAutomation else { return }
        if availableTargets.isEmpty { refreshTargets() }
        installEmergencyStopMonitor()
        automationEngine.start()
    }

    func testAutomationNode(_ node: AutomationNode) {
        guard automationStore.runState == .idle else { return }
        installEmergencyStopMonitor()
        automationEngine.testNode(node.id)
    }

    func runAutomationFromNode(_ node: AutomationNode) {
        guard automationStore.runState == .idle else { return }
        installEmergencyStopMonitor()
        automationEngine.runFromHere(node.id)
    }

    func testAutomationMacro(_ node: AutomationNode) {
        guard automationStore.runState == .idle, let macroID = node.macroID,
              macros.contains(where: { $0.id == macroID }) else { return }
        selectedMacroID = macroID
        start()
    }

    func togglePause() {
        if automationStore.runState != .idle {
            automationEngine.togglePause()
        } else if simpleEngine.state != .idle {
            simpleEngine.togglePause()
        } else {
            engine.togglePause()
        }
    }

    func stop() {
        playbackPreparationID = nil
        cancelRecordingCountdown()
        if recording { finishRecording() }
        automationEngine.stop()
        engine.stop()
        simpleEngine.stop()
        activity = .idle
        playbackProgress = nil
    }

    func emergencyStop() {
        let shouldFinishRecording = recording
        let wasActive = runState != .idle || recording || recordingCountdown != nil
        playbackPreparationID = nil
        cancelRecordingCountdown()
        automationEngine.stop()
        engine.stop()
        simpleEngine.stop()
        playbackProgress = nil
        if shouldFinishRecording {
            finishRecording()
        } else {
            activity = .idle
        }
        if wasActive { log("Emergency stop: Escape pressed", level: .warning) }
    }

    func toggleRecording() {
        if recording || recordingCountdown != nil {
            stop()
        } else {
            startRecording()
        }
    }

    func updateHotkey(_ action: HotkeyAction, to shortcut: HotkeyShortcut) {
        var updated = hotkeys
        updated[action] = shortcut
        guard Set(updated.all).count == updated.all.count else {
            NSSound.beep()
            alertMessage = "That shortcut is already assigned. Choose a different hotkey for each action."
            return
        }
        hotkeys = updated
        saveAndConfigureHotkeys()
    }

    func resetHotkeys() {
        hotkeys = HotkeyPreferences()
        saveAndConfigureHotkeys()
    }

    func sendTestInput() {
        permissionManager.refresh()
        guard permissionManager.accessibilityGranted else {
            diagnosticMessage = "Accessibility permission is required before testing."
            return
        }
        guard let target = selectedTarget else {
            diagnosticMessage = "Select a target first."
            return
        }
        let mode = selectedMacro?.mousePlaybackMode ?? .background
        let backend = inputBackend(for: mode)
        diagnosticMessage = "Attempting \(diagnosticAction.rawValue) for \(target.applicationName)…"
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if mode != .background {
                    guard self.permissionManager.eventPostingGranted else {
                        throw InputBackendError.eventPostingRequired
                    }
                    try await CompatibilityPlaybackPreparation.activate(target)
                }
                let center = CGPoint(x: target.bounds.midX, y: target.bounds.midY)
                switch diagnosticAction {
                case .pressE:
                    guard let code = KeyCodeMapper.code(for: "e") else { return }
                    try backend.keyDown(code, target: target)
                    do {
                        try await Task.sleep(nanoseconds: 50_000_000)
                        try backend.keyUp(code, target: target)
                    } catch {
                        try? backend.keyUp(code, target: target)
                        throw error
                    }
                case .leftClickCenter:
                    try backend.mouseDown(.left, at: center, clickCount: 1, target: target)
                    do {
                        try await Task.sleep(nanoseconds: 50_000_000)
                        try backend.mouseUp(.left, at: center, clickCount: 1, target: target)
                    } catch {
                        try? backend.mouseUp(.left, at: center, clickCount: 1, target: target)
                        throw error
                    }
                case .moveCenter:
                    try backend.mouseMove(to: center, target: target)
                }
                diagnosticMessage = "Attempted \(diagnosticAction.rawValue) for \(target.applicationName). Input was posted, but receipt cannot be verified."
                log("Diagnostic: \(diagnosticAction.rawValue) attempted for \(target.applicationName)")
            } catch {
                diagnosticMessage = "Test failed: \(error.localizedDescription)"
                log(diagnosticMessage, level: .error)
            }
        }
    }

    func shutdown() {
        playbackPreparationID = nil
        cancelRecordingCountdown()
        automationEngine.stop()
        engine.stop()
        simpleEngine.stop()
        if recording { finishRecording() }
        activity = .idle
        emergencyMonitor.stop()
        hotkeyManager.unregisterAll()
        persistenceTask?.cancel()
        try? storage.saveLibrary(macros)
        automationStore.saveNow()
    }

    func log(_ message: String, level: LogEntry.Level = .info) {
        logs.append(LogEntry(date: .now, level: level, message: message))
    }

    private func handleEngineState(_ state: RunState) {
        switch state {
        case .idle:
            if activity == .playing || activity == .paused || activity == .preparingPlayback {
                activity = .idle
            }
            playbackProgress = nil
        case .running:
            activity = .playing
        case .paused:
            activity = .paused
        }
    }

    private func startRecording() {
        guard activity == .idle, automationStore.runState == .idle else { return }
        permissionManager.refresh()
        guard permissionManager.inputMonitoringGranted else {
            log("Cannot record: Input Monitoring permission is not granted", level: .error)
            alertMessage = "Input Monitoring is not available to the running Macro.app. Enable the compiled Macro.app—not Macro.xcodeproj—in Privacy & Security → Input Monitoring, quit Macro completely, then run it again."
            return
        }
        installEmergencyStopMonitor()
        recordedActionCount = 0
        recordingResultMessage = nil

        activity = .recordingCountdown(3)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            self?.advanceRecordingCountdown()
        }
        recordingCountdownTimer = timer
        timer.resume()
        log("Recording starts in 3 seconds")
    }

    private func advanceRecordingCountdown() {
        guard let remaining = recordingCountdown else {
            cancelRecordingCountdown()
            return
        }

        guard remaining <= 1 else {
            activity = .recordingCountdown(remaining - 1)
            return
        }

        recordingCountdownTimer?.setEventHandler {}
        recordingCountdownTimer?.cancel()
        recordingCountdownTimer = nil
        activity = .idle

        do {
            let hadSelectedTarget = selectedTarget != nil
            refreshTargets(allowAutoReconnect: false)
            if hadSelectedTarget && selectedTarget == nil {
                throw InputBackendError.targetWindowUnavailable
            }
            try recorder.start(target: selectedTarget, excluding: hotkeys.all)
            recordingStartedAt = .now
            activity = .recording
            log("Recording started")
        } catch {
            recordingStartedAt = nil
            activity = .idle
            alertMessage = "Recording could not start: \(error.localizedDescription)"
            log("Recording failed: \(error.localizedDescription)", level: .error)
        }
    }

    private func finishRecording() {
        activity = .idle
        recordingStartedAt = nil
        let recordedTarget = recorder.recordedTarget
        let actions = recorder.stop()

        let timestamp = Date.now.formatted(date: .abbreviated, time: .standard)
        let mode = selectedMacro?.mousePlaybackMode ?? .background
        let macro = MacroDefinition(
            name: "Recording \(timestamp)",
            targetBundleIdentifier: recordedTarget?.bundleIdentifier,
            actions: actions,
            mousePlaybackMode: mode,
            recordedWindowWidth: recordedTarget.map { Double($0.bounds.width) },
            recordedWindowHeight: recordedTarget.map { Double($0.bounds.height) },
            recordedWindowOriginX: recordedTarget.map { Double($0.bounds.minX) },
            recordedWindowOriginY: recordedTarget.map { Double($0.bounds.minY) }
        )
        macros.append(macro)
        selectedMacroID = macro.id
        if actions.isEmpty {
            recordingResultMessage = "Saved \(macro.name), but no input actions were detected."
            log("Recording stopped: created empty \(macro.name)", level: .warning)
        } else {
            recordingResultMessage = "Saved \(actions.count) actions as \(macro.name)."
            log("Recording stopped: created \(macro.name) with \(actions.count) actions")
        }
    }

    private func cancelRecordingCountdown() {
        recordingCountdownTimer?.setEventHandler {}
        recordingCountdownTimer?.cancel()
        recordingCountdownTimer = nil
        if case .recordingCountdown = activity { activity = .idle }
    }

    private func installEmergencyStopMonitor() {
        emergencyMonitor.start { [weak self] in self?.emergencyStop() }
    }

    private func saveAndConfigureHotkeys() {
        if let data = try? JSONEncoder().encode(hotkeys) {
            UserDefaults.standard.set(data, forKey: hotkeyDefaultsKey)
        }
        configureHotkeys()
    }

    private func configureHotkeys() {
        do {
            try hotkeyManager.register(hotkeys) { [weak self] action in
                DispatchQueue.main.async { self?.handleHotkey(action) }
            }
            hotkeyRegistrationMessage = "Global hotkeys are active."
        } catch {
            hotkeyRegistrationMessage = error.localizedDescription
            log("Hotkeys unavailable: \(error.localizedDescription)", level: .warning)
        }
    }

    private func handleHotkey(_ action: HotkeyAction) {
        switch action {
        case .record:
            guard !recording, recordingCountdown == nil else {
                log("Record hotkey ignored because recording is already active", level: .warning)
                return
            }
            startRecording()
        case .stop:
            stop()
        case .play:
            destination == .automation ? startAutomation() : start()
        }
    }

    private func automationTarget(for node: AutomationNode, macro: MacroDefinition) -> TargetWindow? {
        refreshTargets(allowAutoReconnect: false)
        let bundleIdentifier = node.targetBundleIdentifier ?? macro.targetBundleIdentifier
        let target = AutomationTargetSelector.select(
            from: availableTargets,
            selected: selectedTarget,
            bundleIdentifier: bundleIdentifier,
            isAvailable: { TargetManager().currentWindow(matching: $0) != nil }
        )
        if target == nil {
            log("No exact target window is available for \(macro.name). Select its window in Target and try again.", level: .warning)
        }
        return target
    }

    func automationNodeTitle(_ node: AutomationNode) -> String {
        if let customTitle = node.customTitle, !customTitle.isEmpty { return customTitle }
        if node.kind == .macro {
            return node.macroID.flatMap { id in macros.first { $0.id == id }?.name } ?? "Missing Macro"
        }
        return node.kind.title
    }

    private func reconnectSelectedTarget(in windows: [TargetWindow]) {
        guard let previous = selectedTarget else { return }
        if let sameWindow = windows.first(where: {
            $0.id == previous.id && $0.processIdentifier == previous.processIdentifier
        }) {
            selectedTarget = sameWindow
            return
        }

        selectedTarget = nil
        targetNeedsReselection = true
        if runState != .idle { engine.stop(); simpleEngine.stop() }
        log("Selected window is no longer available: \(previous.applicationName). Select the intended window again.", level: .warning)
    }

    private func reconnectTargetForSelectedMacro(in windows: [TargetWindow]) {
        guard
            selectedTarget == nil,
            !targetNeedsReselection,
            let bundleIdentifier = selectedMacro?.targetBundleIdentifier
        else { return }
        let matches = windows.filter { $0.bundleIdentifier == bundleIdentifier }
        guard matches.count == 1, let replacement = matches.first else { return }

        selectedTarget = replacement
        log("Automatically reconnected target: \(replacement.applicationName)")
    }

    private func persistLibrary(silent: Bool) {
        do {
            try storage.saveLibrary(macros)
            if !silent { log("Saved \(macros.count) macros") }
        } catch {
            if !silent { log("Could not save macro library: \(error.localizedDescription)", level: .error) }
        }
    }

    private func scheduleLibraryPersistence(silent: Bool = true, debounce: Bool = true) {
        let snapshot = macros
        let storage = storage
        persistenceTask?.cancel()
        persistenceTask = Task { @MainActor [weak self] in
            if debounce {
                do {
                    try await Task.sleep(nanoseconds: 180_000_000)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }

            let errorMessage = await Task.detached(priority: .utility) {
                do {
                    try storage.saveLibrary(snapshot)
                    return Optional<String>.none
                } catch {
                    return error.localizedDescription
                }
            }.value

            guard let self, !Task.isCancelled else { return }
            if let errorMessage {
                if !silent { log("Could not save macro library: \(errorMessage)", level: .error) }
            } else if !silent {
                log("Saved \(snapshot.count) macros")
            }
            persistenceTask = nil
        }
    }
}

extension MacroDefinition {
    static let example = MacroDefinition(
        name: "Roblox Travel Loop",
        targetBundleIdentifier: "com.roblox.RobloxPlayer",
        actions: [
            MacroAction(type: .keyDown, key: "w", duration: 0),
            MacroAction(type: .wait, key: nil, duration: 10),
            MacroAction(type: .keyUp, key: "w", duration: 0),
            MacroAction(type: .wait, key: nil, duration: 2),
            MacroAction(type: .keyPress, key: "e", duration: 0.1),
            MacroAction(type: .wait, key: nil, duration: 3)
        ],
        loopMode: .infinite
    )
}
