import AppKit
import Foundation

@MainActor
final class AutomationEngine {
    typealias MacroResolver = (UUID) -> MacroDefinition?
    typealias TargetResolver = (AutomationNode, MacroDefinition) -> TargetWindow?
    typealias BackendResolver = (MousePlaybackMode) -> any InputBackend
    typealias WindowResolver = () -> [TargetWindow]

    private let store: AutomationStore
    private let macroResolver: MacroResolver
    private let targetResolver: TargetResolver
    private let backendResolver: BackendResolver
    private let windowResolver: WindowResolver
    private let permissionCheck: () -> Bool
    private let logger: (String, LogEntry.Level) -> Void
    private let macroEngine: any MacroPlaybackControlling
    private var task: Task<Void, Never>?
    private var macroContinuation: CheckedContinuation<MacroRunOutcome, Never>?

    init(
        store: AutomationStore,
        macroResolver: @escaping MacroResolver,
        targetResolver: @escaping TargetResolver,
        backendResolver: @escaping BackendResolver,
        windowResolver: @escaping WindowResolver = { [] },
        permissionCheck: @escaping () -> Bool,
        logger: @escaping (String, LogEntry.Level) -> Void,
        macroEngine: (any MacroPlaybackControlling)? = nil
    ) {
        self.store = store
        self.macroResolver = macroResolver
        self.targetResolver = targetResolver
        self.backendResolver = backendResolver
        self.windowResolver = windowResolver
        self.permissionCheck = permissionCheck
        self.logger = logger
        self.macroEngine = macroEngine ?? (SimplePlaybackEngine.useLegacyFallback ? MacroEngine() : SimplePlaybackEngine())

        self.macroEngine.onLog = logger
        self.macroEngine.onFinish = { [weak self] outcome in
            self?.finishPendingMacro(with: outcome)
        }
    }

    var runState: AutomationRunState { store.runState }

