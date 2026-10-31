import CoreGraphics
import Foundation

struct WorkflowPoint: Codable, Equatable, Hashable {
    var x: Double
    var y: Double

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    init(_ point: CGPoint) {
        x = Double(point.x)
        y = Double(point.y)
    }

    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

enum AutomationNodeKind: String, Codable, CaseIterable, Identifiable {
    case start, macro, wait, waitForWindow, ifElse, schedule, repeatFlow, loopBack, merge, stop, resetTimer, note

    var id: Self { self }

    var title: String {
        switch self {
        case .start: "Start"
        case .macro: "Macro"
        case .wait: "Wait"
        case .waitForWindow: "Wait for Window"
        case .ifElse: "If / Else"
        case .schedule: "Schedule"
        case .repeatFlow: "Repeat"
        case .loopBack: "Loop Back"
        case .merge: "Merge"
        case .stop: "Stop"
        case .resetTimer: "Reset Timer"
        case .note: "Note"
        }
    }

    var symbol: String {
        switch self {
        case .start: "play.fill"
        case .macro: "bolt.fill"
        case .wait: "clock.fill"
        case .waitForWindow: "macwindow"
        case .ifElse: "arrow.branch"
        case .schedule: "calendar.badge.clock"
        case .repeatFlow: "repeat"
        case .loopBack: "arrow.uturn.backward"
        case .merge: "arrow.triangle.merge"
        case .stop: "stop.fill"
        case .resetTimer: "timer"
        case .note: "note.text"
        }
    }

    var acceptsInput: Bool {
        switch self {
        case .start, .note: false
        default: true
        }
    }
    var providesOutput: Bool {
        switch self {
        case .stop, .note, .loopBack: false
        default: true
        }
    }
}

enum AutomationBranch: String, Codable, CaseIterable, Identifiable {
    case yes, no
    var id: Self { self }
    var title: String { self == .yes ? "Yes" : "No" }
}

enum AutomationConnectionStyle: String, Codable, CaseIterable, Identifiable {
    case bent, curved, straight
    var id: Self { self }
    var title: String { rawValue.capitalized }
}

enum AutomationConditionKind: String, Codable, CaseIterable, Identifiable {
    case windowOpen, elapsedTime, macroRunCount
    var id: Self { self }
    var title: String {
        switch self {
        case .windowOpen: "Window is open"
        case .elapsedTime: "Time has elapsed"
        case .macroRunCount: "Macro run count"
        }
    }
}

enum MacroPlaybackOverride: String, Codable, CaseIterable, Identifiable {
    case useMacroSetting, background, compatibility

    var id: Self { self }
    var title: String {
        switch self {
        case .useMacroSetting: "Use macro setting"
        case .background: "Background"
        case .compatibility: "Compatibility"
        }
    }

    func resolve(using fallback: MousePlaybackMode) -> MousePlaybackMode {
        switch self {
        case .useMacroSetting: fallback
        case .background: .background
        case .compatibility: .compatibility
        }
    }
}

enum AutomationScheduleRepeat: String, Codable, CaseIterable, Identifiable {
    case once, everyMinute, everyHour, everyDay

