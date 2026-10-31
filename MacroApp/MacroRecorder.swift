import AppKit
import CoreGraphics

final class MacroRecorder {
    private struct PendingMouseDown {
        let timestamp: TimeInterval
        let coordinates: CGPoint
        let delay: TimeInterval
        let clickCount: Int
    }

    private var monitors: [Any] = []
    private var actions: [MacroAction] = []
    private var lastEventTime: TimeInterval?
    private var target: TargetWindow?
    private var lastMoveTime: TimeInterval = 0
    private var lastMovePoint = CGPoint(x: -10_000, y: -10_000)
    private var excludedHotkeys: [HotkeyShortcut] = []
    private var pendingMouseDown: [MacroMouseButton: PendingMouseDown] = [:]
    private var heldModifierCodes = Set<UInt16>()

    var isRecording: Bool { !monitors.isEmpty }
    var actionCount: Int { actions.count }
    var onActionCountChange: ((Int) -> Void)?

    func start(target: TargetWindow?, excluding hotkeys: [HotkeyShortcut] = []) throws {
        guard CGPreflightListenEventAccess() else { throw InputBackendError.unsupported("Input Monitoring permission is required for recording.") }
        guard monitors.isEmpty else { return }

        self.target = target
        excludedHotkeys = hotkeys
        actions = []
        lastEventTime = nil
        lastMoveTime = 0
        pendingMouseDown.removeAll()
        heldModifierCodes.removeAll()

        let eventTypes: NSEvent.EventTypeMask = [
            .keyDown, .keyUp, .flagsChanged,
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged,
            .mouseMoved, .scrollWheel
        ]

        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: eventTypes, handler: { [weak self] event in
            guard let self, self.isRecording else { return }
            self.record(event)
        }) {
            monitors.append(monitor)
        }

