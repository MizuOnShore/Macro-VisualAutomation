import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// Temporary click trace for Debug builds. MACRO_CLICK_DIAGNOSTICS=0 disables it.
enum ClickDiagnostics {
    #if DEBUG
    static let enabled = ProcessInfo.processInfo.environment["MACRO_CLICK_DIAGNOSTICS"] != "0"
    private static let queue = DispatchQueue(label: "Macro.ClickDiagnostics", qos: .utility)
    private static let fileURL: URL = {
        if let path = ProcessInfo.processInfo.environment["MACRO_CLICK_DIAGNOSTICS_FILE"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Macro", isDirectory: true)
            .appendingPathComponent("ClickDiagnostics.log")
    }()

    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let line = "\(Date().ISO8601Format()) pid=\(ProcessInfo.processInfo.processIdentifier) [MacroClickTrace] \(message())"
        queue.async {
            NSLog("%@", line)
            do {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    FileManager.default.createFile(atPath: fileURL.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data((line + "\n").utf8))
            } catch {
                NSLog("[MacroClickTrace] file_write_error=%@", error.localizedDescription)
            }
        }
    }
    #else
    static let enabled = false
    static func log(_ message: @autoclosure () -> String) {}
    #endif
}

enum InputBackendError: LocalizedError {
    case accessibilityRequired
    case eventPostingRequired
    case invalidKey(String)
    case eventCreationFailed
    case targetUnavailable
    case targetWindowUnavailable
    case targetActivationFailed
    case targetFocusChanged
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .accessibilityRequired: "Accessibility permission is required."
        case .eventPostingRequired: "Synthetic event permission is required for foreground mouse playback. Open Settings → Permissions and request Accessibility access again."
        case .invalidKey(let key): "Unknown key: \(key)."
        case .eventCreationFailed: "macOS could not create the synthetic event."
        case .targetUnavailable: "The selected target process is no longer running."
        case .targetWindowUnavailable: "The selected target window is no longer available. Select the window again before playback."
        case .targetActivationFailed: "Macro could not bring the selected target to the foreground."
        case .targetFocusChanged: "The selected target window lost focus. Playback stopped."
        case .unsupported(let reason): reason
        }
    }
}

