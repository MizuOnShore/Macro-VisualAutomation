import SwiftUI

@MainActor
final class AutomationStore: ObservableObject {
    @Published private(set) var automations: [AutomationDefinition] = [] {
        didSet { schedulePersistence() }
    }
    @Published var selectedAutomationID: UUID?
    @Published var selectedNodeID: UUID?
    @Published var selectedConnectionID: UUID?
    @Published private(set) var runState: AutomationRunState = .idle
    @Published private(set) var activeNodeID: UUID?
    @Published private(set) var completedNodeIDs = Set<UUID>()
    @Published private(set) var failedNodeID: UUID?
    @Published private(set) var currentStep = 0
    @Published private(set) var totalSteps = 0
    @Published private(set) var statusMessage = "Select a workflow and press Run to start."
    @Published private(set) var executionHistory: [AutomationExecutionRecord] = []
    @Published private(set) var lastTestResult: AutomationNodeTestResult?

    private let storage: any AutomationStoring
    private var persistenceTask: Task<Void, Never>?
    private var undoStack: [[AutomationDefinition]] = []
    private var redoStack: [[AutomationDefinition]] = []
    private var continuousEditSnapshot: [AutomationDefinition]?
    private var activeExecutionRecordID: UUID?

    init(storage: any AutomationStoring = AutomationStorage()) {
        self.storage = storage
        automations = (try? storage.loadAutomations()) ?? []
        selectedAutomationID = automations.first?.id
    }

    var selectedAutomationIndex: Int? {
        automations.firstIndex { $0.id == selectedAutomationID }
    }

    var selectedAutomation: AutomationDefinition? {
        guard let index = selectedAutomationIndex else { return nil }
        return automations[index]
    }