    var id: Self { self }
    var title: String {
        switch self {
        case .once: "Once"
        case .everyMinute: "Every minute"
        case .everyHour: "Every hour"
        case .everyDay: "Every day"
        }
    }
}

enum AutomationScheduleMode: String, Codable, CaseIterable, Identifiable {
    case atTime, interval
    var id: Self { self }
    var title: String { self == .atTime ? "At a time" : "Every interval" }
}

enum AutomationScheduleUnit: String, Codable, CaseIterable, Identifiable {
    case seconds, minutes, hours
    var id: Self { self }
    var title: String { rawValue.capitalized }
    var secondsPerUnit: Double {
        switch self {
        case .seconds: 1
        case .minutes: 60
        case .hours: 3600
        }
    }
}

enum AutomationRepeatMode: String, Codable, CaseIterable, Identifiable {
    case count, infinite, duration
    var id: Self { self }
    var title: String {
        switch self {
        case .count: "A number of times"
        case .infinite: "Until stopped"
        case .duration: "For a duration"
        }
    }
}

enum AutomationStartMode: String, Codable, CaseIterable, Identifiable {
    case immediately, scheduled
    var id: Self { self }
    var title: String { self == .immediately ? "Immediately" : "From Schedule node" }
}

struct AutomationNode: Identifiable, Codable, Equatable {
    var id = UUID()
    var kind: AutomationNodeKind
    var position: WorkflowPoint
    var macroID: UUID?
    var playbackOverride: MacroPlaybackOverride = .useMacroSetting
    var targetBundleIdentifier: String?
    var macroLoops: Int = 1
    var waitDuration: Double = 30
    var waitForBundleIdentifier: String?
    var waitForWindowTitle = ""
    var waitForWindowTimeout: Double = 60
    var conditionBundleIdentifier: String?
    var conditionWindowTitle = ""
    var conditionKind: AutomationConditionKind = .windowOpen
    var conditionDuration: Double = 9
    var conditionDurationUnit: AutomationScheduleUnit = .minutes
    var conditionElapsedMilliseconds: Int?
    var conditionMacroID: UUID?
    var conditionMacroRunCount: Int = 1
    var scheduleMinuteOfDay: Int = 22 * 60
    var scheduleRepeat: AutomationScheduleRepeat = .once
    var scheduleMode: AutomationScheduleMode = .atTime
    var scheduleInterval: Double = 5
    var scheduleIntervalUnit: AutomationScheduleUnit = .minutes
    var repeatCount: Int = 5
    var repeatInfinitely = false
    var repeatForDuration = false
    var repeatDuration: Double = 9
    var repeatDurationUnit: AutomationScheduleUnit = .minutes
    var repeatTargetNodeID: UUID?
    var jumpTargetNodeID: UUID?
    var customTitle: String?
    var noteText = ""
    var isEnabled: Bool = true

    var resolvedConditionElapsedMilliseconds: Int {
        if let conditionElapsedMilliseconds { return max(0, conditionElapsedMilliseconds) }
        guard conditionDuration.isFinite else { return 0 }
        return max(0, Int((conditionDuration * conditionDurationUnit.secondsPerUnit * 1_000).rounded()))
    }

    var conditionElapsedHours: Int {
        get { resolvedConditionElapsedMilliseconds / 3_600_000 }
        set { setElapsedComponents(hours: newValue, minutes: conditionElapsedMinutes, seconds: conditionElapsedSeconds, milliseconds: conditionElapsedSubsecond) }
    }
    var conditionElapsedMinutes: Int {
        get { (resolvedConditionElapsedMilliseconds / 60_000) % 60 }
        set { setElapsedComponents(hours: conditionElapsedHours, minutes: newValue, seconds: conditionElapsedSeconds, milliseconds: conditionElapsedSubsecond) }
    }
    var conditionElapsedSeconds: Int {
        get { (resolvedConditionElapsedMilliseconds / 1_000) % 60 }
        set { setElapsedComponents(hours: conditionElapsedHours, minutes: conditionElapsedMinutes, seconds: newValue, milliseconds: conditionElapsedSubsecond) }
    }
    var conditionElapsedSubsecond: Int {
        get { resolvedConditionElapsedMilliseconds % 1_000 }
        set { setElapsedComponents(hours: conditionElapsedHours, minutes: conditionElapsedMinutes, seconds: conditionElapsedSeconds, milliseconds: newValue) }
    }

    private mutating func setElapsedComponents(hours: Int, minutes: Int, seconds: Int, milliseconds: Int) {
        let safeHours = min(max(hours, 0), 999_999)
        let safeMinutes = min(max(minutes, 0), 59)
        let safeSeconds = min(max(seconds, 0), 59)
        let safeMilliseconds = min(max(milliseconds, 0), 999)
        conditionElapsedMilliseconds = safeHours * 3_600_000 + safeMinutes * 60_000 + safeSeconds * 1_000 + safeMilliseconds
    }

