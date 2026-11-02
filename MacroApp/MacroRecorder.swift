import AppKit
import CoreGraphics

final class MacroRecorder {
    // Preserve every button and key transition. Movement is bounded to a
    // practical rate so playback can keep up with the event stream.
    private static let moveSampleInterval: TimeInterval = 1.0 / 120.0
    private static let moveDistanceThreshold: CGFloat = 1
    private struct PendingMove {
        var action: MacroAction
        var timestamp: TimeInterval
    }
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var actions: [MacroAction] = []
    private var lastEventTime: TimeInterval?
    private var lastCountNotificationTime: TimeInterval = 0
    private var target: TargetWindow?
    private var lastMoveTime: TimeInterval = 0
    private var lastMovePoint = CGPoint(x: -10_000, y: -10_000)
    private var pendingMove: PendingMove?
    private var excludedHotkeys: [HotkeyShortcut] = []
    private var heldModifierCodes = Set<UInt16>()
    private var recordedHeldKeys = Set<UInt16>()
    private var recordedHeldButtons = Set<MacroMouseButton>()
    private var lastHoverCheckAt: TimeInterval = 0
    private var lastHoverWindowID: TargetWindow.ID?
    private var currentCaptureWindow: TargetWindow?
    private var lastCaptureWindowRefreshAt: TimeInterval = 0
    private let targetManager = TargetManager()

    var isRecording: Bool { eventTap != nil }
    var actionCount: Int { actions.count }
    var recordedTarget: TargetWindow? { target }
    var onActionCountChange: ((Int) -> Void)?

