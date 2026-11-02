import Foundation
import CoreGraphics

enum SidebarDestination: String, CaseIterable, Identifiable {
    case macros = "Macros"
    case recorder = "Recorder"
    case target = "Target"
    case logs = "Logs"
    case automation = "Automation"
    case settings = "Settings"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .macros: "command.square"
        case .recorder: "record.circle"
        case .target: "macwindow"
        case .logs: "text.alignleft"
        case .automation: "point.3.connected.trianglepath.dotted"
        case .settings: "gearshape"
        }
    }
}

enum MacroActionType: String, Codable, CaseIterable, Identifiable {
    case keyDown, keyUp, keyPress, holdKey, wait
    case leftClick, rightClick, middleClick, mouseDown, mouseUp, move, scroll

    var id: Self { self }

    var title: String {
        switch self {
        case .keyDown: "Key Down"
        case .keyUp: "Key Up"
        case .keyPress: "Key Press"
        case .holdKey: "Hold Key"
        case .wait: "Wait"
        case .leftClick: "Left Click"
        case .rightClick: "Right Click"
        case .middleClick: "Middle Click"
        case .mouseDown: "Mouse Down"
        case .mouseUp: "Mouse Up"
        case .move: "Move Pointer"
        case .scroll: "Scroll"
        }
    }

    var symbol: String {
        switch self {
        case .keyDown: "arrow.down.to.line"
        case .keyUp: "arrow.up.to.line"
        case .keyPress: "keyboard"
        case .holdKey: "hand.tap"
        case .wait: "clock"
        case .leftClick: "cursorarrow.click"
        case .rightClick: "cursorarrow.click.2"
        case .middleClick: "computermouse"
        case .mouseDown: "arrow.down.circle"
        case .mouseUp: "arrow.up.circle"
        case .move: "arrow.up.and.down.and.arrow.left.and.right"
        case .scroll: "scroll"
        }
    }

    var tintName: String {
        switch self {
        case .keyDown, .keyUp, .keyPress, .holdKey: "blue"
        case .wait: "orange"
        case .scroll: "teal"
        default: "purple"
        }
    }
}

enum MacroMouseButton: String, Codable, CaseIterable, Identifiable, Hashable {
    case left, right, middle

    var id: Self { self }
    var title: String { rawValue.capitalized }
}

enum MacroScrollUnit: String, Codable, Equatable {
    case pixel, line
}

struct MacroAction: Identifiable, Codable, Equatable {
    var id = UUID()
    var type: MacroActionType
    var label: String?
    var key: String?
    var duration: Double
    var delay: Double = 0
    var x: Double?
    var y: Double?
    var recordedScreenX: Double?
    var recordedScreenY: Double?
    var mouseButton: MacroMouseButton = .left
    var clickCount: Int = 1
    var scrollDeltaX: Double = 0
    var scrollDeltaY: Double = 0
    var scrollUnit: MacroScrollUnit = .pixel
    var usesWindowCoordinates = true
    var isEnabled = true
    var isKeyRepeat = false

    private enum CodingKeys: String, CodingKey {
        case id, type, label, key, duration, delay, x, y, recordedScreenX, recordedScreenY, mouseButton, clickCount
        case scrollDeltaX, scrollDeltaY, scrollUnit, usesWindowCoordinates, isEnabled, isKeyRepeat
    }