    private enum CodingKeys: String, CodingKey { case id, kind, position, macroID, playbackOverride, targetBundleIdentifier, macroLoops, waitDuration, waitForBundleIdentifier, waitForWindowTitle, waitForWindowTimeout, conditionBundleIdentifier, conditionWindowTitle, conditionKind, conditionDuration, conditionDurationUnit, conditionElapsedMilliseconds, conditionMacroID, conditionMacroRunCount, scheduleMinuteOfDay, scheduleRepeat, scheduleMode, scheduleInterval, scheduleIntervalUnit, repeatCount, repeatInfinitely, repeatForDuration, repeatDuration, repeatDurationUnit, repeatTargetNodeID, jumpTargetNodeID, customTitle, noteText, isEnabled }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(AutomationNodeKind.self, forKey: .kind)
        position = try c.decode(WorkflowPoint.self, forKey: .position)
        macroID = try c.decodeIfPresent(UUID.self, forKey: .macroID)
        playbackOverride = try c.decodeIfPresent(MacroPlaybackOverride.self, forKey: .playbackOverride) ?? .useMacroSetting
        targetBundleIdentifier = try c.decodeIfPresent(String.self, forKey: .targetBundleIdentifier)
        macroLoops = try c.decodeIfPresent(Int.self, forKey: .macroLoops) ?? 1
        waitDuration = try c.decodeIfPresent(Double.self, forKey: .waitDuration) ?? 30
        waitForBundleIdentifier = try c.decodeIfPresent(String.self, forKey: .waitForBundleIdentifier)
        waitForWindowTitle = try c.decodeIfPresent(String.self, forKey: .waitForWindowTitle) ?? ""
        waitForWindowTimeout = try c.decodeIfPresent(Double.self, forKey: .waitForWindowTimeout) ?? 60
        conditionBundleIdentifier = try c.decodeIfPresent(String.self, forKey: .conditionBundleIdentifier)
        conditionWindowTitle = try c.decodeIfPresent(String.self, forKey: .conditionWindowTitle) ?? ""
        conditionKind = try c.decodeIfPresent(AutomationConditionKind.self, forKey: .conditionKind) ?? .windowOpen
        conditionDuration = try c.decodeIfPresent(Double.self, forKey: .conditionDuration) ?? 9
        conditionDurationUnit = try c.decodeIfPresent(AutomationScheduleUnit.self, forKey: .conditionDurationUnit) ?? .minutes
        conditionElapsedMilliseconds = try c.decodeIfPresent(Int.self, forKey: .conditionElapsedMilliseconds)
        conditionMacroID = try c.decodeIfPresent(UUID.self, forKey: .conditionMacroID)
        conditionMacroRunCount = try c.decodeIfPresent(Int.self, forKey: .conditionMacroRunCount) ?? 1
        scheduleMinuteOfDay = try c.decodeIfPresent(Int.self, forKey: .scheduleMinuteOfDay) ?? 22 * 60
        scheduleRepeat = try c.decodeIfPresent(AutomationScheduleRepeat.self, forKey: .scheduleRepeat) ?? .once
        scheduleMode = try c.decodeIfPresent(AutomationScheduleMode.self, forKey: .scheduleMode) ?? .atTime
        scheduleInterval = try c.decodeIfPresent(Double.self, forKey: .scheduleInterval) ?? 5
        scheduleIntervalUnit = try c.decodeIfPresent(AutomationScheduleUnit.self, forKey: .scheduleIntervalUnit) ?? .minutes
        repeatCount = try c.decodeIfPresent(Int.self, forKey: .repeatCount) ?? 5
        repeatInfinitely = try c.decodeIfPresent(Bool.self, forKey: .repeatInfinitely) ?? false
        repeatForDuration = try c.decodeIfPresent(Bool.self, forKey: .repeatForDuration) ?? false
        repeatDuration = try c.decodeIfPresent(Double.self, forKey: .repeatDuration) ?? 9
        repeatDurationUnit = try c.decodeIfPresent(AutomationScheduleUnit.self, forKey: .repeatDurationUnit) ?? .minutes
        repeatTargetNodeID = try c.decodeIfPresent(UUID.self, forKey: .repeatTargetNodeID)
        jumpTargetNodeID = try c.decodeIfPresent(UUID.self, forKey: .jumpTargetNodeID)
        customTitle = try c.decodeIfPresent(String.self, forKey: .customTitle)
        noteText = try c.decodeIfPresent(String.self, forKey: .noteText) ?? ""
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(kind, forKey: .kind); try c.encode(position, forKey: .position)
        try c.encodeIfPresent(macroID, forKey: .macroID); try c.encode(playbackOverride, forKey: .playbackOverride)
        try c.encodeIfPresent(targetBundleIdentifier, forKey: .targetBundleIdentifier); try c.encode(macroLoops, forKey: .macroLoops)
        try c.encode(waitDuration, forKey: .waitDuration); try c.encode(scheduleMinuteOfDay, forKey: .scheduleMinuteOfDay)
        try c.encodeIfPresent(waitForBundleIdentifier, forKey: .waitForBundleIdentifier)
        try c.encode(waitForWindowTitle, forKey: .waitForWindowTitle); try c.encode(waitForWindowTimeout, forKey: .waitForWindowTimeout)
        try c.encodeIfPresent(conditionBundleIdentifier, forKey: .conditionBundleIdentifier)
        try c.encode(conditionWindowTitle, forKey: .conditionWindowTitle)
        try c.encode(conditionKind, forKey: .conditionKind); try c.encode(conditionDuration, forKey: .conditionDuration)
        try c.encode(conditionDurationUnit, forKey: .conditionDurationUnit)
        try c.encodeIfPresent(conditionElapsedMilliseconds, forKey: .conditionElapsedMilliseconds)
        try c.encodeIfPresent(conditionMacroID, forKey: .conditionMacroID)
        try c.encode(conditionMacroRunCount, forKey: .conditionMacroRunCount)
        try c.encode(scheduleRepeat, forKey: .scheduleRepeat); try c.encode(repeatCount, forKey: .repeatCount)
        try c.encode(scheduleMode, forKey: .scheduleMode); try c.encode(scheduleInterval, forKey: .scheduleInterval)
        try c.encode(scheduleIntervalUnit, forKey: .scheduleIntervalUnit)
        try c.encode(repeatInfinitely, forKey: .repeatInfinitely); try c.encode(repeatForDuration, forKey: .repeatForDuration)
        try c.encode(repeatDuration, forKey: .repeatDuration); try c.encode(repeatDurationUnit, forKey: .repeatDurationUnit)
        try c.encodeIfPresent(repeatTargetNodeID, forKey: .repeatTargetNodeID)
        try c.encodeIfPresent(jumpTargetNodeID, forKey: .jumpTargetNodeID)
        try c.encodeIfPresent(customTitle, forKey: .customTitle); try c.encode(noteText, forKey: .noteText)
        try c.encode(isEnabled, forKey: .isEnabled)
    }

