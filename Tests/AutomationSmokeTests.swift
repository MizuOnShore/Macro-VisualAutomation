import CoreGraphics
import Foundation

@main
@MainActor
struct AutomationSmokeTests {
    static func main() async throws {
        try testPersistenceAndReferences()
        try testSectionPersistenceAndMovement()
        try testEditingAndUndo()
        try testValidation()
        try testAutomationTargetSelection()
        try await testSequentialExecution()
        try await testRepeatTargetExecution()
        try await testLoopBackSharedTargetExecution()
        try await testTimedRepeatExecution()
        try await testIfElseWindowBranchExecution()
        try await testRecurringScheduleExecution()
        try await testPauseAndStop()
        print("Automation smoke tests passed")
    }

    private static func testSectionPersistenceAndMovement() throws {
        let automation = AutomationDefinition.blank(name: "Sections")
        let stop = automation.nodes.first { $0.kind == .stop }!
        var withSection = automation
        let section = AutomationSection(title: "Recovery", frame: WorkflowFrame(x: 250, y: 250, width: 300, height: 180), nodeIDs: [stop.id])
        withSection.sections = [section]
        let (store, storageDirectory) = try makeStore(with: withSection)
        defer { try? FileManager.default.removeItem(at: storageDirectory) }

        store.beginContinuousEdit()
        store.moveSection(section.id, by: CGSize(width: 40, height: 25))
        store.endContinuousEdit()
        let moved = store.selectedAutomation!
        try expect(moved.sections[0].frame.x == 290 && moved.sections[0].frame.y == 275, "Section frame did not move")
        try expect(moved.nodes.first(where: { $0.id == stop.id })?.position == WorkflowPoint(x: 460, y: 415), "Contained node did not move with its section")

        store.undo()
        try expect(store.selectedAutomation?.sections[0].frame.x == 250, "Section movement was not undoable")
        store.saveNow()
        let reopened = AutomationStore(storage: AutomationStorage(
            fileURL: storageDirectory.appendingPathComponent("Automations.json")
        ))
        try expect(reopened.selectedAutomation?.sections == [section], "Section did not persist")

        var legacyObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(automation)) as? [String: Any]
        legacyObject?.removeValue(forKey: "sections")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject ?? [:])
        let legacyAutomation = try JSONDecoder().decode(AutomationDefinition.self, from: legacyData)
        try expect(legacyAutomation.sections.isEmpty, "Older workflows without sections did not load")
    }

    private static func testEditingAndUndo() throws {
        let automation = AutomationDefinition.blank(name: "Editing")
        let (store, storageDirectory) = try makeStore(with: automation)
        defer { try? FileManager.default.removeItem(at: storageDirectory) }
        guard let startID = store.selectedAutomation?.nodes.first(where: { $0.kind == .start })?.id else {
            throw AutomationTestFailure("Blank automation had no Start node")
        }

        store.addNode(kind: .wait, at: CGPoint(x: 350, y: 220))
        guard let waitID = store.selectedNodeID else { throw AutomationTestFailure("Wait node was not added") }
        store.beginContinuousEdit()
        store.setNodePosition(waitID, to: CGPoint(x: 410, y: 260))
        store.endContinuousEdit()
        try expect(store.selectedNode?.position == WorkflowPoint(x: 410, y: 260), "Node movement was not applied")

        store.connect(source: startID, target: waitID)
        guard let connectionID = store.selectedConnectionID else { throw AutomationTestFailure("Connection was not created") }
        store.selectConnection(connectionID)
        store.deleteSelection()
        try expect(store.selectedAutomation?.connections.isEmpty == true, "Connection was not deleted")
        store.undo()
        try expect(store.selectedAutomation?.connections.count == 1, "Connection deletion did not undo")

        store.saveNow()
        let reopened = AutomationStore(storage: AutomationStorage(
            fileURL: storageDirectory.appendingPathComponent("Automations.json")
        ))
        try expect(reopened.selectedAutomation?.nodes.count == 3, "Edited workflow did not survive reopen")
    }

    private static func testPersistenceAndReferences() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutomationSmoke-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Automations.json")
        let storage = AutomationStorage(fileURL: url)
        let macroID = UUID()
        let macroNode = AutomationNode(
            kind: .macro,
            position: WorkflowPoint(x: 320, y: 240),
            macroID: macroID
        )
        var repeatNode = AutomationNode(
            kind: .repeatFlow,
            position: WorkflowPoint(x: 320, y: 400)
        )
        repeatNode.repeatTargetNodeID = macroNode.id
        let automation = AutomationDefinition(
            name: "Persistence",
            nodes: [macroNode, repeatNode],
            connections: []
        )

        try storage.saveAutomations([automation])
        let loaded = try storage.loadAutomations()
        try expect(loaded == [automation], "Automation did not round-trip")
        try expect(loaded[0].nodes[0].macroID == macroID, "Macro reference was copied or lost")
        try expect(loaded[0].nodes[1].repeatTargetNodeID == macroNode.id, "Repeat target was not persisted")

        var updated = automation
        updated.name = "Updated"
        try storage.saveAutomations([updated])
        try Data("corrupt".utf8).write(to: url, options: .atomic)
        try expect(try storage.loadAutomations() == [automation], "Automation backup recovery failed")
    }

    private static func testValidation() throws {
        let macroID = UUID()
        let start = AutomationNode(kind: .start, position: WorkflowPoint(x: 100, y: 100))
        let macroNode = AutomationNode(kind: .macro, position: WorkflowPoint(x: 300, y: 100), macroID: macroID)
        let stop = AutomationNode(kind: .stop, position: WorkflowPoint(x: 500, y: 100))
        let valid = AutomationDefinition(
            name: "Valid",
            nodes: [start, macroNode, stop],
            connections: [
                AutomationConnection(sourceNodeID: start.id, targetNodeID: macroNode.id),
                AutomationConnection(sourceNodeID: macroNode.id, targetNodeID: stop.id)
            ]
        )
        try expect(
            valid.validationIssues(availableMacroIDs: [macroID]).contains(where: { $0.severity == .error }) == false,
            "Valid workflow reported an error"
        )
        try expect(
            valid.validationIssues(availableMacroIDs: []).contains(where: { $0.id.hasPrefix("missing-macro") }),
            "Missing macro reference was not detected"
        )

        let first = AutomationNode(kind: .wait, position: WorkflowPoint(x: 200, y: 300))
        let second = AutomationNode(kind: .wait, position: WorkflowPoint(x: 400, y: 300))
        let invalid = AutomationDefinition(
            name: "Cycle",
            nodes: [start, stop, first, second],
            connections: [
                AutomationConnection(sourceNodeID: start.id, targetNodeID: stop.id),
                AutomationConnection(sourceNodeID: first.id, targetNodeID: second.id),
                AutomationConnection(sourceNodeID: second.id, targetNodeID: first.id)
            ]
        )
        try expect(
            invalid.validationIssues(availableMacroIDs: []).contains(where: { $0.id.hasPrefix("cycle") }),
            "Direct connection cycle was not detected"
        )

        var condition = AutomationNode(kind: .ifElse, position: WorkflowPoint(x: 300, y: 100))
        condition.conditionKind = .elapsedTime
        let branchWork = AutomationNode(kind: .wait, position: WorkflowPoint(x: 500, y: 100))
        var repeatNode = AutomationNode(kind: .repeatFlow, position: WorkflowPoint(x: 700, y: 200))
        repeatNode.repeatInfinitely = true
        repeatNode.repeatTargetNodeID = condition.id
        let exit = AutomationNode(kind: .stop, position: WorkflowPoint(x: 700, y: 100))
        let conditionalLoop = AutomationDefinition(
            name: "Conditional Loop",
            nodes: [start, condition, branchWork, repeatNode, exit],
            connections: [
                AutomationConnection(sourceNodeID: start.id, targetNodeID: condition.id),
                AutomationConnection(sourceNodeID: condition.id, targetNodeID: branchWork.id, branch: .yes),
                AutomationConnection(sourceNodeID: condition.id, targetNodeID: repeatNode.id, branch: .no),
                AutomationConnection(sourceNodeID: branchWork.id, targetNodeID: exit.id)
            ]
        )
        try expect(
            !conditionalLoop.validationIssues(availableMacroIDs: []).contains(where: { $0.severity == .error }),
            "A conditional exit from an infinite Repeat loop was incorrectly reported as a dead end"
        )

    }

    private static func testSequentialExecution() async throws {
        let macroID = UUID()
        let macro = MacroDefinition(
            id: macroID,
            name: "Referenced Macro",
            actions: [MacroAction(type: .keyPress, key: "e", duration: 0.01)]
        )
        let start = AutomationNode(kind: .start, position: WorkflowPoint(x: 100, y: 100))
        let macroNode = AutomationNode(kind: .macro, position: WorkflowPoint(x: 300, y: 100), macroID: macroID)
        var waitNode = AutomationNode(kind: .wait, position: WorkflowPoint(x: 500, y: 100))
        waitNode.waitDuration = 0.02
        let stop = AutomationNode(kind: .stop, position: WorkflowPoint(x: 700, y: 100))
        let automation = AutomationDefinition(
            name: "Sequential",
            nodes: [start, macroNode, waitNode, stop],
            connections: [
                AutomationConnection(sourceNodeID: start.id, targetNodeID: macroNode.id),
                AutomationConnection(sourceNodeID: macroNode.id, targetNodeID: waitNode.id),
                AutomationConnection(sourceNodeID: waitNode.id, targetNodeID: stop.id)
            ]
        )
        let (store, storageDirectory) = try makeStore(with: automation)
        defer { try? FileManager.default.removeItem(at: storageDirectory) }
        let backend = AutomationFakeBackend()
        let engine = makeEngine(store: store, macro: macro, backend: backend)

        engine.start()
        try await waitUntilIdle(store)
        try expect(backend.events == ["down:14", "up:14"], "Referenced macro did not execute")
        try expect(store.completedNodeIDs == Set([start.id, macroNode.id, waitNode.id, stop.id]), "Workflow did not execute sequentially")
        try expect(store.executionHistory.count == 4, "Execution history did not record every node")
        try expect(
            store.executionHistory.allSatisfy { $0.status == .completed && $0.finishedAt != nil },
            "Completed execution history contained an unfinished node"
        )
    }

    private static func testAutomationTargetSelection() throws {
        let game = TargetWindow(id: 12524, applicationName: "Game", windowTitle: "Game",
                                processIdentifier: 49100, bundleIdentifier: "game.bundle",
                                bounds: CGRect(x: 0, y: 30, width: 1920, height: 1050))
        let auxiliary = TargetWindow(id: 12525, applicationName: "Game", windowTitle: "Game",
                                     processIdentifier: 49100, bundleIdentifier: "game.bundle",
                                     bounds: CGRect(x: 0, y: 580, width: 500, height: 500))
        let windows = [auxiliary, game]
        let available: (TargetWindow) -> Bool = { $0.id == game.id }

        try expect(AutomationTargetSelector.select(from: windows, selected: game,
                                                   bundleIdentifier: "game.bundle", isAvailable: available)?.id == game.id,
                   "Automation chose the first same-bundle window instead of the selected game window")
        try expect(AutomationTargetSelector.select(from: windows, selected: nil,
                                                   bundleIdentifier: "game.bundle", isAvailable: available)?.id == game.id,
                   "Automation did not choose the only available game window")
        try expect(AutomationTargetSelector.select(from: windows, selected: auxiliary,
                                                   bundleIdentifier: "game.bundle", isAvailable: available) == nil,
                   "Automation silently switched away from an unavailable selected window")
        try expect(AutomationTargetSelector.select(from: windows, selected: nil,
                                                   bundleIdentifier: "game.bundle", isAvailable: { _ in true }) == nil,
                   "Automation guessed between two available game windows")
    }

    private static func testPauseAndStop() async throws {
        let start = AutomationNode(kind: .start, position: WorkflowPoint(x: 100, y: 100))
        var waitNode = AutomationNode(kind: .wait, position: WorkflowPoint(x: 300, y: 100))
        waitNode.waitDuration = 0.18
        let stop = AutomationNode(kind: .stop, position: WorkflowPoint(x: 500, y: 100))
        let automation = AutomationDefinition(
            name: "Pause",
            nodes: [start, waitNode, stop],
            connections: [
                AutomationConnection(sourceNodeID: start.id, targetNodeID: waitNode.id),
                AutomationConnection(sourceNodeID: waitNode.id, targetNodeID: stop.id)
            ]
        )
        let (store, storageDirectory) = try makeStore(with: automation)
        defer { try? FileManager.default.removeItem(at: storageDirectory) }
        let engine = makeEngine(store: store, macro: nil, backend: AutomationFakeBackend())

        engine.start()
        try await Task.sleep(nanoseconds: 30_000_000)
        engine.togglePause()
        try expect(store.runState == .paused, "Automation did not pause")
        try await Task.sleep(nanoseconds: 70_000_000)
        try expect(store.runState == .paused, "Paused automation advanced unexpectedly")
        engine.togglePause()
        try await waitUntilIdle(store)

        store.updateNode(waitNode.id) { $0.waitDuration = 5 }
        engine.start()
        try await Task.sleep(nanoseconds: 30_000_000)
        engine.stop()
        try await waitUntilIdle(store)
        try expect(store.statusMessage == "Automation stopped", "Automation stop state was incorrect")
        try expect(store.executionHistory.last?.status == .stopped, "Stopped node was not recorded in execution history")
    }

    private static func testIfElseWindowBranchExecution() async throws {
        let start = AutomationNode(kind: .start, position: WorkflowPoint(x: 100, y: 100))
        var condition = AutomationNode(kind: .ifElse, position: WorkflowPoint(x: 300, y: 100))
        condition.conditionBundleIdentifier = "com.example.game"
        condition.conditionWindowTitle = "Roblox"
        var yesWait = AutomationNode(kind: .wait, position: WorkflowPoint(x: 500, y: 20))
        yesWait.waitDuration = 0.01
        var noWait = AutomationNode(kind: .wait, position: WorkflowPoint(x: 500, y: 180))
        noWait.waitDuration = 0.01
        let stop = AutomationNode(kind: .stop, position: WorkflowPoint(x: 700, y: 100))
        let automation = AutomationDefinition(
            name: "If Else",
            nodes: [start, condition, yesWait, noWait, stop],
            connections: [
                AutomationConnection(sourceNodeID: start.id, targetNodeID: condition.id),
                AutomationConnection(sourceNodeID: condition.id, targetNodeID: yesWait.id, branch: .yes),
                AutomationConnection(sourceNodeID: condition.id, targetNodeID: noWait.id, branch: .no),
                AutomationConnection(sourceNodeID: yesWait.id, targetNodeID: stop.id),
                AutomationConnection(sourceNodeID: noWait.id, targetNodeID: stop.id)
            ]
        )
        let (store, storageDirectory) = try makeStore(with: automation)
        defer { try? FileManager.default.removeItem(at: storageDirectory) }
        let window = TargetWindow(
            id: 123,
            applicationName: "Game",
            windowTitle: "Roblox - World",
            processIdentifier: 123,
            bundleIdentifier: "com.example.game",
            bounds: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
        let engine = makeEngine(store: store, macro: nil, backend: AutomationFakeBackend(), windows: [window])

        engine.start()
        try await waitUntilIdle(store)
        try expect(store.completedNodeIDs == Set([start.id, condition.id, yesWait.id, stop.id]), "If / Else did not take the matching Yes path and rejoin")
        try expect(!store.completedNodeIDs.contains(noWait.id), "If / Else incorrectly executed the No path")
    }

    private static func testRepeatTargetExecution() async throws {
        let start = AutomationNode(kind: .start, position: WorkflowPoint(x: 100, y: 100))
        var wait = AutomationNode(kind: .wait, position: WorkflowPoint(x: 100, y: 220))
        wait.waitDuration = 0.005
        var repeatNode = AutomationNode(kind: .repeatFlow, position: WorkflowPoint(x: 100, y: 340))
        repeatNode.repeatCount = 3
        repeatNode.repeatTargetNodeID = wait.id
        let stop = AutomationNode(kind: .stop, position: WorkflowPoint(x: 100, y: 460))
        let automation = AutomationDefinition(
            name: "Targeted Repeat",
            nodes: [start, wait, repeatNode, stop],
            connections: [
                AutomationConnection(sourceNodeID: start.id, targetNodeID: wait.id),
                AutomationConnection(sourceNodeID: wait.id, targetNodeID: repeatNode.id),
                AutomationConnection(sourceNodeID: repeatNode.id, targetNodeID: stop.id)
            ]
        )
        let (store, storageDirectory) = try makeStore(with: automation)
        defer { try? FileManager.default.removeItem(at: storageDirectory) }
        let engine = makeEngine(store: store, macro: nil, backend: AutomationFakeBackend())

        engine.start()
        try await waitUntilIdle(store)
        try expect(
            store.executionHistory.filter { $0.nodeID == wait.id }.count == 3,
            "Repeat did not return to the selected target the requested number of times"
        )
        try expect(store.executionHistory.last?.nodeID == stop.id, "Repeat did not continue to Stop")
    }

    private static func testLoopBackSharedTargetExecution() async throws {
        let start = AutomationNode(kind: .start, position: WorkflowPoint(x: 100, y: 100))
        var wait = AutomationNode(kind: .wait, position: WorkflowPoint(x: 100, y: 220))
        wait.waitDuration = 0.01
        var condition = AutomationNode(kind: .ifElse, position: WorkflowPoint(x: 100, y: 340))
        condition.conditionKind = .windowOpen
        condition.conditionBundleIdentifier = "com.example.game"
        var loopBack = AutomationNode(kind: .loopBack, position: WorkflowPoint(x: 300, y: 460))
        loopBack.jumpTargetNodeID = wait.id
        let automation = AutomationDefinition(
            name: "Shared Loop Back",
            nodes: [start, wait, condition, loopBack],
            connections: [
                AutomationConnection(sourceNodeID: start.id, targetNodeID: wait.id),
                AutomationConnection(sourceNodeID: wait.id, targetNodeID: condition.id),
                AutomationConnection(sourceNodeID: condition.id, targetNodeID: loopBack.id, branch: .yes),
                AutomationConnection(sourceNodeID: condition.id, targetNodeID: loopBack.id, branch: .no)
            ]
        )
        let (store, storageDirectory) = try makeStore(with: automation)
        defer { try? FileManager.default.removeItem(at: storageDirectory) }
        let engine = makeEngine(store: store, macro: nil, backend: AutomationFakeBackend())

        engine.start()
        let deadline = Date().addingTimeInterval(2)
        while store.executionHistory.filter({ $0.nodeID == wait.id }).count < 2 {
            if Date() > deadline { throw AutomationTestFailure("Loop Back did not return to its configured target") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        engine.stop()
        try await waitUntilIdle(store)
        let waitRuns = store.executionHistory.filter { $0.nodeID == wait.id }.count
        try expect(waitRuns >= 2, "Loop Back did not return to the configured shared target")
        try expect(store.completedNodeIDs.contains(loopBack.id), "Loop Back node did not execute")
        try expect(store.statusMessage == "Automation stopped", "Loop Back did not stop cleanly")
    }

    private static func testRecurringScheduleExecution() async throws {
        let start = AutomationNode(kind: .start, position: WorkflowPoint(x: 100, y: 100))
        var schedule = AutomationNode(kind: .schedule, position: WorkflowPoint(x: 100, y: 220))
        schedule.scheduleMode = .interval
        schedule.scheduleInterval = 1
        schedule.scheduleIntervalUnit = .seconds
        let stop = AutomationNode(kind: .stop, position: WorkflowPoint(x: 100, y: 340))
        let automation = AutomationDefinition(
            name: "Recurring Schedule",
            nodes: [start, schedule, stop],
            connections: [
                AutomationConnection(sourceNodeID: start.id, targetNodeID: schedule.id),
                AutomationConnection(sourceNodeID: schedule.id, targetNodeID: stop.id)
            ]
        )
        let (store, storageDirectory) = try makeStore(with: automation)
        defer { try? FileManager.default.removeItem(at: storageDirectory) }
        let engine = makeEngine(store: store, macro: nil, backend: AutomationFakeBackend())

        engine.start()
        let deadline = Date().addingTimeInterval(3)
        while store.executionHistory.filter({ $0.nodeID == schedule.id }).count < 2 {
            if Date() > deadline { throw AutomationTestFailure("Recurring Schedule did not begin a second cycle") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        engine.stop()
        try await waitUntilIdle(store)
        try expect(
            store.executionHistory.filter({ $0.nodeID == schedule.id }).count >= 2,
            "Recurring Schedule did not execute at the configured interval"
        )
        try expect(store.statusMessage == "Automation stopped", "Recurring schedule did not stop cleanly")
    }

    private static func testTimedRepeatExecution() async throws {
        let start = AutomationNode(kind: .start, position: WorkflowPoint(x: 100, y: 100))
        var recordOne = AutomationNode(kind: .wait, position: WorkflowPoint(x: 100, y: 220))
        recordOne.waitDuration = 0.15
        var timedRepeat = AutomationNode(kind: .repeatFlow, position: WorkflowPoint(x: 100, y: 340))
        timedRepeat.repeatForDuration = true
        timedRepeat.repeatDuration = 1
        timedRepeat.repeatDurationUnit = .seconds
        timedRepeat.repeatTargetNodeID = recordOne.id
        var recordTwo = AutomationNode(kind: .wait, position: WorkflowPoint(x: 100, y: 460))
        recordTwo.waitDuration = 0.01
        let stop = AutomationNode(kind: .stop, position: WorkflowPoint(x: 100, y: 580))
        let automation = AutomationDefinition(
            name: "Timed Repeat",
            nodes: [start, recordOne, timedRepeat, recordTwo, stop],
            connections: [
                AutomationConnection(sourceNodeID: start.id, targetNodeID: recordOne.id),
                AutomationConnection(sourceNodeID: recordOne.id, targetNodeID: timedRepeat.id),
                AutomationConnection(sourceNodeID: timedRepeat.id, targetNodeID: recordTwo.id),
                AutomationConnection(sourceNodeID: recordTwo.id, targetNodeID: stop.id)
            ]
        )
        let (store, storageDirectory) = try makeStore(with: automation)
        defer { try? FileManager.default.removeItem(at: storageDirectory) }
        let engine = makeEngine(store: store, macro: nil, backend: AutomationFakeBackend())

        engine.start()
        try await waitUntilIdle(store)
        let recordOneRuns = store.executionHistory.filter { $0.nodeID == recordOne.id }.count
        try expect(
            recordOneRuns >= 3,
            "Timed Repeat did not rerun its target while the duration was active"
        )
        let recordTwoRuns = store.executionHistory.filter { $0.nodeID == recordTwo.id }.count
        try expect(
            recordTwoRuns == 1,
            "Timed Repeat did not continue to the next node after the duration elapsed"
        )
    }

    private static func makeStore(with automation: AutomationDefinition) throws -> (AutomationStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutomationEngineSmoke-\(UUID().uuidString)", isDirectory: true)
        let storage = AutomationStorage(fileURL: directory.appendingPathComponent("Automations.json"))
        try storage.saveAutomations([automation])
        return (AutomationStore(storage: storage), directory)
    }

    private static func makeEngine(
        store: AutomationStore,
        macro: MacroDefinition?,
        backend: AutomationFakeBackend,
        windows: [TargetWindow] = []
    ) -> AutomationEngine {
        let macroEngine = MacroEngine(isAuthorized: { true }, targetIsRunning: { _ in true }, targetWindowResolver: { $0 })
        return AutomationEngine(
            store: store,
            macroResolver: { id in macro?.id == id ? macro : nil },
            targetResolver: { _, _ in .automationTestTarget },
            backendResolver: { _ in backend },
            windowResolver: { windows },
            permissionCheck: { true },
            logger: { _, _ in },
            macroEngine: macroEngine
        )
    }

    private static func waitUntilIdle(_ store: AutomationStore) async throws {
        let deadline = Date().addingTimeInterval(2)
        while store.runState != .idle {
            if Date() > deadline {
                let visited = store.executionHistory.map(\.title).joined(separator: " → ")
                throw AutomationTestFailure("Automation did not finish in time: \(store.statusMessage), active node \(String(describing: store.activeNodeID)); visited \(visited)")
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw AutomationTestFailure(message) }
    }
}

@MainActor
private final class AutomationFakeBackend: InputBackend {
    let displayName = "Automation Fake"
    let canVerifyReceipt = true
    var events: [String] = []

    func keyDown(_ keyCode: CGKeyCode, target: TargetWindow) throws { events.append("down:\(keyCode)") }
    func keyUp(_ keyCode: CGKeyCode, target: TargetWindow) throws { events.append("up:\(keyCode)") }
    func mouseMove(to point: CGPoint, target: TargetWindow) throws {}
    func mouseDrag(_ button: MacroMouseButton, to point: CGPoint, target: TargetWindow) throws {}
    func mouseDown(_ button: MacroMouseButton, at point: CGPoint, clickCount: Int, target: TargetWindow) throws {}
    func mouseUp(_ button: MacroMouseButton, at point: CGPoint, clickCount: Int, target: TargetWindow) throws {}
    func scroll(deltaX: Double, deltaY: Double, units: MacroScrollUnit, at point: CGPoint, target: TargetWindow) throws {}
}

private extension TargetWindow {
    static let automationTestTarget = TargetWindow(
        id: 1,
        applicationName: "Test",
        windowTitle: "Test",
        processIdentifier: 1,
        bundleIdentifier: "test.bundle",
        bounds: CGRect(x: 0, y: 0, width: 800, height: 600)
    )
}

private struct AutomationTestFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