        guard !monitors.isEmpty else {
            throw InputBackendError.unsupported("macOS did not allow the global recording monitor.")
        }
    }

    func stop() -> [MacroAction] {
        // Global NSEvent monitor callbacks arrive on the main thread and record
        // synchronously, so every event observed before Stop is already committed.
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        let result = actions
        actions = []
        excludedHotkeys = []
        pendingMouseDown.removeAll()
        heldModifierCodes.removeAll()
        lastEventTime = nil
        onActionCountChange?(0)
        return result
    }

    private func record(_ event: NSEvent) {
        guard isRecording else { return }
        if excludedHotkeys.contains(where: { $0.matches(event) }) { return }
        if event.type == .keyDown && (event.isARepeat || event.keyCode == 53) { return }
        if event.type == .keyUp && event.keyCode == 53 { return }

        let now = event.timestamp
        let delay = delaySinceLastEvent(at: now)
        let point = event.cgEvent?.location ?? .zero
        let coordinates = recordedCoordinates(for: point)
        let action: MacroAction?

        switch event.type {
        case .keyDown:
            action = MacroAction(type: .keyDown, key: KeyCodeMapper.name(for: event.keyCode), duration: 0, delay: delay)
        case .keyUp:
            action = MacroAction(type: .keyUp, key: KeyCodeMapper.name(for: event.keyCode), duration: 0, delay: delay)
        case .flagsChanged:
            guard let flag = modifierFlag(for: event.keyCode) else { return }
            let isDown = event.modifierFlags.contains(flag)
            let wasDown = heldModifierCodes.contains(event.keyCode)
            guard isDown != wasDown else { return }
            if isDown {
                heldModifierCodes.insert(event.keyCode)
            } else {
                guard wasDown else { return }
                heldModifierCodes.remove(event.keyCode)
            }
            action = MacroAction(
                type: isDown ? .keyDown : .keyUp,
                key: KeyCodeMapper.name(for: event.keyCode),
                duration: 0,
                delay: delay
            )
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            guard let button = mouseButton(for: event) else { return }
            pendingMouseDown[button] = PendingMouseDown(
                timestamp: now,
                coordinates: coordinates,
                delay: delay,
                clickCount: max(1, event.clickCount)
            )
            return
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            guard let button = mouseButton(for: event) else { return }
            if let pending = pendingMouseDown.removeValue(forKey: button) {
                action = MacroAction(
                    type: clickActionType(for: button),
                    key: nil,
                    duration: max(0.01, now - pending.timestamp),
                    delay: pending.delay,
                    x: pending.coordinates.x,
                    y: pending.coordinates.y,
                    mouseButton: button,
                    clickCount: pending.clickCount,
                    usesWindowCoordinates: target != nil
                )
            } else {
                action = MacroAction(
                    type: .mouseUp,
                    key: nil,
                    duration: 0,
                    delay: delay,
                    x: coordinates.x,
                    y: coordinates.y,
                    mouseButton: button,
                    clickCount: max(1, event.clickCount),
                    usesWindowCoordinates: target != nil
                )
            }
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            guard let button = mouseButton(for: event) else { return }
            if let pending = pendingMouseDown.removeValue(forKey: button) {
                append(
                    MacroAction(
                        type: .mouseDown,
                        key: nil,
                        duration: 0,
                        delay: pending.delay,
                        x: pending.coordinates.x,
                        y: pending.coordinates.y,
                        mouseButton: button,
                        clickCount: pending.clickCount,
                        usesWindowCoordinates: target != nil
                    ),
                    at: pending.timestamp
                )
            }
            guard shouldRecordMove(at: point, time: now) else { return }
            action = MacroAction(
                type: .move,
                key: nil,
                duration: 0,
                delay: delaySinceLastEvent(at: now),
                x: coordinates.x,
                y: coordinates.y,
                mouseButton: button,
                usesWindowCoordinates: target != nil
            )
        case .mouseMoved:
            guard shouldRecordMove(at: point, time: now) else { return }
            action = MacroAction(type: .move, key: nil, duration: 0, delay: delay, x: coordinates.x, y: coordinates.y, usesWindowCoordinates: target != nil)
        case .scrollWheel:
            let deltaX = event.scrollingDeltaX
            let deltaY = event.scrollingDeltaY
            guard deltaX != 0 || deltaY != 0 else { return }
            action = MacroAction(
                type: .scroll,
                key: nil,
                duration: 0,
                delay: delay,
                x: coordinates.x,
                y: coordinates.y,
                scrollDeltaX: deltaX,
                scrollDeltaY: deltaY,
                usesWindowCoordinates: target != nil
            )
        default:
            return
        }

        if let action {
            append(action, at: now)
        }
    }

    private func append(_ action: MacroAction, at timestamp: TimeInterval) {
        if action.type == .scroll,
           action.delay <= 0.06,
           var previous = actions.last,
           previous.type == .scroll,
           previous.usesWindowCoordinates == action.usesWindowCoordinates {
            previous.scrollDeltaX += action.scrollDeltaX
            previous.scrollDeltaY += action.scrollDeltaY
            previous.x = action.x
            previous.y = action.y
            actions[actions.count - 1] = previous
            lastEventTime = timestamp
            return
        }
        actions.append(action)
        lastEventTime = timestamp
        onActionCountChange?(actions.count)
    }

    private func delaySinceLastEvent(at timestamp: TimeInterval) -> TimeInterval {
        lastEventTime.map { max(0, timestamp - $0) } ?? 0
    }

    private func shouldRecordMove(at point: CGPoint, time: TimeInterval) -> Bool {
        guard time - lastMoveTime >= 0.05,
              hypot(point.x - lastMovePoint.x, point.y - lastMovePoint.y) >= 4 else { return false }
        lastMoveTime = time
        lastMovePoint = point
        return true
    }

    private func mouseButton(for event: NSEvent) -> MacroMouseButton? {
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged: .left
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged: .right
        case .otherMouseDown, .otherMouseUp, .otherMouseDragged: .middle
        default: nil
        }
    }

    private func clickActionType(for button: MacroMouseButton) -> MacroActionType {
        switch button { case .left: .leftClick; case .right: .rightClick; case .middle: .middleClick }
    }

    private func modifierFlag(for keyCode: UInt16) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 54, 55: .command
        case 56, 60: .shift
        case 58, 61: .option
        case 59, 62: .control
        case 57: .capsLock
        case 63: .function
        default: nil
        }
    }

    private func recordedCoordinates(for point: CGPoint) -> CGPoint {
        guard let target else { return point }
        return CGPoint(x: point.x - target.bounds.minX, y: point.y - target.bounds.minY)
    }
}

@MainActor
final class EmergencyStopMonitor {
    private var globalMonitor: Any?
    private var localMonitor: Any?

    func start(handler: @escaping () -> Void) {
        stop()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return }
            DispatchQueue.main.async(execute: handler)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { handler() }
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    deinit {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }
}