    init(
        id: UUID = UUID(),
        kind: AutomationNodeKind,
        position: WorkflowPoint,
        macroID: UUID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.position = position
        self.macroID = macroID
    }
}

struct AutomationConnection: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var sourceNodeID: UUID
    var targetNodeID: UUID
    var branch: AutomationBranch? = nil
    var style: AutomationConnectionStyle? = nil
    var bendPoint: WorkflowPoint? = nil

    // Older saved workflows may contain a style, but the editor now uses one
    // consistent obstacle-aware bent connector style for every wire.
    var resolvedStyle: AutomationConnectionStyle { .bent }

    private enum CodingKeys: String, CodingKey { case id, sourceNodeID, targetNodeID, branch, style, bendPoint }

    init(id: UUID = UUID(), sourceNodeID: UUID, targetNodeID: UUID, branch: AutomationBranch? = nil, style: AutomationConnectionStyle? = nil, bendPoint: WorkflowPoint? = nil) {
        self.id = id
        self.sourceNodeID = sourceNodeID
        self.targetNodeID = targetNodeID
        self.branch = branch
        self.style = style
        self.bendPoint = bendPoint
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        sourceNodeID = try values.decode(UUID.self, forKey: .sourceNodeID)
        targetNodeID = try values.decode(UUID.self, forKey: .targetNodeID)
        branch = try values.decodeIfPresent(AutomationBranch.self, forKey: .branch)
        style = try values.decodeIfPresent(AutomationConnectionStyle.self, forKey: .style)
        bendPoint = try values.decodeIfPresent(WorkflowPoint.self, forKey: .bendPoint)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(sourceNodeID, forKey: .sourceNodeID)
        try values.encode(targetNodeID, forKey: .targetNodeID)
        try values.encodeIfPresent(branch, forKey: .branch)
        try values.encodeIfPresent(style, forKey: .style)
        try values.encodeIfPresent(bendPoint, forKey: .bendPoint)
    }
}

