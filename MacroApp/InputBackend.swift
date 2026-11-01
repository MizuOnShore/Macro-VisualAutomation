import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum InputBackendError: LocalizedError {
    case accessibilityRequired
    case eventPostingRequired
    case invalidKey(String)
    case eventCreationFailed
    case targetUnavailable
    case targetActivationFailed
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .accessibilityRequired: "Accessibility permission is required."
        case .eventPostingRequired: "Synthetic event permission is required for Compatibility mouse playback. Open Settings → Permissions and request Accessibility access again."
        case .invalidKey(let key): "Unknown key: \(key)."
        case .eventCreationFailed: "macOS could not create the synthetic event."
        case .targetUnavailable: "The selected target process is no longer running."
        case .targetActivationFailed: "Macro could not bring the selected target to the foreground."
        case .unsupported(let reason): reason
        }
    }
}

@MainActor
enum CompatibilityPlaybackPreparation {
    static func activate(_ target: TargetWindow) async throws {
        guard let application = NSRunningApplication(processIdentifier: target.processIdentifier),
              !application.isTerminated else {
            throw InputBackendError.targetUnavailable
        }

        _ = application.unhide()
        application.activate(options: [.activateAllWindows])

        // Switching Spaces or restoring a fullscreen game can take much longer
        // than a fixed delay. Do not start HID playback until it is frontmost.
        for _ in 0..<40 {
            try Task.checkCancellation()
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw InputBackendError.targetActivationFailed
    }
}

extension MacroMouseButton {
    var cgButton: CGMouseButton {
        switch self { case .left: .left; case .right: .right; case .middle: .center }
    }

    var downType: CGEventType {
        switch self { case .left: .leftMouseDown; case .right: .rightMouseDown; case .middle: .otherMouseDown }
    }

    var upType: CGEventType {
        switch self { case .left: .leftMouseUp; case .right: .rightMouseUp; case .middle: .otherMouseUp }
    }

    var dragType: CGEventType {
        switch self { case .left: .leftMouseDragged; case .right: .rightMouseDragged; case .middle: .otherMouseDragged }
    }
}

@MainActor
protocol InputBackend: AnyObject {
    var mousePlaybackMode: MousePlaybackMode { get }
    var displayName: String { get }
    var canVerifyReceipt: Bool { get }
    func keyDown(_ keyCode: CGKeyCode, target: TargetWindow) throws
    func keyUp(_ keyCode: CGKeyCode, target: TargetWindow) throws
    func mouseMove(to point: CGPoint, target: TargetWindow) throws
    func mouseDrag(_ button: MacroMouseButton, to point: CGPoint, target: TargetWindow) throws
    func mouseDown(_ button: MacroMouseButton, at point: CGPoint, clickCount: Int, target: TargetWindow) throws
    func mouseUp(_ button: MacroMouseButton, at point: CGPoint, clickCount: Int, target: TargetWindow) throws
    func scroll(deltaX: Double, deltaY: Double, at point: CGPoint, target: TargetWindow) throws
}

extension InputBackend {
    var mousePlaybackMode: MousePlaybackMode { .background }
}

/// Posts keyboard events directly to the selected process. Mouse events use the
/// system HID stream because games such as Roblox ignore PID-targeted mouse
/// events even when they accept PID-targeted keyboard events.
@MainActor
final class TargetedCGEventBackend: InputBackend {
    let mousePlaybackMode: MousePlaybackMode
    var displayName: String {
        switch mousePlaybackMode {
        case .background: "Targeted Keyboard + Background Mouse"
        case .compatibility: "Targeted Keyboard + System Mouse"
        case .exactScreen: "Targeted Keyboard + Exact Screen Mouse"
        }
    }

    init(mousePlaybackMode: MousePlaybackMode) {
        self.mousePlaybackMode = mousePlaybackMode
        let stateID: CGEventSourceStateID = mousePlaybackMode == .compatibility
            ? .hidSystemState
            : .privateState
        source = CGEventSource(stateID: stateID)
        source?.localEventsSuppressionInterval = 0
    }
    let canVerifyReceipt = false
    private let source: CGEventSource?

    func keyDown(_ keyCode: CGKeyCode, target: TargetWindow) throws {
        try validate(target)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) else {
            throw InputBackendError.eventCreationFailed
        }
        event.postToPid(target.processIdentifier)
    }