@MainActor
enum CompatibilityPlaybackPreparation {
    static func activate(_ target: TargetWindow) async throws {
        let manager = TargetManager()
        ClickDiagnostics.log("stage=prepare_begin selectedPID=\(target.processIdentifier) selectedWindow=\(target.id) selectedFrame=\(target.bounds)")
        guard let current = manager.currentWindow(matching: target) else {
            ClickDiagnostics.log("stage=prepare_blocked reason=selectedWindowUnavailable selectedPID=\(target.processIdentifier) selectedWindow=\(target.id)")
            throw InputBackendError.targetWindowUnavailable
        }
        guard let application = NSRunningApplication(processIdentifier: target.processIdentifier),
              !application.isTerminated else {
            throw InputBackendError.targetUnavailable
        }

        _ = application.unhide()
        application.activate(options: [.activateAllWindows])
        _ = manager.raiseWindow(matching: current)

        // Switching Spaces or restoring a fullscreen game can take much longer
        // than a fixed delay. Do not start HID playback until it is frontmost.
        for attempt in 0..<40 {
            try Task.checkCancellation()
            guard let updated = manager.currentWindow(matching: current) else {
                ClickDiagnostics.log("stage=prepare_blocked reason=windowDisappeared selectedPID=\(target.processIdentifier) selectedWindow=\(target.id)")
                throw InputBackendError.targetWindowUnavailable
            }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier {
                switch manager.focusedWindowStatus(matching: updated) {
                case .matched:
                    ClickDiagnostics.log("stage=prepare_ready focus=matched currentPID=\(updated.processIdentifier) currentWindow=\(updated.id) currentFrame=\(updated.bounds)")
                    return
                case .unavailable:
                    ClickDiagnostics.log("stage=prepare_ready focus=unverified currentPID=\(updated.processIdentifier) currentWindow=\(updated.id) currentFrame=\(updated.bounds)")
                    return
                case .different:
                    if attempt % 5 == 0 { _ = manager.raiseWindow(matching: updated) }
                }
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        ClickDiagnostics.log("stage=prepare_blocked reason=focusChanged selectedPID=\(target.processIdentifier) selectedWindow=\(target.id)")
        throw InputBackendError.targetFocusChanged
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
    func resetInputState()
    func keyDown(_ keyCode: CGKeyCode, target: TargetWindow) throws
    func keyDown(_ keyCode: CGKeyCode, target: TargetWindow, isRepeat: Bool) throws
    func keyUp(_ keyCode: CGKeyCode, target: TargetWindow) throws
    func mouseMove(to point: CGPoint, target: TargetWindow) throws
    func mouseDrag(_ button: MacroMouseButton, to point: CGPoint, target: TargetWindow) throws
    func mouseDown(_ button: MacroMouseButton, at point: CGPoint, clickCount: Int, target: TargetWindow) throws
    func mouseUp(_ button: MacroMouseButton, at point: CGPoint, clickCount: Int, target: TargetWindow) throws
    func scroll(deltaX: Double, deltaY: Double, units: MacroScrollUnit, at point: CGPoint, target: TargetWindow) throws
}

extension InputBackend {
    var mousePlaybackMode: MousePlaybackMode { .background }
    func resetInputState() {}
    func keyDown(_ keyCode: CGKeyCode, target: TargetWindow, isRepeat: Bool) throws {
        try keyDown(keyCode, target: target)
    }
}

/// Background input stays targeted to the selected process. Foreground modes
/// send both keyboard and mouse events through the system HID stream.
@MainActor
final class TargetedCGEventBackend: InputBackend {
    let mousePlaybackMode: MousePlaybackMode
    var displayName: String {
        switch mousePlaybackMode {
        case .background: "Targeted Keyboard + Background Mouse"
        case .compatibility: "System Keyboard + System Mouse"
        }
    }

    init(mousePlaybackMode: MousePlaybackMode) {
        self.mousePlaybackMode = mousePlaybackMode
        let stateID: CGEventSourceStateID = mousePlaybackMode != .background
            ? .hidSystemState
            : .privateState
        source = CGEventSource(stateID: stateID)
        source?.localEventsSuppressionInterval = 0
    }
    let canVerifyReceipt = false
    private let source: CGEventSource?
    private var heldModifiers = Set<CGKeyCode>()

    func resetInputState() {
        heldModifiers.removeAll()
    }

    private var modifierFlags: CGEventFlags {
        var flags: CGEventFlags = []
        for code in heldModifiers {
            switch code {
            case 54, 55: flags.insert(.maskCommand)
            case 56, 60: flags.insert(.maskShift)
            case 58, 61: flags.insert(.maskAlternate)
            case 59, 62: flags.insert(.maskControl)
            case 57: flags.insert(.maskAlphaShift)
            case 63: flags.insert(.maskSecondaryFn)
            default: break
            }
        }
        return flags
    }

    private func isModifier(_ code: CGKeyCode) -> Bool {
        switch code {
        case 54...63: true
        default: false
        }
    }

    func keyDown(_ keyCode: CGKeyCode, target: TargetWindow) throws {
        try keyDown(keyCode, target: target, isRepeat: false)
    }

    func keyDown(_ keyCode: CGKeyCode, target: TargetWindow, isRepeat: Bool) throws {
        try validate(target)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) else {
            throw InputBackendError.eventCreationFailed
        }
        if isModifier(keyCode) { heldModifiers.insert(keyCode) }
        event.flags = modifierFlags
        if isRepeat { event.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        postKeyboardEvent(event, target: target)
    }

    func keyUp(_ keyCode: CGKeyCode, target: TargetWindow) throws {
        try validate(target)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            throw InputBackendError.eventCreationFailed
        }
        if isModifier(keyCode) { heldModifiers.remove(keyCode) }
        event.flags = modifierFlags
        postKeyboardEvent(event, target: target)
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

    func scroll(deltaX: Double, deltaY: Double, units: MacroScrollUnit, at point: CGPoint, target: TargetWindow) throws {
        try validate(target)
        guard let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: units == .pixel ? .pixel : .line,
            wheelCount: 2,
            wheel1: scrollValue(deltaY),
            wheel2: scrollValue(deltaX),
            wheel3: 0
        ) else {
            throw InputBackendError.eventCreationFailed
        }
        event.location = point
        event.flags = modifierFlags
        postMouseEvent(event, target: target)
    }

    private func postMouse(
        type: CGEventType,
        button: MacroMouseButton,
        point: CGPoint,
        clickCount: Int = 1,
        target: TargetWindow
    ) throws {
        let isClick = type == .leftMouseDown || type == .leftMouseUp
            || type == .rightMouseDown || type == .rightMouseUp
            || type == .otherMouseDown || type == .otherMouseUp
        do {
            try validate(target)
        } catch {
            if isClick {
                ClickDiagnostics.log("stage=dispatch_error phase=validation type=\(type.rawValue) pid=\(target.processIdentifier) window=\(target.id) error=\(error.localizedDescription)")
            }
            throw error
        }
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: button.cgButton
        ) else {
            if isClick {
                ClickDiagnostics.log("stage=dispatch_error phase=creation type=\(type.rawValue) pid=\(target.processIdentifier) window=\(target.id) error=eventCreationFailed")
            }
            throw InputBackendError.eventCreationFailed
        }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, clickCount)))
        event.flags = modifierFlags
        let createdAt = isClick ? DispatchTime.now().uptimeNanoseconds : 0
        let postStartedAt = isClick ? DispatchTime.now().uptimeNanoseconds : 0
        postMouseEvent(event, target: target)
        if isClick {
            let postReturnedAt = DispatchTime.now().uptimeNanoseconds
            ClickDiagnostics.log("stage=dispatch_created type=\(type.rawValue) pid=\(target.processIdentifier) window=\(target.id) mode=\(mousePlaybackMode.rawValue) point=\(point) timeNs=\(createdAt)")
            ClickDiagnostics.log("stage=post_call_start type=\(type.rawValue) pid=\(target.processIdentifier) window=\(target.id) timeNs=\(postStartedAt)")
            // CGEvent.post/postToPid return Void; this is not target receipt.
            ClickDiagnostics.log("stage=post_call_return type=\(type.rawValue) pid=\(target.processIdentifier) window=\(target.id) timeNs=\(postReturnedAt) receipt=unverified")
        }
    }

    private func postMouseEvent(_ event: CGEvent, target: TargetWindow) {
        switch mousePlaybackMode {
        case .background:
            event.postToPid(target.processIdentifier)
        case .compatibility:
            event.post(tap: .cghidEventTap)
        }
    }

    private func postKeyboardEvent(_ event: CGEvent, target: TargetWindow) {
        switch mousePlaybackMode {
        case .background:
            event.postToPid(target.processIdentifier)
        case .compatibility:
            event.post(tap: .cghidEventTap)
        }
    }

    private func validate(_ target: TargetWindow) throws {
        guard AXIsProcessTrusted() else { throw InputBackendError.accessibilityRequired }
        if mousePlaybackMode != .background, !CGPreflightPostEventAccess() {
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
        "`": 50, "delete": 51, "escape": 53, "rightcommand": 54, "command": 55, "shift": 56,
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