    var selectedNode: AutomationNode? {
        selectedAutomation?.nodes.first { $0.id == selectedNodeID }
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var canRun: Bool { selectedAutomation?.nodes.contains(where: { $0.kind == .start }) == true }
    var canEdit: Bool { runState == .idle }

    func validationIssues(availableMacroIDs: Set<UUID>) -> [AutomationValidationIssue] {
        selectedAutomation?.validationIssues(availableMacroIDs: availableMacroIDs) ?? []
    }

    func canRun(availableMacroIDs: Set<UUID>) -> Bool {
        canRun && !validationIssues(availableMacroIDs: availableMacroIDs).contains { $0.severity == .error }
    }

    func seedIfNeeded(macros: [MacroDefinition]) {
        guard automations.isEmpty else { return }
        automations = [.example(macros: macros)]
        selectedAutomationID = automations.first?.id
    }

    func selectAutomation(_ id: UUID?) {
        guard runState == .idle || id == selectedAutomationID else { return }
        if id != selectedAutomationID {
            executionHistory = []
            activeExecutionRecordID = nil
        }
        selectedAutomationID = id
        selectedNodeID = nil
        selectedConnectionID = nil
    }

    func createAutomation() {
        performMutation {
            let automation = AutomationDefinition.blank()
            automations.append(automation)
            selectedAutomationID = automation.id
            selectedNodeID = nil
            selectedConnectionID = nil
            executionHistory = []
            activeExecutionRecordID = nil
        }
    }

    func deleteSelectedAutomation() {
        guard let index = selectedAutomationIndex else { return }
        performMutation {
            automations.remove(at: index)
            selectedAutomationID = automations.first?.id
            selectedNodeID = nil
            selectedConnectionID = nil
            executionHistory = []
            activeExecutionRecordID = nil
        }
    }

    func updateAutomation(_ update: (inout AutomationDefinition) -> Void) {
        guard let index = selectedAutomationIndex else { return }
        performMutation {
            update(&automations[index])
            automations[index].lastEdited = .now
        }
    }

    func addNode(kind: AutomationNodeKind, macroID: UUID? = nil, at point: CGPoint) {
        guard canEdit,
              kind != .macro || macroID != nil,
              kind != .start || selectedAutomation?.nodes.contains(where: { $0.kind == .start }) != true else { return }
        updateAutomation { automation in
            var node = AutomationNode(kind: kind, position: WorkflowPoint(point), macroID: macroID)
            if kind == .repeatFlow,
               let startID = automation.nodes.first(where: { $0.kind == .start })?.id,
               let firstID = automation.connections.first(where: { $0.sourceNodeID == startID })?.targetNodeID {
                node.repeatTargetNodeID = firstID
            }
            if kind == .loopBack,
               let startID = automation.nodes.first(where: { $0.kind == .start })?.id,
               let firstID = automation.connections.first(where: { $0.sourceNodeID == startID })?.targetNodeID {
                node.jumpTargetNodeID = firstID
            }
            automation.nodes.append(node)
        }
        selectedNodeID = selectedAutomation?.nodes.last?.id
        selectedConnectionID = nil
    }

    func updateNode(_ nodeID: UUID, _ update: (inout AutomationNode) -> Void) {
        updateAutomation { automation in
            guard let index = automation.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
            update(&automation.nodes[index])
        }
    }

    func setNodePosition(_ nodeID: UUID, to point: CGPoint) {
        guard canEdit,
              let automationIndex = selectedAutomationIndex,
              let nodeIndex = automations[automationIndex].nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        automations[automationIndex].nodes[nodeIndex].position = WorkflowPoint(point)
        automations[automationIndex].lastEdited = .now
    }

    func addSection(_ section: AutomationSection) {
        updateAutomation { $0.sections.append(section) }
    }

    func renameSection(_ sectionID: UUID, to title: String) {
        guard let index = selectedAutomationIndex,
              let sectionIndex = automations[index].sections.firstIndex(where: { $0.id == sectionID }) else { return }
        automations[index].sections[sectionIndex].title = title
        automations[index].lastEdited = .now
    }

    func moveSection(_ sectionID: UUID, by delta: CGSize, containing nodeIDs: Set<UUID>) {
        guard canEdit, let index = selectedAutomationIndex,
              let sectionIndex = automations[index].sections.firstIndex(where: { $0.id == sectionID }) else { return }
        automations[index].sections[sectionIndex].frame.x += Double(delta.width)
        automations[index].sections[sectionIndex].frame.y += Double(delta.height)
        for nodeIndex in automations[index].nodes.indices where nodeIDs.contains(automations[index].nodes[nodeIndex].id) {
            automations[index].nodes[nodeIndex].position.x += Double(delta.width)
            automations[index].nodes[nodeIndex].position.y += Double(delta.height)
        }
        automations[index].lastEdited = .now
    }

    func deleteSection(_ sectionID: UUID) {
        guard canEdit else { return }
        updateAutomation { $0.sections.removeAll { $0.id == sectionID } }
    }

    func connect(source: UUID, target: UUID, branch: AutomationBranch? = nil) {
        guard canEdit,
              source != target,
              let automation = selectedAutomation,
              automation.nodes.first(where: { $0.id == source })?.kind.providesOutput == true,
              automation.nodes.first(where: { $0.id == target })?.kind.acceptsInput == true,
              (automation.nodes.first(where: { $0.id == source })?.kind == .ifElse) == (branch != nil) else { return }
        updateAutomation { automation in
            automation.connections.removeAll {
                $0.sourceNodeID == source && (branch == nil || $0.branch == branch)
            }
            let connection = AutomationConnection(sourceNodeID: source, targetNodeID: target, branch: branch)
            automation.connections.append(connection)
            selectedConnectionID = connection.id
            selectedNodeID = nil
        }
    }

    func selectNode(_ id: UUID?) {
        selectedNodeID = id
        selectedConnectionID = nil
    }

    func selectConnection(_ id: UUID?) {
        selectedConnectionID = id
        selectedNodeID = nil
    }

    func setConnectionStyle(_ id: UUID, to style: AutomationConnectionStyle) {
        updateAutomation { automation in
            guard let index = automation.connections.firstIndex(where: { $0.id == id }) else { return }
            automation.connections[index].style = style
        }
    }

    func setConnectionBendPoint(_ id: UUID, to point: CGPoint?) {
        updateAutomation { automation in
            guard let index = automation.connections.firstIndex(where: { $0.id == id }) else { return }
            automation.connections[index].bendPoint = point.map(WorkflowPoint.init(_:))
        }
    }

    func addConnectionBendPoint(_ id: UUID) {
        guard let automation = selectedAutomation,
              let connection = automation.connections.first(where: { $0.id == id }),
              let source = automation.nodes.first(where: { $0.id == connection.sourceNodeID }),
              let target = automation.nodes.first(where: { $0.id == connection.targetNodeID }) else { return }
        let branchOffset: CGFloat = connection.branch == .yes ? -62 : connection.branch == .no ? 62 : 0
        let start = CGPoint(x: CGFloat(source.position.x) + branchOffset, y: CGFloat(source.position.y) + 38)
        let end = CGPoint(x: CGFloat(target.position.x), y: CGFloat(target.position.y) - 38)
        setConnectionBendPoint(id, to: CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2))
    }