struct WorkflowFrame: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

struct AutomationSection: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    /// Canvas-space bounds, with the origin at the frame's top-left corner.
    var frame: WorkflowFrame
}

struct AutomationDefinition: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var automationDescription = ""
    var startMode: AutomationStartMode = .immediately
    var nodes: [AutomationNode]
    var connections: [AutomationConnection]
    var sections: [AutomationSection]
    var lastEdited = Date.now

    init(
        id: UUID = UUID(),
        name: String,
        automationDescription: String = "",
        startMode: AutomationStartMode = .immediately,
        nodes: [AutomationNode],
        connections: [AutomationConnection],
        sections: [AutomationSection] = [],
        lastEdited: Date = .now
    ) {
        self.id = id
        self.name = name
        self.automationDescription = automationDescription
        self.startMode = startMode
        self.nodes = nodes
        self.connections = connections
        self.sections = sections
        self.lastEdited = lastEdited
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, automationDescription, startMode, nodes, connections, sections, lastEdited
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decode(String.self, forKey: .name)
        automationDescription = try values.decodeIfPresent(String.self, forKey: .automationDescription) ?? ""
        startMode = try values.decodeIfPresent(AutomationStartMode.self, forKey: .startMode) ?? .immediately
        nodes = try values.decode([AutomationNode].self, forKey: .nodes)
        connections = try values.decodeIfPresent([AutomationConnection].self, forKey: .connections) ?? []
        // Sections were added after workflows had already been saved, so they
        // must remain optional in older files and decode as an empty collection.
        sections = try values.decodeIfPresent([AutomationSection].self, forKey: .sections) ?? []
        lastEdited = try values.decodeIfPresent(Date.self, forKey: .lastEdited) ?? .now
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(automationDescription, forKey: .automationDescription)
        try values.encode(startMode, forKey: .startMode)
        try values.encode(nodes, forKey: .nodes)
        try values.encode(connections, forKey: .connections)
        try values.encode(sections, forKey: .sections)
        try values.encode(lastEdited, forKey: .lastEdited)
    }

    static func blank(name: String = "Untitled Automation") -> AutomationDefinition {
        let start = AutomationNode(kind: .start, position: WorkflowPoint(x: 420, y: 150))
        let stop = AutomationNode(kind: .stop, position: WorkflowPoint(x: 420, y: 390))
        return AutomationDefinition(name: name, nodes: [start, stop], connections: [])
    }

    static func example(macros: [MacroDefinition]) -> AutomationDefinition {
        let start = AutomationNode(kind: .start, position: WorkflowPoint(x: 420, y: 100))
        var nodes = [start]
        var connections: [AutomationConnection] = []
        var previousID = start.id
        var firstLoopTargetID: UUID?
        var y = 205.0

        if let macro = macros.first {
            let macroNode = AutomationNode(kind: .macro, position: WorkflowPoint(x: 420, y: y), macroID: macro.id)
            nodes.append(macroNode)
            firstLoopTargetID = macroNode.id
            connections.append(AutomationConnection(sourceNodeID: previousID, targetNodeID: macroNode.id))
            previousID = macroNode.id
            y += 105
        }

        let wait = AutomationNode(kind: .wait, position: WorkflowPoint(x: 420, y: y))
        nodes.append(wait)
        if firstLoopTargetID == nil { firstLoopTargetID = wait.id }
        connections.append(AutomationConnection(sourceNodeID: previousID, targetNodeID: wait.id))
        previousID = wait.id
        y += 105

        if macros.count > 1 {
            let macroNode = AutomationNode(kind: .macro, position: WorkflowPoint(x: 420, y: y), macroID: macros[1].id)
            nodes.append(macroNode)
            connections.append(AutomationConnection(sourceNodeID: previousID, targetNodeID: macroNode.id))
            previousID = macroNode.id
            y += 105
        }

        var repeatNode = AutomationNode(kind: .repeatFlow, position: WorkflowPoint(x: 420, y: y))
        repeatNode.repeatCount = 5
        repeatNode.repeatTargetNodeID = firstLoopTargetID
        nodes.append(repeatNode)
        connections.append(AutomationConnection(sourceNodeID: previousID, targetNodeID: repeatNode.id))
        previousID = repeatNode.id
        y += 105

        let stop = AutomationNode(kind: .stop, position: WorkflowPoint(x: 420, y: y))
        nodes.append(stop)
        connections.append(AutomationConnection(sourceNodeID: previousID, targetNodeID: stop.id))
        return AutomationDefinition(
            name: "Night Farming",
            automationDescription: "A visual workflow built from your saved macros.",
            nodes: nodes,
            connections: connections
        )
    }
}