    init(
        id: UUID = UUID(),
        type: MacroActionType,
        label: String? = nil,
        key: String?,
        duration: Double,
        delay: Double = 0,
        x: Double? = nil,
        y: Double? = nil,
        recordedScreenX: Double? = nil,
        recordedScreenY: Double? = nil,
        mouseButton: MacroMouseButton = .left,
        clickCount: Int = 1,
        scrollDeltaX: Double = 0,
        scrollDeltaY: Double = 0,
        scrollUnit: MacroScrollUnit = .pixel,
        usesWindowCoordinates: Bool = true,
        isEnabled: Bool = true,
        isKeyRepeat: Bool = false
    ) {
        self.id = id
        self.type = type
        self.label = label
        self.key = key
        self.duration = duration
        self.delay = delay
        self.x = x
        self.y = y
        self.recordedScreenX = recordedScreenX
        self.recordedScreenY = recordedScreenY
        self.mouseButton = mouseButton
        self.clickCount = clickCount
        self.scrollDeltaX = scrollDeltaX
        self.scrollDeltaY = scrollDeltaY
        self.scrollUnit = scrollUnit
        self.usesWindowCoordinates = usesWindowCoordinates
        self.isEnabled = isEnabled
        self.isKeyRepeat = isKeyRepeat
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        type = try values.decode(MacroActionType.self, forKey: .type)
        label = try values.decodeIfPresent(String.self, forKey: .label)
        key = try values.decodeIfPresent(String.self, forKey: .key)
        duration = try values.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        delay = try values.decodeIfPresent(Double.self, forKey: .delay) ?? 0
        x = try values.decodeIfPresent(Double.self, forKey: .x)
        y = try values.decodeIfPresent(Double.self, forKey: .y)
        recordedScreenX = try values.decodeIfPresent(Double.self, forKey: .recordedScreenX)
        recordedScreenY = try values.decodeIfPresent(Double.self, forKey: .recordedScreenY)
        mouseButton = try values.decodeIfPresent(MacroMouseButton.self, forKey: .mouseButton) ?? .left
        clickCount = max(1, try values.decodeIfPresent(Int.self, forKey: .clickCount) ?? 1)
        scrollDeltaX = try values.decodeIfPresent(Double.self, forKey: .scrollDeltaX) ?? 0
        scrollDeltaY = try values.decodeIfPresent(Double.self, forKey: .scrollDeltaY) ?? 0
        scrollUnit = try values.decodeIfPresent(MacroScrollUnit.self, forKey: .scrollUnit) ?? .pixel
        usesWindowCoordinates = try values.decodeIfPresent(Bool.self, forKey: .usesWindowCoordinates) ?? true
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        isKeyRepeat = try values.decodeIfPresent(Bool.self, forKey: .isKeyRepeat) ?? false
    }

    var summary: String {
        switch type {
        case .wait: return String(format: "%.3f seconds", duration)
        case .holdKey: return "\(key?.uppercased() ?? "Key") for \(String(format: "%.3f", duration)) seconds"
        case .keyDown, .keyUp, .keyPress: return key?.uppercased() ?? "Choose a key"
        case .move:
            return "\(usesWindowCoordinates ? "Window" : "Screen") · \(Int(x ?? 0)), \(Int(y ?? 0))"
        case .scroll:
            return "Horizontal \(Int(scrollDeltaX)) · Vertical \(Int(scrollDeltaY))"
        case .leftClick, .rightClick, .middleClick:
            let count = clickCount > 1 ? "\(clickCount)× · " : ""
            return "\(count)\(usesWindowCoordinates ? "Window" : "Screen") · \(Int(x ?? 0)), \(Int(y ?? 0))"
        default:
            return delay > 0 ? "Delay \(String(format: "%.3f", delay)) seconds" : "No delay"
        }
    }
}

enum LoopMode: String, Codable, CaseIterable, Identifiable {
    case once, count, infinite
    var id: Self { self }
    var title: String { self == .once ? "Run Once" : self == .count ? "Repeat" : "Infinite" }
}