    func deleteSelection() {
        guard canEdit, let automationIndex = selectedAutomationIndex else { return }
        if let nodeID = selectedNodeID {
            guard automations[automationIndex].nodes.first(where: { $0.id == nodeID })?.kind != .start else { return }
            performMutation {
                automations[automationIndex].nodes.removeAll { $0.id == nodeID }
                automations[automationIndex].connections.removeAll {
                    $0.sourceNodeID == nodeID || $0.targetNodeID == nodeID
                }
                for index in automations[automationIndex].nodes.indices
                    where automations[automationIndex].nodes[index].repeatTargetNodeID == nodeID {
                    automations[automationIndex].nodes[index].repeatTargetNodeID = nil
                }
                automations[automationIndex].lastEdited = .now
                selectedNodeID = nil
            }
        } else if let connectionID = selectedConnectionID {
            performMutation {
                automations[automationIndex].connections.removeAll { $0.id == connectionID }
                automations[automationIndex].lastEdited = .now
                selectedConnectionID = nil
            }
        }
    }

    func beginContinuousEdit() {
        guard canEdit else { return }
        if continuousEditSnapshot == nil { continuousEditSnapshot = automations }
    }

    func autoArrangeSelected() {
        updateAutomation { automation in
            guard let start = automation.nodes.first(where: { $0.kind == .start }) else { return }
            var orderedIDs: [UUID] = []
            var visited = Set<UUID>()
            var cursor: UUID? = start.id
            while let nodeID = cursor, visited.insert(nodeID).inserted {
                orderedIDs.append(nodeID)
                cursor = automation.connections.first(where: { $0.sourceNodeID == nodeID })?.targetNodeID
            }

            let remainingIDs = automation.nodes.map(\.id).filter { !visited.contains($0) }
            for (offset, nodeID) in orderedIDs.enumerated() {
                guard let index = automation.nodes.firstIndex(where: { $0.id == nodeID }) else { continue }
                automation.nodes[index].position = WorkflowPoint(x: 420, y: Double(100 + offset * 105))
            }
            for (offset, nodeID) in remainingIDs.enumerated() {
                guard let index = automation.nodes.firstIndex(where: { $0.id == nodeID }) else { continue }
                automation.nodes[index].position = WorkflowPoint(x: 720, y: Double(120 + offset * 112))
            }
        }
    }

    func endContinuousEdit() {
        guard let snapshot = continuousEditSnapshot else { return }
        continuousEditSnapshot = nil
        guard snapshot != automations else { return }
        undoStack.append(snapshot)
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        guard canEdit, let previous = undoStack.popLast() else { return }
        redoStack.append(automations)
        automations = previous
        repairSelection()
    }

    func redo() {
        guard canEdit, let next = redoStack.popLast() else { return }
        undoStack.append(automations)
        automations = next
        repairSelection()
    }

    func saveNow() {
        persistenceTask?.cancel()
        try? storage.saveAutomations(automations)
    }

    func beginRun(totalSteps: Int) {
        runState = .running
        activeNodeID = nil
        completedNodeIDs = []
        failedNodeID = nil
        currentStep = 0
        self.totalSteps = totalSteps
        executionHistory = []
        activeExecutionRecordID = nil
        lastTestResult = nil
        statusMessage = selectedAutomation.map { "Running \($0.name)" } ?? "Running automation"
    }

    func beginNodeTest(_ node: AutomationNode) {
        runState = .running
        activeNodeID = node.id
        failedNodeID = nil
        completedNodeIDs = []
        currentStep = 1
        totalSteps = 1
        statusMessage = "Testing (node.kind.title)…"
        lastTestResult = AutomationNodeTestResult(nodeID: node.id, startedAt: .now, finishedAt: nil, status: .running, message: nil, actionsExecuted: nil)
        executionHistory = [AutomationExecutionRecord(id: UUID(), nodeID: node.id, title: node.kind.title, kind: node.kind, startedAt: .now, finishedAt: nil, status: .running, message: nil, isTest: true, actionsExecuted: nil)]
        activeExecutionRecordID = executionHistory.first?.id
    }

