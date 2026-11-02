import AppKit
import Carbon
import CoreGraphics

enum HotkeyAction: UInt32, CaseIterable, Identifiable {
    case record = 1
    case stop = 2
    case play = 3

    var id: UInt32 { rawValue }

    var title: String {
        switch self {
        case .record: "Start Recording"
        case .stop: "Stop Recording / Macro"
        case .play: "Play Selected Macro"
        }
    }

    var symbol: String {
        switch self {
        case .record: "record.circle"
        case .stop: "stop.fill"
        case .play: "play.fill"
        }
    }
}

struct HotkeyShortcut: Codable, Equatable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32
    var keyLabel: String

    static let recordDefault = HotkeyShortcut(keyCode: 97, modifiers: 0, keyLabel: "F6")
    static let stopDefault = HotkeyShortcut(keyCode: 98, modifiers: 0, keyLabel: "F7")
    static let playDefault = HotkeyShortcut(keyCode: 100, modifiers: 0, keyLabel: "F8")

    var displayName: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + keyLabel
    }

    func matches(_ event: NSEvent) -> Bool {
        // AppKit raises an Objective-C exception when keyCode is requested from
        // a mouse or scroll event. The recorder sends every observed event
        // through this filter, so reject non-keyboard events before reading any
        // keyboard-only NSEvent properties.
        guard event.type == .keyDown || event.type == .keyUp else { return false }
        return UInt32(event.keyCode) == keyCode && Self.carbonModifiers(from: event.modifierFlags) == modifiers
    }

    func matches(_ event: CGEvent) -> Bool {
        guard event.type == .keyDown || event.type == .keyUp,
              UInt32(event.getIntegerValueField(.keyboardEventKeycode)) == keyCode else { return false }
        let flags = event.flags
        var eventModifiers: UInt32 = 0
        if flags.contains(.maskControl) { eventModifiers |= UInt32(controlKey) }
        if flags.contains(.maskAlternate) { eventModifiers |= UInt32(optionKey) }
        if flags.contains(.maskShift) { eventModifiers |= UInt32(shiftKey) }
        if flags.contains(.maskCommand) { eventModifiers |= UInt32(cmdKey) }
        return eventModifiers == modifiers
    }

    static func from(_ event: NSEvent) -> HotkeyShortcut? {
        guard event.type == .keyDown else { return nil }
        let label = keyName(for: event)
        let modifiers = carbonModifiers(from: event.modifierFlags)
        let isFunctionKey = label.hasPrefix("F") && Int(label.dropFirst()) != nil

        // A bare letter, digit, or punctuation key would intercept normal typing globally.
        guard isFunctionKey || modifiers != 0 else { return nil }
        return HotkeyShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers, keyLabel: label)
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        var result: UInt32 = 0
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }

    private static func keyName(for event: NSEvent) -> String {
        let functionKeys: [UInt16: String] = [
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
            105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18",
            80: "F19", 90: "F20"
        ]
        if let name = functionKeys[event.keyCode] { return name }

        let namedKeys: [UInt16: String] = [
            36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc",
            115: "Home", 116: "Page Up", 117: "Forward Delete", 119: "End",
            121: "Page Down", 123: "←", 124: "→", 125: "↓", 126: "↑"
        ]
        if let name = namedKeys[event.keyCode] { return name }
        let text = event.charactersIgnoringModifiers?.uppercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? "Key \(event.keyCode)" : text
    }
}

struct HotkeyPreferences: Codable, Equatable {
    var record = HotkeyShortcut.recordDefault
    var stop = HotkeyShortcut.stopDefault
    var play = HotkeyShortcut.playDefault

    subscript(action: HotkeyAction) -> HotkeyShortcut {
        get {
            switch action {
            case .record: record
            case .stop: stop
            case .play: play
            }
        }
        set {
            switch action {
            case .record: record = newValue
            case .stop: stop = newValue
            case .play: play = newValue
            }
        }
    }

    var all: [HotkeyShortcut] { [record, stop, play] }
}

enum GlobalHotkeyError: LocalizedError {
    case duplicate
    case registrationFailed(HotkeyAction, OSStatus)

    var errorDescription: String? {
        switch self {
        case .duplicate:
            "Each action needs a different hotkey."
        case .registrationFailed(let action, let status):
            "macOS could not register \(action.title) (error \(status)). That shortcut may be reserved by another app."
        }
    }
}

final class GlobalHotkeyManager {
    private let signature: OSType = 0x4D_41_43_52 // "MACR"
    private var eventHandler: EventHandlerRef?
    private var registrations: [EventHotKeyRef] = []
    private var actionHandler: ((HotkeyAction) -> Void)?

    init() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(context).takeUnretainedValue()
                return manager.handle(event)
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }

    func register(_ preferences: HotkeyPreferences, handler: @escaping (HotkeyAction) -> Void) throws {
        unregisterAll()
        actionHandler = handler

        guard Set(preferences.all).count == preferences.all.count else {
            throw GlobalHotkeyError.duplicate
        }

        do {
            for action in HotkeyAction.allCases {
                let shortcut = preferences[action]
                var reference: EventHotKeyRef?
                let identifier = EventHotKeyID(signature: signature, id: action.rawValue)
                let status = RegisterEventHotKey(
                    shortcut.keyCode,
                    shortcut.modifiers,
                    identifier,
                    GetApplicationEventTarget(),
                    0,
                    &reference
                )
                guard status == noErr, let reference else {
                    throw GlobalHotkeyError.registrationFailed(action, status)
                }
                registrations.append(reference)
            }
        } catch {
            unregisterAll()
            throw error
        }
    }

    func unregisterAll() {
        registrations.forEach { UnregisterEventHotKey($0) }
        registrations.removeAll()
    }

    private func handle(_ event: EventRef) -> OSStatus {
        var identifier = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &identifier
        )
        guard status == noErr, identifier.signature == signature,
              let action = HotkeyAction(rawValue: identifier.id) else {
            return OSStatus(eventNotHandledErr)
        }
        actionHandler?(action)
        return noErr
    }

    deinit {
        unregisterAll()
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}

@MainActor
final class HotkeyCaptureSession: ObservableObject {
    @Published private(set) var isCapturing = false
    private var monitor: Any?

    func begin(onCapture: @escaping (HotkeyShortcut) -> Void) {
        end()
        isCapturing = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 {
                self.end()
                return nil
            }
            guard let shortcut = HotkeyShortcut.from(event) else {
                NSSound.beep()
                return nil
            }
            onCapture(shortcut)
            self.end()
            return nil
        }
    }

    func end() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isCapturing = false
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}