struct MacroDefinition: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var isFavorite = false
    var targetBundleIdentifier: String?
    var actions: [MacroAction]
    var loopMode: LoopMode = .once
    var loopCount = 2
    var mousePlaybackMode: MousePlaybackMode = .background
    var recordedWindowWidth: Double?
    var recordedWindowHeight: Double?
    var recordedWindowOriginX: Double?
    var recordedWindowOriginY: Double?

    private enum CodingKeys: String, CodingKey {
        case id, name, isFavorite, targetBundleIdentifier, actions, loopMode, loopCount
        case mousePlaybackMode, recordedWindowWidth, recordedWindowHeight, recordedWindowOriginX, recordedWindowOriginY
    }

    init(
        id: UUID = UUID(),
        name: String,
        isFavorite: Bool = false,
        targetBundleIdentifier: String? = nil,
        actions: [MacroAction],
        loopMode: LoopMode = .once,
        loopCount: Int = 2,
        mousePlaybackMode: MousePlaybackMode = .background,
        recordedWindowWidth: Double? = nil,
        recordedWindowHeight: Double? = nil,
        recordedWindowOriginX: Double? = nil,
        recordedWindowOriginY: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.isFavorite = isFavorite
        self.targetBundleIdentifier = targetBundleIdentifier
        self.actions = actions
        self.loopMode = loopMode
        self.loopCount = loopCount
        self.mousePlaybackMode = mousePlaybackMode
        self.recordedWindowWidth = recordedWindowWidth
        self.recordedWindowHeight = recordedWindowHeight
        self.recordedWindowOriginX = recordedWindowOriginX
        self.recordedWindowOriginY = recordedWindowOriginY
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? "Imported Macro"
        isFavorite = try values.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        targetBundleIdentifier = try values.decodeIfPresent(String.self, forKey: .targetBundleIdentifier)
        actions = try values.decodeIfPresent([MacroAction].self, forKey: .actions) ?? []
        loopMode = try values.decodeIfPresent(LoopMode.self, forKey: .loopMode) ?? .once
        loopCount = try values.decodeIfPresent(Int.self, forKey: .loopCount) ?? 2
        mousePlaybackMode = try values.decodeIfPresent(MousePlaybackMode.self, forKey: .mousePlaybackMode) ?? .background
        recordedWindowWidth = try values.decodeIfPresent(Double.self, forKey: .recordedWindowWidth)
        recordedWindowHeight = try values.decodeIfPresent(Double.self, forKey: .recordedWindowHeight)
        recordedWindowOriginX = try values.decodeIfPresent(Double.self, forKey: .recordedWindowOriginX)
        recordedWindowOriginY = try values.decodeIfPresent(Double.self, forKey: .recordedWindowOriginY)
    }

    var recordedWindowSize: CGSize? {
        guard let recordedWindowWidth, let recordedWindowHeight,
              recordedWindowWidth > 0, recordedWindowHeight > 0 else { return nil }
        return CGSize(width: CGFloat(recordedWindowWidth), height: CGFloat(recordedWindowHeight))
    }

    var recordedWindowOrigin: CGPoint? {
        guard let recordedWindowOriginX, let recordedWindowOriginY else { return nil }
        return CGPoint(x: recordedWindowOriginX, y: recordedWindowOriginY)
    }
}

struct TargetWindow: Identifiable, Equatable {
    let id: Int
    let applicationName: String
    let windowTitle: String
    let processIdentifier: Int32
    let bundleIdentifier: String?
    let bounds: CGRect
    let isOnScreen: Bool

    init(
        id: Int,
        applicationName: String,
        windowTitle: String,
        processIdentifier: Int32,
        bundleIdentifier: String?,
        bounds: CGRect,
        isOnScreen: Bool = true
    ) {
        self.id = id
        self.applicationName = applicationName
        self.windowTitle = windowTitle
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.bounds = bounds
        self.isOnScreen = isOnScreen
    }

    var dimensions: String {
        "\(Int(bounds.width)) × \(Int(bounds.height))"
    }
}

enum RunState: String {
    case idle = "Ready"
    case running = "Running"
    case paused = "Paused"
}

enum AppActivity: Equatable {
    case idle
    case recordingCountdown(Int)
    case recording
    case preparingPlayback
    case playing
    case paused

    var runState: RunState {
        switch self {
        case .preparingPlayback, .playing: .running
        case .paused: .paused
        default: .idle
        }
    }

    var isRecording: Bool { self == .recording }

    var countdownValue: Int? {
        guard case .recordingCountdown(let value) = self else { return nil }
        return value
    }
}

struct PlaybackProgress: Equatable {
    var current: Int
    var total: Int

    var label: String { "Action \(current) of \(total)" }
}

enum MousePlaybackMode: String, Codable, CaseIterable, Identifiable {
    case background
    case compatibility

    var id: Self { self }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        if value == "exactScreen" {
            self = .compatibility
        } else if let mode = Self(rawValue: value) {
            self = mode
        } else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Unknown mouse playback mode: \(value)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var title: String {
        switch self {
        case .background: "Background"
        case .compatibility: "Compatibility"
        }
    }

    var detail: String {
        switch self {
        case .background:
            "Does not switch apps or move your cursor. Some games may ignore this input."
        case .compatibility:
            "Brings the target forward and uses your cursor. Mouse positions follow its window."
        }
    }
}

enum TestInputAction: String, CaseIterable, Identifiable {
    case pressE = "Press E"
    case leftClickCenter = "Left Click Center"
    case moveCenter = "Move to Center"

    var id: Self { self }
}

struct LogEntry: Identifiable {
    let id = UUID()
    let date: Date
    let level: Level
    let message: String

    enum Level { case info, warning, error }
}