enum AutomationRunState: String, Equatable {
    case idle = "Automation Ready"
    case running = "Running"
    case paused = "Paused"
}

enum AutomationNodeRunState: Equatable {
    case idle, running, complete, failed
}

enum AutomationValidationSeverity: Int, Comparable {
    case warning = 0
    case error = 1

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct AutomationValidationIssue: Identifiable, Equatable {
    let id: String
    let severity: AutomationValidationSeverity
    let nodeID: UUID?
    let message: String
}

enum AutomationExecutionStatus: Equatable {
    case running, completed, failed, stopped
}

struct AutomationNodeTestResult: Equatable {
    let nodeID: UUID
    let startedAt: Date
    var finishedAt: Date?
    var status: AutomationExecutionStatus
    var message: String?
    var actionsExecuted: Int?

    var duration: TimeInterval { (finishedAt ?? Date()).timeIntervalSince(startedAt) }
}

struct AutomationExecutionRecord: Identifiable, Equatable {
    let id: UUID
    let nodeID: UUID
    let title: String
    let kind: AutomationNodeKind
    let startedAt: Date
    var finishedAt: Date?
    var status: AutomationExecutionStatus
    var message: String?
    var isTest: Bool = false
    var actionsExecuted: Int? = nil

    var duration: TimeInterval {
        (finishedAt ?? Date()).timeIntervalSince(startedAt)
    }
}

extension AutomationDefinition {
    func validationIssues(availableMacroIDs: Set<UUID>) -> [AutomationValidationIssue] {
        var issues: [AutomationValidationIssue] = []
        let nodeIDs = Set(nodes.map(\.id))
        let starts = nodes.filter { $0.kind == .start }

        func add(
            _ code: String,
            _ severity: AutomationValidationSeverity,
            nodeID: UUID? = nil,
            _ message: String
        ) {
            issues.append(AutomationValidationIssue(
                id: "\(code):\(nodeID?.uuidString ?? "workflow")",
                severity: severity,
                nodeID: nodeID,
                message: message
            ))
        }

        if starts.isEmpty {
            add("missing-start", .error, "Add a Start node to the workflow.")
        } else if starts.count > 1 {
            add("multiple-starts", .error, "The workflow can only contain one Start node.")
        }

        for connection in connections where
            !nodeIDs.contains(connection.sourceNodeID) || !nodeIDs.contains(connection.targetNodeID) {
            add("broken-connection-\(connection.id)", .error, "A connection references a node that no longer exists.")
        }

        let validConnections = connections.filter {
            nodeIDs.contains($0.sourceNodeID) && nodeIDs.contains($0.targetNodeID)
        }
        let nodesByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        for connection in validConnections {
            if connection.sourceNodeID == connection.targetNodeID {
                add("self-connection", .error, nodeID: connection.sourceNodeID, "A node cannot connect to itself.")
            }
            if nodesByID[connection.sourceNodeID]?.kind.providesOutput != true {
                add("invalid-source", .error, nodeID: connection.sourceNodeID, "This node cannot provide an outgoing connection.")
            }
            if nodesByID[connection.targetNodeID]?.kind.acceptsInput != true {
                add("invalid-target", .error, nodeID: connection.targetNodeID, "This node cannot accept an incoming connection.")
            }
            let sourceKind = nodesByID[connection.sourceNodeID]?.kind
            if sourceKind == .ifElse && connection.branch == nil {
                add("missing-branch-label", .error, nodeID: connection.sourceNodeID, "Choose whether this connection follows the Yes or No path.")
            } else if sourceKind != .ifElse && connection.branch != nil {
                add("unexpected-branch-label", .error, nodeID: connection.sourceNodeID, "Only an If / Else node can have Yes or No connections.")
            }
        }
        let outgoing = Dictionary(grouping: validConnections, by: \.sourceNodeID)

        for (nodeID, links) in outgoing where links.count > 1 {
            if nodesByID[nodeID]?.kind != .ifElse {
                add("multiple-outputs", .error, nodeID: nodeID, "This node has more than one outgoing connection.")
            } else {
                for branch in AutomationBranch.allCases where links.filter({ $0.branch == branch }).count > 1 {
                    add("duplicate-branch-\(branch.rawValue)", .error, nodeID: nodeID, "The \(branch.title) path has more than one outgoing connection.")
                }
            }
        }
        for node in nodes {
            if node.kind == .ifElse {
                switch node.conditionKind {
                case .windowOpen:
                    if node.conditionBundleIdentifier == nil && node.conditionWindowTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        add("missing-condition", .error, nodeID: node.id, "Choose an application or enter part of a window title to check.")
                    }
                case .elapsedTime:
                    if node.resolvedConditionElapsedMilliseconds < 1 {
                        add("invalid-condition-duration", .error, nodeID: node.id, "Elapsed time must be greater than zero.")
                    }
                case .macroRunCount:
                    let conditionMacroExists = node.conditionMacroID.map(availableMacroIDs.contains) ?? false
                    if !conditionMacroExists || node.conditionMacroRunCount < 1 {
                        add("invalid-macro-condition", .error, nodeID: node.id, "Choose a macro and a run count of at least 1.")
                    }
                }
            }
            if node.kind == .ifElse {
                let branches = Set(outgoing[node.id, default: []].compactMap(\.branch))
                for branch in AutomationBranch.allCases where !branches.contains(branch) {
                    add("missing-branch-\(branch.rawValue)", .error, nodeID: node.id, "Connect the \(branch.title) output to a node.")
                }
            }
            if node.kind == .macro {
                guard let macroID = node.macroID, availableMacroIDs.contains(macroID) else {
                    add("missing-macro", .error, nodeID: node.id, "Select an existing macro for this node.")
                    continue
                }
            }
            if node.kind == .wait, node.waitDuration < 0 {
                add("negative-wait", .error, nodeID: node.id, "Wait duration cannot be negative.")
            }
            if node.kind == .waitForWindow {
                if node.waitForBundleIdentifier == nil && node.waitForWindowTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    add("missing-window-match", .error, nodeID: node.id, "Choose an application or enter part of a window title.")
                }
                if node.waitForWindowTimeout <= 0 {
                    add("invalid-window-timeout", .error, nodeID: node.id, "Window wait timeout must be greater than zero.")
                }
            }
            if node.kind == .repeatFlow, node.repeatInfinitely && !node.repeatForDuration {
                add("infinite-repeat", .warning, nodeID: node.id, "This workflow repeats until you stop it manually.")
            }
            if node.kind == .repeatFlow {
                if !node.repeatInfinitely && !node.repeatForDuration && node.repeatCount < 1 {
                    add("invalid-repeat-count", .error, nodeID: node.id, "Repeat count must be at least 1.")
                }
                if node.repeatForDuration &&
                    (!node.repeatDuration.isFinite || node.repeatDuration < 1 || node.repeatDuration > 999 || node.repeatDuration.rounded() != node.repeatDuration) {
                    add("invalid-repeat-duration", .error, nodeID: node.id, "Repeat duration must be a whole number from 1 to 999.")
                }
                guard let targetID = node.repeatTargetNodeID, nodeIDs.contains(targetID) else {
                    add("missing-repeat-target", .error, nodeID: node.id, "Choose where this Repeat node should loop back to.")
                    continue
                }
                if targetID == node.id {
                    add("repeat-self-target", .error, nodeID: node.id, "Repeat cannot loop back to itself.")
                }
            }
            if node.kind == .loopBack {
                guard let targetID = node.jumpTargetNodeID, nodeIDs.contains(targetID) else {
                    add("missing-loop-back-target", .error, nodeID: node.id, "Choose the node this path should return to.")
                    continue
                }
                if targetID == node.id || nodesByID[targetID]?.kind == .loopBack || nodesByID[targetID]?.kind == .note || nodesByID[targetID]?.kind == .stop {
                    add("invalid-loop-back-target", .error, nodeID: node.id, "Choose a workflow node that can continue execution.")
                }
            }
            if node.kind == .schedule && !(0...1439).contains(node.scheduleMinuteOfDay) {
                add("invalid-schedule", .error, nodeID: node.id, "Choose a valid time for this Schedule node.")
            }
            if node.kind == .schedule && node.scheduleMode == .interval &&
                (!node.scheduleInterval.isFinite || node.scheduleInterval < 1 || node.scheduleInterval > 999 || node.scheduleInterval.rounded() != node.scheduleInterval) {
                add("invalid-schedule-interval", .error, nodeID: node.id, "Schedule interval must be a whole number from 1 to 999.")
            }
        }