    func start() {
        guard task == nil, store.runState == .idle, let automation = store.selectedAutomation else { return }
        let availableMacroIDs = Set(automation.nodes.compactMap { node -> UUID? in
            guard node.kind == .macro, let id = node.macroID, macroResolver(id) != nil else { return nil }
            return id
        })
        let validationErrors = automation.validationIssues(availableMacroIDs: availableMacroIDs)
            .filter { $0.severity == .error }
        guard validationErrors.isEmpty else {
            let message = validationErrors.first?.message ?? "The workflow contains validation errors."
            store.setStatusMessage(message)
            logger("Automation validation failed: \(message)", .error)
            return
        }
        guard permissionCheck() else {
            store.finishRun(message: "Accessibility permission is required.")
            logger("Automation cannot start: Accessibility permission is not granted", .error)
            return
        }

        store.beginRun(totalSteps: max(1, automation.nodes.count))
        logger("Automation started: \(automation.name)", .info)
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.run(automation, startNodeID: nil)
                if !Task.isCancelled {
                    self.store.finishRun()
                    self.logger("Automation completed: \(automation.name)", .info)
                }
            } catch is CancellationError {
                self.store.stopActiveNode()
                self.store.finishRun(message: "Automation stopped")
                self.logger("Automation stopped: \(automation.name)", .warning)
            } catch {
                if let active = self.store.activeNodeID {
                    self.store.failNode(active, message: error.localizedDescription)
                }
                self.store.finishRun(message: error.localizedDescription)
                self.logger("Automation error: \(error.localizedDescription)", .error)
            }
            self.task = nil
        }
    }

    func runFromHere(_ nodeID: UUID) {
        guard task == nil, store.runState == .idle, let automation = store.selectedAutomation,
              let node = automation.nodes.first(where: { $0.id == nodeID }) else { return }
        store.beginRun(totalSteps: max(1, automation.nodes.count))
        logger("Automation run from node: \(nodeTitle(node))", .info)
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.run(automation, startNodeID: nodeID)
                if !Task.isCancelled { self.store.finishRun(); self.logger("Automation run-from-here completed", .info) }
            } catch is CancellationError {
                self.store.stopActiveNode(); self.store.finishRun(message: "Automation stopped"); self.logger("Automation run-from-here stopped", .warning)
            } catch {
                if let active = self.store.activeNodeID { self.store.failNode(active, message: error.localizedDescription) }
                self.store.finishRun(message: error.localizedDescription); self.logger("Automation run-from-here failed: \(error.localizedDescription)", .error)
            }
            self.task = nil
        }
    }

    func testNode(_ nodeID: UUID) {
        guard task == nil, store.runState == .idle, let automation = store.selectedAutomation,
              let node = automation.nodes.first(where: { $0.id == nodeID }) else { return }
        store.beginNodeTest(node)
        logger("Node test started: \(nodeTitle(node))", .info)
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let actions = try await self.executeTest(node, automation: automation)
                if !Task.isCancelled {
                    self.store.finishNodeTest(status: .completed, actionsExecuted: actions)
                    self.logger("Node test completed: \(self.nodeTitle(node))", .info)
                }
            } catch is CancellationError {
                self.store.finishNodeTest(status: .stopped, message: "Stopped by user")
                self.logger("Node test stopped: \(self.nodeTitle(node))", .warning)
            } catch {
                self.store.finishNodeTest(status: .failed, message: error.localizedDescription)
                self.logger("Node test failed: \(error.localizedDescription)", .error)
            }
            self.task = nil
        }
    }

    func togglePause() {
        guard store.runState != .idle else { return }
        let shouldPause = store.runState == .running
        store.setPaused(shouldPause)
        if macroEngine.state != .idle { macroEngine.togglePause() }
    }

    func stop() {
        guard task != nil || store.runState != .idle else { return }
        task?.cancel()
        macroEngine.stop()
        if macroEngine.state == .idle, let continuation = macroContinuation {
            macroContinuation = nil
            continuation.resume(returning: .stopped)
        }
    }

    private func run(_ automation: AutomationDefinition, startNodeID: UUID?) async throws {
        guard let start = startNodeID.flatMap({ id in automation.nodes.first { $0.id == id } }) ?? automation.nodes.first(where: { $0.kind == .start }) else {
            throw AutomationExecutionError.missingStart
        }

        var current: AutomationNode? = start
        var transitions = 0
        var repeatVisits: [UUID: Int] = [:]
        var repeatStartedAt: [UUID: Date] = [:]
        var elapsedTimerStartedAt = Date.now
        var macroRunCounts: [UUID: Int] = [:]
        var recurringScheduleStarted = false

        while let node = current {
            try Task.checkCancellation()
            try await waitWhilePaused()
            transitions += 1
            guard transitions <= 10_000 else { throw AutomationExecutionError.runawayWorkflow }

            store.setActiveNode(
                node,
                title: nodeTitle(node),
                step: min(transitions, max(1, store.totalSteps))
            )
            if !node.isEnabled {
                store.completeNode(node.id)
                current = nextNode(after: node.id, in: automation)
                continue
            }
            // Workflow runs don't display per-node action totals; node tests do.
            _ = try await execute(node, automation: automation)
            store.completeNode(node.id)

            if node.kind == .macro, let macroID = node.macroID {
                macroRunCounts[macroID, default: 0] += max(1, node.macroLoops)
            }
            if node.kind == .resetTimer {
                elapsedTimerStartedAt = .now
            }

            if node.kind == .schedule && node.scheduleMode == .interval {
                recurringScheduleStarted = true
            }

            if node.kind == .stop {
                if recurringScheduleStarted {
                    // Completing Stop starts the next scheduled run. The Schedule node
                    // at the top of the flow provides the interval delay each time.
                    current = start
                    transitions = 0
                    repeatVisits.removeAll()
                    recurringScheduleStarted = false
                    continue
                }
                return
            }

            if node.kind == .loopBack {
                current = node.jumpTargetNodeID.flatMap { targetID in automation.nodes.first { $0.id == targetID } }
                transitions = 0
                continue
            }

            if node.kind == .ifElse {
                let conditionMatched = conditionMatches(
                    node,
                    timerStartedAt: elapsedTimerStartedAt,
                    macroRunCounts: macroRunCounts
                )
                current = nextNode(after: node.id, branch: conditionMatched ? .yes : .no, in: automation)
                continue
            }

            if node.kind == .repeatFlow {
                if node.repeatForDuration {
                    let startedAt = repeatStartedAt[node.id] ?? .now
                    repeatStartedAt[node.id] = startedAt
                    let duration = node.repeatDuration * node.repeatDurationUnit.secondsPerUnit
                    if Date.now.timeIntervalSince(startedAt) >= duration {
                        repeatStartedAt.removeValue(forKey: node.id)
                    } else {
                        current = node.repeatTargetNodeID
                            .flatMap { targetID in automation.nodes.first { $0.id == targetID } }
                            ?? nextNode(after: start.id, in: automation)
                        transitions = 0
                        continue
                    }
                } else {
                    let visit = (repeatVisits[node.id] ?? 0) + 1
                    repeatVisits[node.id] = visit
                    if node.repeatInfinitely || visit < max(1, node.repeatCount) {
                        current = node.repeatTargetNodeID
                            .flatMap { targetID in automation.nodes.first { $0.id == targetID } }
                            ?? nextNode(after: start.id, in: automation)
                        transitions = 0
                        continue
                    }
                }
            }

            current = nextNode(after: node.id, in: automation)
        }
    }

    private func executeTest(_ node: AutomationNode, automation: AutomationDefinition) async throws -> Int? {
        guard node.isEnabled else { return 0 }
        if node.kind == .repeatFlow && (node.repeatInfinitely || node.repeatForDuration) {
            // A node test never follows an unbounded loop.
            return 0
        }
        if node.kind == .schedule { return 0 }
        if node.kind == .stop { return 0 }
        return try await execute(node, automation: automation)
    }

    private func execute(_ node: AutomationNode, automation: AutomationDefinition) async throws -> Int? {
        switch node.kind {
        case .start, .stop, .repeatFlow, .loopBack, .merge, .ifElse, .resetTimer, .note:
            return 0
        case .wait:
            try await wait(seconds: max(0, node.waitDuration))
            return 0
        case .waitForWindow:
            try await waitForWindow(node)
            return 0
        case .schedule:
            if node.scheduleMode == .interval {
                let delay = node.scheduleInterval * node.scheduleIntervalUnit.secondsPerUnit
                try await wait(seconds: delay, pollingInterval: 1)
            } else {
                guard automation.startMode == .scheduled else { return 0 }
                try await wait(seconds: delayUntil(minuteOfDay: node.scheduleMinuteOfDay), pollingInterval: 1)
            }
            return 0
        case .macro:
            guard let macroID = node.macroID, var macro = macroResolver(macroID) else {
                throw AutomationExecutionError.missingMacro
            }
            guard let target = targetResolver(node, macro) else {
                throw AutomationExecutionError.missingTarget(macro.name)
            }

            macro.mousePlaybackMode = node.playbackOverride.resolve(using: macro.mousePlaybackMode)
            macro.loopMode = node.macroLoops > 1 ? .count : .once
            macro.loopCount = max(1, node.macroLoops)
            let outcome = await playMacro(macro, target: target)
            switch outcome {
            case .completed: return macro.actions.filter(\.isEnabled).count * max(1, macro.loopCount)
            case .stopped: throw CancellationError()
            case .failed(let message): throw AutomationExecutionError.macroFailed(message)
            }
        }
    }

    private func waitForWindow(_ node: AutomationNode) async throws {
        let deadline = Date().addingTimeInterval(node.waitForWindowTimeout)
        let titleQuery = node.waitForWindowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        while Date() < deadline {
            try Task.checkCancellation()
            try await waitWhilePaused()
            let found = windowResolver().contains { window in
                let matchesApplication = node.waitForBundleIdentifier.map { window.bundleIdentifier == $0 } ?? true
                let matchesTitle = titleQuery.isEmpty || window.windowTitle.localizedCaseInsensitiveContains(titleQuery)
                return matchesApplication && matchesTitle
            }
            if found { return }
            let remaining = deadline.timeIntervalSinceNow
            if remaining > 0 { try await wait(seconds: min(0.5, remaining)) }
        }
        throw AutomationExecutionError.windowWaitTimedOut(node.waitForWindowTimeout)
    }

    private func playMacro(_ macro: MacroDefinition, target: TargetWindow) async -> MacroRunOutcome {
        let mode = macro.mousePlaybackMode
        if mode == .compatibility {
            do {
                try await CompatibilityPlaybackPreparation.activate(target)
            } catch is CancellationError {
                return .stopped
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        do {
            try await waitWhilePaused()
        } catch {
            return .stopped
        }
        guard !Task.isCancelled else { return .stopped }
        return await withCheckedContinuation { continuation in
            macroContinuation = continuation
            macroEngine.start(macro: macro, target: target, backend: backendResolver(mode))
        }
    }

    private func finishPendingMacro(with outcome: MacroRunOutcome) {
        guard let continuation = macroContinuation else { return }
        macroContinuation = nil
        continuation.resume(returning: outcome)
    }

    private func nextNode(after nodeID: UUID, branch: AutomationBranch? = nil, in automation: AutomationDefinition) -> AutomationNode? {
        guard let connection = automation.connections.first(where: { connection in
            guard connection.sourceNodeID == nodeID else { return false }
            return branch == nil ? connection.branch == nil || connection.branch == .yes : connection.branch == branch
        }) else { return nil }
        return automation.nodes.first { $0.id == connection.targetNodeID }
    }

    private func conditionMatches(
        _ node: AutomationNode,
        timerStartedAt: Date,
        macroRunCounts: [UUID: Int]
    ) -> Bool {
        switch node.conditionKind {
        case .windowOpen:
            let titleQuery = node.conditionWindowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            return windowResolver().contains { window in
                let matchesApplication = node.conditionBundleIdentifier.map { window.bundleIdentifier == $0 } ?? true
                let matchesTitle = titleQuery.isEmpty || window.windowTitle.localizedCaseInsensitiveContains(titleQuery)
                return matchesApplication && matchesTitle
            }
        case .elapsedTime:
            let threshold = Double(node.resolvedConditionElapsedMilliseconds) / 1_000
            return Date.now.timeIntervalSince(timerStartedAt) >= threshold
        case .macroRunCount:
            guard let macroID = node.conditionMacroID else { return false }
            return macroRunCounts[macroID, default: 0] >= max(1, node.conditionMacroRunCount)
        }
    }

    private func nodeTitle(_ node: AutomationNode) -> String {
        if let customTitle = node.customTitle, !customTitle.isEmpty { return customTitle }
        if node.kind == .macro, let macroID = node.macroID {
            return macroResolver(macroID)?.name ?? "Missing Macro"
        }
        return node.kind.title
    }

    private func wait(seconds: Double, pollingInterval: Double = 0.05) async throws {
        var remaining = seconds
        while remaining > 0 {
            try Task.checkCancellation()
            try await waitWhilePaused()
            let slice = min(remaining, max(0.05, pollingInterval))
            try await Task.sleep(nanoseconds: UInt64(slice * 1_000_000_000))
            remaining -= slice
        }
    }

    private func waitWhilePaused() async throws {
        while store.runState == .paused {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func delayUntil(minuteOfDay: Int) -> TimeInterval {
        let calendar = Calendar.current
        let now = Date()
        let minute = min(max(0, minuteOfDay), 1439)
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = minute / 60
        components.minute = minute % 60
        components.second = 0
        guard var date = calendar.date(from: components) else { return 0 }
        if date <= now { date = calendar.date(byAdding: .day, value: 1, to: date) ?? now }
        return max(0, date.timeIntervalSince(now))
    }
}

private enum AutomationExecutionError: LocalizedError {
    case missingStart
    case missingMacro
    case missingTarget(String)
    case macroFailed(String)
    case runawayWorkflow
    case windowWaitTimedOut(Double)

    var errorDescription: String? {
        switch self {
        case .missingStart: "This automation has no Start node."
        case .missingMacro: "A Macro node references a macro that no longer exists."
        case .missingTarget(let name): "No target window is available for \(name)."
        case .macroFailed(let message): message
        case .runawayWorkflow: "The workflow exceeded its execution safety limit."
        case .windowWaitTimedOut(let seconds): "The matching window did not appear within \(Int(seconds)) seconds."
        }
    }
}