    func start(target: TargetWindow?, excluding hotkeys: [HotkeyShortcut] = []) throws {
        guard CGPreflightListenEventAccess() else { throw InputBackendError.unsupported("Input Monitoring permission is required for recording.") }
        guard !isRecording else { return }

        self.target = target
        excludedHotkeys = hotkeys
        actions = []
        lastEventTime = nil
        lastMoveTime = 0
        lastMovePoint = CGPoint(x: -10_000, y: -10_000)
        pendingMove = nil
        lastCountNotificationTime = 0
        heldModifierCodes.removeAll()
        recordedHeldKeys.removeAll()
        recordedHeldButtons.removeAll()
        lastHoverCheckAt = 0
        lastHoverWindowID = nil
        currentCaptureWindow = target
        lastCaptureWindowRefreshAt = 0
        ClickDiagnostics.log("stage=recording_start selectedPID=\(target?.processIdentifier ?? -1) selectedWindow=\(target?.id ?? -1) selectedFrame=\(String(describing: target?.bounds))")

        let eventTypes: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp,
            .leftMouseDragged, .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged, .mouseMoved,
            .scrollWheel
        ]
        let eventMask = eventTypes.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let recorder = Unmanaged<MacroRecorder>.fromOpaque(userInfo).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = recorder.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            } else {
                recorder.record(event)
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            throw InputBackendError.unsupported("macOS did not allow the input recording tap. Check Input Monitoring permission and relaunch Macro.")
        }
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() -> [MacroAction] {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        runLoopSource = nil
        eventTap = nil
        flushPendingMove()
        let result = actions
        actions = []
        excludedHotkeys = []
        heldModifierCodes.removeAll()
        recordedHeldKeys.removeAll()
        recordedHeldButtons.removeAll()
        currentCaptureWindow = nil
        pendingMove = nil
        lastEventTime = nil
        onActionCountChange?(0)
        return result
    }

    private func record(_ event: CGEvent) {
        guard isRecording else { return }
        // The session tap sees Macro's own HUD and Stop button too. Never put
        // those controls into the recording, especially a dangling mouse down.
        let destinationPID = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
        let ownPID = ProcessInfo.processInfo.processIdentifier
        if destinationPID == ownPID || (destinationPID == 0 && NSApp.isActive) {
            return
        }
        if excludedHotkeys.contains(where: { $0.matches(event) }) { return }
        let now = event.timestamp == 0
            ? ProcessInfo.processInfo.systemUptime
            : TimeInterval(event.timestamp) / 1_000_000_000
        let isMove = switch event.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: true
        default: false
        }
        let isClick = switch event.type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp: true
        default: false
        }
        let point = event.location
        let currentWindow = captureWindow(for: event.type, at: now)
        if isClick {
            ClickDiagnostics.log("stage=record_candidate type=\(event.type.rawValue) eventTimeSec=\(now) screen=\(point) destinationPID=\(destinationPID) selectedPID=\(target?.processIdentifier ?? -1) selectedWindow=\(target?.id ?? -1) currentWindow=\(currentWindow?.id ?? -1) frame=\(String(describing: currentWindow?.bounds))")
        }
        if target != nil && currentWindow == nil {
            if isClick { ClickDiagnostics.log("stage=record_rejected reason=selectedWindowUnavailable type=\(event.type.rawValue) screen=\(point)") }
            return
        }
        guard shouldCapture(event, destinationPID: destinationPID, point: point, at: now,
                            currentWindow: currentWindow) else {
            if isClick { ClickDiagnostics.log("stage=record_rejected reason=targetProvenance type=\(event.type.rawValue) screen=\(point) destinationPID=\(destinationPID)") }
            return
        }
        if !isMove { flushPendingMove() }
        let delay = delaySinceLastEvent(at: now)
        let coordinates = recordedCoordinates(for: point, currentWindow: currentWindow)
        let action: MacroAction?

        switch event.type {
        case .keyDown:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            guard keyCode != 53 else { return }
            action = MacroAction(
                type: .keyDown,
                key: KeyCodeMapper.name(for: keyCode),
                duration: 0,
                delay: delay,
                isKeyRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            )
        case .keyUp:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            guard keyCode != 53 else { return }
            action = MacroAction(type: .keyUp, key: KeyCodeMapper.name(for: keyCode), duration: 0, delay: delay)
        case .flagsChanged:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            guard let flag = modifierFlag(for: keyCode) else { return }
            let wasDown = heldModifierCodes.contains(keyCode)
            // CGEventFlags reports the combined modifier state. If both Shift
            // keys are held, releasing one still leaves maskShift set, so use
            // the physical key transition to preserve left/right key order.
            let isDown = keyCode == 57 ? event.flags.contains(flag) : !wasDown && event.flags.contains(flag)
            guard isDown != wasDown else { return }
            if isDown {
                heldModifierCodes.insert(keyCode)
            } else {
                guard wasDown else { return }
                heldModifierCodes.remove(keyCode)
            }
            action = MacroAction(
                type: isDown ? .keyDown : .keyUp,
                key: KeyCodeMapper.name(for: keyCode),
                duration: 0,
                delay: delay
            )
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            guard let button = mouseButton(for: event) else { return }
            action = MacroAction(
                type: .mouseDown,
                key: nil,
                duration: 0,
                delay: delay,
                x: coordinates.x,
                y: coordinates.y,
                recordedScreenX: point.x,
                recordedScreenY: point.y,
                mouseButton: button,
                clickCount: max(1, Int(event.getIntegerValueField(.mouseEventClickState))),
                usesWindowCoordinates: target != nil
            )
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            guard let button = mouseButton(for: event) else { return }
            action = MacroAction(
                type: .mouseUp,
                key: nil,
                duration: 0,
                delay: delay,
                x: coordinates.x,
                y: coordinates.y,
                recordedScreenX: point.x,
                recordedScreenY: point.y,
                mouseButton: button,
                clickCount: max(1, Int(event.getIntegerValueField(.mouseEventClickState))),
                usesWindowCoordinates: target != nil
            )
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            guard let button = mouseButton(for: event) else { return }
            action = MacroAction(
                type: .move,
                key: nil,
                duration: 0,
                delay: delay,
                x: coordinates.x,
                y: coordinates.y,
                recordedScreenX: point.x,
                recordedScreenY: point.y,
                mouseButton: button,
                usesWindowCoordinates: target != nil
            )
        case .mouseMoved:
            action = MacroAction(
                type: .move, key: nil, duration: 0, delay: delay,
                x: coordinates.x, y: coordinates.y,
                recordedScreenX: point.x, recordedScreenY: point.y,
                usesWindowCoordinates: target != nil
            )
        case .scrollWheel:
            let pointX = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
            let pointY = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
            let lineX = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
            let lineY = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
            let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
            let unit: MacroScrollUnit = isContinuous || (lineX == 0 && lineY == 0) ? .pixel : .line
            let deltaX = unit == .pixel ? pointX : lineX
            let deltaY = unit == .pixel ? pointY : lineY
            guard deltaX != 0 || deltaY != 0 else { return }
            action = MacroAction(
                type: .scroll,
                key: nil,
                duration: 0,
                delay: delay,
                x: coordinates.x,
                y: coordinates.y,
                recordedScreenX: point.x,
                recordedScreenY: point.y,
                scrollDeltaX: deltaX,
                scrollDeltaY: deltaY,
                scrollUnit: unit,
                usesWindowCoordinates: target != nil
            )
        default:
            return
        }

        if let action {
            switch event.type {
            case .keyDown:
                recordedHeldKeys.insert(UInt16(event.getIntegerValueField(.keyboardEventKeycode)))
            case .keyUp:
                recordedHeldKeys.remove(UInt16(event.getIntegerValueField(.keyboardEventKeycode)))
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                if let button = mouseButton(for: event) { recordedHeldButtons.insert(button) }
            case .leftMouseUp, .rightMouseUp, .otherMouseUp:
                if let button = mouseButton(for: event) { recordedHeldButtons.remove(button) }
            default: break
            }
            if isMove {
                if shouldRecordMove(at: point, time: now) {
                    pendingMove = nil
                    append(action, at: now)
                } else if point != lastMovePoint {
                    pendingMove = PendingMove(action: action, timestamp: now)
                }
            } else {
                append(action, at: now)
            }
        }
    }

    private func flushPendingMove() {
        guard var pendingMove else { return }
        self.pendingMove = nil
        pendingMove.action.delay = delaySinceLastEvent(at: pendingMove.timestamp)
        append(pendingMove.action, at: pendingMove.timestamp)
    }

    private func append(_ action: MacroAction, at timestamp: TimeInterval) {
        actions.append(action)
        if action.type == .mouseDown || action.type == .mouseUp {
            ClickDiagnostics.log("stage=record_saved index=\(actions.count - 1) actionID=\(action.id) type=\(action.type.rawValue) eventTimeSec=\(timestamp) delaySec=\(action.delay) screen=(\(action.recordedScreenX ?? .nan),\(action.recordedScreenY ?? .nan)) relative=(\(action.x ?? .nan),\(action.y ?? .nan)) selectedPID=\(target?.processIdentifier ?? -1) selectedWindow=\(target?.id ?? -1) currentWindow=\(currentCaptureWindow?.id ?? -1) frame=\(String(describing: currentCaptureWindow?.bounds)) recordedFrame=\(String(describing: target?.bounds))")
        }
        lastEventTime = timestamp
        if timestamp - lastCountNotificationTime >= 0.1 {
            lastCountNotificationTime = timestamp
            onActionCountChange?(actions.count)
        }
    }

    private func delaySinceLastEvent(at timestamp: TimeInterval) -> TimeInterval {
        lastEventTime.map { max(0, timestamp - $0) } ?? 0
    }

    private func shouldRecordMove(at point: CGPoint, time: TimeInterval) -> Bool {
        guard time - lastMoveTime >= Self.moveSampleInterval,
              hypot(point.x - lastMovePoint.x, point.y - lastMovePoint.y) >= Self.moveDistanceThreshold else { return false }
        lastMoveTime = time
        lastMovePoint = point
        return true
    }

    private func mouseButton(for event: CGEvent) -> MacroMouseButton? {
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged: .left
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged: .right
        case .otherMouseDown, .otherMouseUp, .otherMouseDragged: .middle
        default: nil
        }
    }

    private func modifierFlag(for keyCode: UInt16) -> CGEventFlags? {
        switch keyCode {
        case 54, 55: .maskCommand
        case 56, 60: .maskShift
        case 58, 61: .maskAlternate
        case 59, 62: .maskControl
        case 57: .maskAlphaShift
        case 63: .maskSecondaryFn
        default: nil
        }
    }

    private func recordedCoordinates(for point: CGPoint, currentWindow: TargetWindow?) -> CGPoint {
        guard let target, let currentWindow else { return point }
        // Store in the initial window's coordinate scale, even if its frame
        // changes during recording. The macro keeps that initial frame size.
        let frame = currentWindow.bounds
        return CGPoint(
            x: (point.x - frame.minX) * target.bounds.width / frame.width,
            y: (point.y - frame.minY) * target.bounds.height / frame.height
        )
    }

    private func captureWindow(for type: CGEventType, at time: TimeInterval) -> TargetWindow? {
        guard let target else { return nil }
        let interval: TimeInterval = switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: 0.03
        case .keyDown, .keyUp, .flagsChanged: 0.1
        default: 0
        }
        if interval == 0 || lastCaptureWindowRefreshAt == 0 || time - lastCaptureWindowRefreshAt >= interval {
            currentCaptureWindow = targetManager.currentWindow(matching: target)
            lastCaptureWindowRefreshAt = time
        }
        return currentCaptureWindow
    }

    private func shouldCapture(_ event: CGEvent, destinationPID: pid_t, point: CGPoint, at time: TimeInterval,
                               currentWindow: TargetWindow?) -> Bool {
        guard let target else { return true } // No selected target retains global recording.
        guard let currentWindow else { return false }
        switch event.type {
        case .keyDown, .keyUp, .flagsChanged:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if event.type == .keyUp && recordedHeldKeys.contains(keyCode) { return true }
            if event.type == .flagsChanged && heldModifierCodes.contains(keyCode) { return true }
            return destinationPID > 0
                ? destinationPID == target.processIdentifier
                : NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier
        case .leftMouseUp, .rightMouseUp, .otherMouseUp,
             .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            guard let button = mouseButton(for: event) else { return false }
            return recordedHeldButtons.contains(button)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel:
            guard currentWindow.bounds.contains(point) else { return false }
            if destinationPID > 0 && destinationPID != target.processIdentifier {
                ClickDiagnostics.log("stage=record_hit result=otherPID type=\(event.type.rawValue) destinationPID=\(destinationPID) selectedPID=\(target.processIdentifier)")
                return false
            }
            let hitWindow = targetManager.window(at: point)
            if event.type != .scrollWheel {
                ClickDiagnostics.log("stage=record_hit type=\(event.type.rawValue) hitPID=\(hitWindow?.processIdentifier ?? -1) hitWindow=\(hitWindow?.id ?? -1) hitFrame=\(String(describing: hitWindow?.bounds)) selectedWindow=\(target.id)")
            }
            if let window = hitWindow {
                return window.id == target.id && window.processIdentifier == target.processIdentifier
            }
            return destinationPID == target.processIdentifier
        case .mouseMoved:
            guard currentWindow.bounds.contains(point),
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else { return false }
            // Keep window hit testing off the hot path of a 120 Hz event tap.
            if time - lastHoverCheckAt >= 0.03 || lastHoverCheckAt == 0 {
                lastHoverWindowID = targetManager.window(at: point)?.id
                lastHoverCheckAt = time
            }
            return lastHoverWindowID == target.id
        default:
            return false
        }
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