        var reachable = Set<UUID>()
        if let start = starts.first {
            var pending = [start.id]
            while let nodeID = pending.popLast() {
                guard reachable.insert(nodeID).inserted else { continue }
                pending.append(contentsOf: outgoing[nodeID, default: []].map(\.targetNodeID))
                if let loopTarget = nodesByID[nodeID]?.kind == .loopBack ? nodesByID[nodeID]?.jumpTargetNodeID : nil {
                    pending.append(loopTarget)
                }
            }

            let hasReachableStop = nodes.contains { $0.kind == .stop && reachable.contains($0.id) }
            let hasReachableLoopBack = nodes.contains { $0.kind == .loopBack && reachable.contains($0.id) }
            if !hasReachableStop {
                if hasReachableLoopBack {
                    add("manual-stop-loop", .warning, nodeID: start.id, "This workflow loops until you stop it manually.")
                } else {
                    add("no-reachable-stop", .error, nodeID: start.id, "Connect the workflow to a Stop node or add a Loop Back node for a manually stopped loop.")
                }
            }
        }

        for node in nodes where !reachable.contains(node.id) && node.kind != .note {
            add("unreachable", .warning, nodeID: node.id, "This node is not reachable from Start.")
        }

        for repeatNode in nodes where repeatNode.kind == .repeatFlow {
            guard let targetID = repeatNode.repeatTargetNodeID, nodeIDs.contains(targetID) else { continue }
            if !reachable.contains(targetID) {
                add("unreachable-repeat-target", .error, nodeID: repeatNode.id, "The selected loop target is not reachable from Start.")
                continue
            }
            var pending = [targetID]
            var traversed = Set<UUID>()
            var reachesRepeat = false
            while let current = pending.popLast() {
                guard traversed.insert(current).inserted else { continue }
                if current == repeatNode.id {
                    reachesRepeat = true
                    break
                }
                pending.append(contentsOf: outgoing[current, default: []].map(\.targetNodeID))
            }
            if !reachesRepeat {
                add("repeat-target-order", .error, nodeID: repeatNode.id, "Choose a node that runs before this Repeat node.")
            }
        }
        for node in nodes where reachable.contains(node.id) && node.kind.providesOutput
            && outgoing[node.id, default: []].isEmpty
            && !(node.kind == .repeatFlow && node.repeatInfinitely && !node.repeatForDuration
                 && node.repeatTargetNodeID.map(nodeIDs.contains) == true) {
            add("dead-end", .error, nodeID: node.id, "This execution path ends before reaching Stop.")
        }

        var visiting = Set<UUID>()
        var visited = Set<UUID>()
        var cycleNodes = Set<UUID>()
        func visit(_ nodeID: UUID) {
            if visiting.contains(nodeID) {
                cycleNodes.insert(nodeID)
                return
            }
            guard visited.insert(nodeID).inserted else { return }
            visiting.insert(nodeID)
            for connection in outgoing[nodeID, default: []] {
                if visiting.contains(connection.targetNodeID) {
                    cycleNodes.insert(nodeID)
                    cycleNodes.insert(connection.targetNodeID)
                } else {
                    visit(connection.targetNodeID)
                }
            }
            visiting.remove(nodeID)
        }
        for node in nodes { visit(node.id) }
        for nodeID in cycleNodes {
            add("cycle", .error, nodeID: nodeID, "Direct connection cycles are not allowed. Use a Repeat node instead.")
        }

        return issues.sorted {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            return $0.message < $1.message
        }
    }
}