    func finishNodeTest(status: AutomationExecutionStatus, message: String? = nil, actionsExecuted: Int? = nil) {
        if let activeExecutionRecordID, let index = executionHistory.firstIndex(where: { $0.id == activeExecutionRecordID }) {
            executionHistory[index].finishedAt = .now
            executionHistory[index].status = status
            executionHistory[index].message = message
            executionHistory[index].actionsExecuted = actionsExecuted
        }
        if let result = lastTestResult {
            lastTestResult = AutomationNodeTestResult(nodeID: result.nodeID, startedAt: result.startedAt, finishedAt: .now, status: status, message: message, actionsExecuted: actionsExecuted)
        }
        activeExecutionRecordID = nil
        activeNodeID = nil
        runState = .idle
        statusMessage = message ?? (status == .completed ? "Node test completed" : status == .stopped ? "Node test stopped" : "Node test failed")
        if status == .completed { completedNodeIDs = Set([lastTestResult?.nodeID].compactMap { $0 }) }
        if status == .failed { failedNodeID = lastTestResult?.nodeID }
    }

    func duplicateNode(_ nodeID: UUID) {
        guard canEdit, let automation = selectedAutomation, let node = automation.nodes.first(where: { $0.id == nodeID }) else { return }
        var copy = node
        copy.id = UUID()
        copy.position = WorkflowPoint(x: node.position.x + 36, y: node.position.y + 36)
        copy.customTitle = node.customTitle.map { "\($0) Copy" } ?? "\(node.kind.title) Copy"
        updateAutomation { $0.nodes.append(copy) }
        selectedNodeID = copy.id
    }

    func renameNode(_ nodeID: UUID, to name: String) {
        guard canEdit else { return }
        updateNode(nodeID) { $0.customTitle = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : name }
    }

    func toggleNodeEnabled(_ nodeID: UUID) {
        guard canEdit else { return }
        updateNode(nodeID) { $0.isEnabled.toggle() }
    }

    func setActiveNode(_ node: AutomationNode, title: String, step: Int) {
        activeNodeID = node.id
        currentStep = step
        let record = AutomationExecutionRecord(
            id: UUID(),
            nodeID: node.id,
            title: title,
            kind: node.kind,
            startedAt: .now,
            finishedAt: nil,
            status: .running,
            message: nil
        )
        executionHistory.append(record)
        activeExecutionRecordID = record.id
    }

    func completeNode(_ id: UUID) {
        completedNodeIDs.insert(id)
        if activeNodeID == id { activeNodeID = nil }
        finishActiveExecution(status: .completed)
    }

    func failNode(_ id: UUID, message: String) {
        failedNodeID = id
        activeNodeID = nil
        statusMessage = message
        finishActiveExecution(status: .failed, message: message)
    }

    func stopActiveNode(message: String = "Stopped by user") {
        activeNodeID = nil
        finishActiveExecution(status: .stopped, message: message)
    }

    func setPaused(_ paused: Bool) {
        runState = paused ? .paused : .running
        statusMessage = paused ? "Automation paused" : "Automation resumed"
    }

    func finishRun(message: String = "Automation complete") {
        runState = .idle
        activeNodeID = nil
        statusMessage = message
    }

    func setStatusMessage(_ message: String) {
        statusMessage = message
    }

    func nodeRunState(_ id: UUID) -> AutomationNodeRunState {
        if failedNodeID == id { return .failed }
        if activeNodeID == id { return .running }
        if completedNodeIDs.contains(id) { return .complete }
        return .idle
    }

    private func performMutation(_ mutation: () -> Void) {
        guard canEdit else { return }
        let previous = automations
        mutation()
        guard previous != automations else { return }
        undoStack.append(previous)
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func finishActiveExecution(status: AutomationExecutionStatus, message: String? = nil) {
        guard let activeExecutionRecordID,
              let index = executionHistory.lastIndex(where: { $0.id == activeExecutionRecordID }) else { return }
        executionHistory[index].finishedAt = .now
        executionHistory[index].status = status
        executionHistory[index].message = message
        self.activeExecutionRecordID = nil
    }

    private func repairSelection() {
        if !automations.contains(where: { $0.id == selectedAutomationID }) {
            selectedAutomationID = automations.first?.id
        }
        if selectedAutomation?.nodes.contains(where: { $0.id == selectedNodeID }) != true {
            selectedNodeID = nil
        }
        if selectedAutomation?.connections.contains(where: { $0.id == selectedConnectionID }) != true {
            selectedConnectionID = nil
        }
    }

    private func schedulePersistence() {
        let snapshot = automations
        let storage = storage
        persistenceTask?.cancel()
        persistenceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            try? storage.saveAutomations(snapshot)
        }
    }
}