    func keyUp(_ keyCode: CGKeyCode, target: TargetWindow) throws {
        try validate(target)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            throw InputBackendError.eventCreationFailed
        }
        event.postToPid(target.processIdentifier)
    }

    func mouseMove(to point: CGPoint, target: TargetWindow) throws {
        try postMouse(type: .mouseMoved, button: .left, point: point, target: target)
    }

    func mouseDrag(_ button: MacroMouseButton, to point: CGPoint, target: TargetWindow) throws {
        try postMouse(type: button.dragType, button: button, point: point, target: target)
    }

    func mouseDown(_ button: MacroMouseButton, at point: CGPoint, clickCount: Int = 1, target: TargetWindow) throws {
        try postMouse(type: button.downType, button: button, point: point, clickCount: clickCount, target: target)
    }

    func mouseUp(_ button: MacroMouseButton, at point: CGPoint, clickCount: Int = 1, target: TargetWindow) throws {
        try postMouse(type: button.upType, button: button, point: point, clickCount: clickCount, target: target)
    }

    func scroll(deltaX: Double, deltaY: Double, at point: CGPoint, target: TargetWindow) throws {
        try validate(target)
        guard let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 2,
            wheel1: scrollValue(deltaY),
            wheel2: scrollValue(deltaX),
            wheel3: 0
        ) else {
            throw InputBackendError.eventCreationFailed
        }
        event.location = point
        postMouseEvent(event, target: target)
    }

    private func postMouse(
        type: CGEventType,
        button: MacroMouseButton,
        point: CGPoint,
        clickCount: Int = 1,
        target: TargetWindow
    ) throws {
        try validate(target)
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: button.cgButton
        ) else {
            throw InputBackendError.eventCreationFailed
        }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, clickCount)))
        postMouseEvent(event, target: target)
    }

    private func postMouseEvent(_ event: CGEvent, target: TargetWindow) {
        switch mousePlaybackMode {
        case .background:
            event.postToPid(target.processIdentifier)
        case .compatibility, .exactScreen:
            event.post(tap: .cghidEventTap)
        }
    }

    private func validate(_ target: TargetWindow) throws {
        guard AXIsProcessTrusted() else { throw InputBackendError.accessibilityRequired }
        if mousePlaybackMode == .compatibility, !CGPreflightPostEventAccess() {
            throw InputBackendError.eventPostingRequired
        }
        guard kill(target.processIdentifier, 0) == 0 else { throw InputBackendError.targetUnavailable }
    }

    private func scrollValue(_ value: Double) -> Int32 {
        guard value != 0 else { return 0 }
        let rounded = Int32(value.rounded())
        return rounded == 0 ? (value > 0 ? 1 : -1) : rounded
    }
}

enum KeyCodeMapper {
    private static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
        "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43,
        "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49,
        "`": 50, "delete": 51, "escape": 53, "command": 55, "shift": 56,
        "capslock": 57, "option": 58, "control": 59, "rightshift": 60,
        "rightoption": 61, "rightcontrol": 62, "fn": 63, "f17": 64,
        "volumeup": 72, "volumedown": 73, "mute": 74, "f18": 79, "f19": 80,
        "f20": 90, "f5": 96, "f6": 97, "f7": 98, "f3": 99, "f8": 100,
        "f9": 101, "f11": 103, "f13": 105, "f16": 106, "f14": 107,
        "f10": 109, "f12": 111, "f15": 113, "help": 114, "home": 115,
        "pageup": 116, "forwarddelete": 117, "f4": 118, "end": 119, "f2": 120,
        "pagedown": 121, "f1": 122, "left": 123, "right": 124, "down": 125, "up": 126
    ]

    static func code(for key: String) -> CGKeyCode? {
        let normalized = key.lowercased().replacingOccurrences(of: " ", with: "")
        if normalized.hasPrefix("keycode:"),
           let raw = UInt16(normalized.dropFirst("keycode:".count)) {
            return raw
        }
        return keyCodes[normalized]
    }

    static func name(for code: CGKeyCode) -> String {
        keyCodes.first(where: { $0.value == code })?.key ?? "keyCode:\(code)"
    }
}
