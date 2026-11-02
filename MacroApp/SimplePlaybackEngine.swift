import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

@MainActor
protocol MacroPlaybackControlling: AnyObject {
    var state: RunState { get }
    var onLog: ((String, LogEntry.Level) -> Void)? { get set }
    var onFinish: ((MacroRunOutcome) -> Void)? { get set }
    func start(macro: MacroDefinition, target: TargetWindow, backend: any InputBackend)
    func togglePause()
    func stop()
}

extension MacroEngine: MacroPlaybackControlling {}

/// One scheduled item in the unchanged MacroAction recording format.
struct SimplePlaybackEvent {
    enum Kind {
        case keyDown(CGKeyCode, Bool)
        case keyUp(CGKeyCode)
        case mouseDown(MacroMouseButton)
        case mouseUp(MacroMouseButton)
        case move
        case scroll
    }

    let kind: Kind
    let elapsedNs: UInt64
    let actionIndex: Int
    let point: CGPoint
    let usesWindowCoordinates: Bool
    let clickCount: Int
    let scrollDeltaX: Double
    let scrollDeltaY: Double
    let scrollUnit: MacroScrollUnit
}

struct SimplePlaybackPlan {
    let events: [SimplePlaybackEvent]
    let durationNs: UInt64
    let actionCount: Int
    let iterationLimit: Int?
    let recordedWindowSize: CGSize?

    init(macro: MacroDefinition) throws {
        let enabled = macro.actions.filter(\.isEnabled)
        actionCount = enabled.count
        recordedWindowSize = macro.recordedWindowSize
        iterationLimit = switch macro.loopMode {
        case .once: 1
        case .count: max(1, macro.loopCount)
        case .infinite: nil
        }

        var time: UInt64 = 0
        var result: [SimplePlaybackEvent] = []
        for (index, action) in enabled.enumerated() {
            time = Self.add(time, seconds: action.delay)
            func append(_ kind: SimplePlaybackEvent.Kind) {
                result.append(SimplePlaybackEvent(
                    kind: kind, elapsedNs: time, actionIndex: index,
                    point: CGPoint(x: action.x ?? 0, y: action.y ?? 0),
                    usesWindowCoordinates: action.usesWindowCoordinates,
                    clickCount: action.clickCount,
                    scrollDeltaX: action.scrollDeltaX, scrollDeltaY: action.scrollDeltaY,
                    scrollUnit: action.scrollUnit
                ))
            }
            switch action.type {
            case .keyDown:
                append(.keyDown(try Self.keyCode(for: action), action.isKeyRepeat))
            case .keyUp:
                append(.keyUp(try Self.keyCode(for: action)))
            case .keyPress, .holdKey:
                let code = try Self.keyCode(for: action)
                append(.keyDown(code, false))
                time = Self.add(time, seconds: action.type == .keyPress
                    ? max(0.01, action.duration) : action.duration)
                append(.keyUp(code))
            case .wait:
                time = Self.add(time, seconds: action.duration)
            case .leftClick, .rightClick, .middleClick:
                let button: MacroMouseButton = switch action.type {
                case .leftClick: .left
                case .rightClick: .right
                default: .middle
                }
                append(.mouseDown(button))
                time = Self.add(time, seconds: max(0.01, action.duration))
                append(.mouseUp(button))
            case .mouseDown:
                append(.mouseDown(action.mouseButton))
            case .mouseUp:
                append(.mouseUp(action.mouseButton))
            case .move:
                append(.move)
            case .scroll:
                append(.scroll)
            }
        }
        events = result
        durationNs = time
    }

    private static func keyCode(for action: MacroAction) throws -> CGKeyCode {
        guard let key = action.key, let code = KeyCodeMapper.code(for: key) else {
            throw InputBackendError.invalidKey(action.key ?? "empty")
        }
        return code
    }

    private static func add(_ time: UInt64, seconds: Double) -> UInt64 {
        guard seconds.isFinite, seconds > 0 else { return time }
        let value = seconds * 1_000_000_000
        guard value.isFinite, value < Double(UInt64.max - time) else { return UInt64.max }
        return time + UInt64(value)
    }
}

protocol SimpleEventPosting: AnyObject {
    func post(_ event: SimplePlaybackEvent, in frame: CGRect, recordedWindowSize: CGSize?) throws
    func releaseHeldInputs()
}

/// A serial worker owns its poster and input ledger. No UI or MainActor call is
/// awaited between consecutive events. Deadlines contain recorded time plus
/// pause time only; dispatch lateness never changes a later deadline.
final class SimplePlaybackWorker: @unchecked Sendable {
    private let plan: SimplePlaybackPlan
    private let poster: any SimpleEventPosting
    private let validateTarget: () throws -> CGRect
    private let onProgress: (Int, Int) -> Void
    private let onComplete: (MacroRunOutcome) -> Void
    private let queue = DispatchQueue(label: "Macro.SimplePlayback", qos: .userInteractive)
    private let wake = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var cancelled = false
    private var pausedAt: UInt64?
    private var completedPauseNs: UInt64 = 0

    init(plan: SimplePlaybackPlan, poster: any SimpleEventPosting,
         validateTarget: @escaping () throws -> CGRect,
         onProgress: @escaping (Int, Int) -> Void,
         onComplete: @escaping (MacroRunOutcome) -> Void) {
        self.plan = plan
        self.poster = poster
        self.validateTarget = validateTarget
        self.onProgress = onProgress
        self.onComplete = onComplete
    }

    func start() { queue.async { self.run() } }

    func setPaused(_ paused: Bool) {
        lock.lock()
        if paused, pausedAt == nil {
            pausedAt = DispatchTime.now().uptimeNanoseconds
        } else if !paused, let startedAt = pausedAt {
            completedPauseNs += DispatchTime.now().uptimeNanoseconds - startedAt
            pausedAt = nil
        }
        lock.unlock()
        wake.signal()
    }

    func stop() {
        lock.lock()
        cancelled = true
        lock.unlock()
        wake.signal()
    }

    private func run() {
        var outcome: MacroRunOutcome = .completed
        defer {
            poster.releaseHeldInputs()
            onComplete(outcome)
        }
        guard plan.actionCount > 0 else { return }
        do {
            var iteration = 0
            while plan.iterationLimit == nil || iteration < plan.iterationLimit! {
                try checkStopped()
                iteration += 1
                let loopStart = DispatchTime.now().uptimeNanoseconds
                let basePause = pauseTotal()
                var frame = try validateTarget()
                var lastValidation = DispatchTime.now().uptimeNanoseconds
                var lastProgress = lastValidation

                for event in plan.events {
                    try waitUntil(loopStart: loopStart, elapsed: event.elapsedNs, basePause: basePause)
                    let now = DispatchTime.now().uptimeNanoseconds
                    if now - lastValidation >= 250_000_000 {
                        frame = try validateTarget()
                        lastValidation = DispatchTime.now().uptimeNanoseconds
                    }
                    try checkStopped()
                    try poster.post(event, in: frame, recordedWindowSize: plan.recordedWindowSize)
                    let postedAt = DispatchTime.now().uptimeNanoseconds
                    if postedAt - lastProgress >= 100_000_000 || event.actionIndex + 1 == plan.actionCount {
                        let current = event.actionIndex + 1
                        let total = plan.iterationLimit.map { plan.actionCount * $0 } ?? plan.actionCount
                        onProgress((iteration - 1) * plan.actionCount + current, total)
                        lastProgress = postedAt
                    }
                }
                try waitUntil(loopStart: loopStart, elapsed: plan.durationNs, basePause: basePause)
            }
        } catch is CancellationError {
            outcome = .stopped
        } catch {
            outcome = .failed(error.localizedDescription)
        }
    }

    private func checkStopped() throws {
        lock.lock()
        let stopped = cancelled
        lock.unlock()
        if stopped { throw CancellationError() }
    }

    private func pauseTotal() -> UInt64 {
        lock.lock()
        let value = completedPauseNs
        lock.unlock()
        return value
    }

    private func waitUntil(loopStart: UInt64, elapsed: UInt64, basePause: UInt64) throws {
        while true {
            lock.lock()
            let stopped = cancelled
            let paused = pausedAt != nil
            let pauseNs = completedPauseNs - basePause
            lock.unlock()
            if stopped { throw CancellationError() }
            if paused {
                wake.wait()
                continue
            }
            let (scheduled, overflow) = loopStart.addingReportingOverflow(elapsed)
            let base = overflow ? UInt64.max : scheduled
            let (withPause, pauseOverflow) = base.addingReportingOverflow(pauseNs)
            let deadline = pauseOverflow ? UInt64.max : withPause
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= deadline { return }
            _ = wake.wait(timeout: DispatchTime(uptimeNanoseconds: deadline))
        }
    }
}

/// CoreGraphics posting happens on the worker queue. The source and held-input
/// state are never accessed from the UI thread.
final class SimpleCGEventPoster: SimpleEventPosting {
    private let targetPID: pid_t
    private let mode: MousePlaybackMode
    private lazy var source: CGEventSource? = {
        let state: CGEventSourceStateID = mode == .background ? .privateState : .hidSystemState
        let source = CGEventSource(stateID: state)
        source?.localEventsSuppressionInterval = 0
        return source
    }()
    private var heldKeys = Set<CGKeyCode>()
    private var heldButtons = Set<MacroMouseButton>()
    private var modifiers = Set<CGKeyCode>()
    private var lastPoint = CGPoint.zero

    init(targetPID: pid_t, mode: MousePlaybackMode) {
        self.targetPID = targetPID
        self.mode = mode
    }

    func post(_ event: SimplePlaybackEvent, in frame: CGRect, recordedWindowSize: CGSize?) throws {
        let point = resolvedPoint(event, frame: frame, recordedWindowSize: recordedWindowSize)
        switch event.kind {
        case .keyDown(let code, let isRepeat):
            guard let key = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true) else {
                throw InputBackendError.eventCreationFailed
            }
            if isModifier(code) { modifiers.insert(code) }
            key.flags = modifierFlags
            if isRepeat { key.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
            postEvent(key)
            heldKeys.insert(code)
        case .keyUp(let code):
            guard let key = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else {
                throw InputBackendError.eventCreationFailed
            }
            if isModifier(code) { modifiers.remove(code) }
            key.flags = modifierFlags
            postEvent(key)
            heldKeys.remove(code)
        case .mouseDown(let button):
            try postMouse(type: button.downType, button: button, point: point, clickCount: event.clickCount)
            heldButtons.insert(button)
            lastPoint = point
        case .mouseUp(let button):
            try postMouse(type: button.upType, button: button, point: point, clickCount: event.clickCount)
            heldButtons.remove(button)
            lastPoint = point
        case .move:
            if let button = [MacroMouseButton.left, .right, .middle].first(where: { heldButtons.contains($0) }) {
                try postMouse(type: button.dragType, button: button, point: point, clickCount: event.clickCount)
            } else {
                try postMouse(type: .mouseMoved, button: .left, point: point, clickCount: event.clickCount)
            }
            lastPoint = point
        case .scroll:
            guard let wheel = CGEvent(scrollWheelEvent2Source: source,
                                      units: event.scrollUnit == .pixel ? .pixel : .line,
                                      wheelCount: 2, wheel1: scrollValue(event.scrollDeltaY),
                                      wheel2: scrollValue(event.scrollDeltaX), wheel3: 0) else {
                throw InputBackendError.eventCreationFailed
            }
            wheel.location = point
            wheel.flags = modifierFlags
            postEvent(wheel)
            lastPoint = point
        }
    }

    func releaseHeldInputs() {
        for code in heldKeys {
            if let key = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) {
                if isModifier(code) { modifiers.remove(code) }
                key.flags = modifierFlags
                postEvent(key)
            }
        }
        for button in heldButtons {
            try? postMouse(type: button.upType, button: button, point: lastPoint, clickCount: 1)
        }
        heldKeys.removeAll()
        heldButtons.removeAll()
        modifiers.removeAll()
    }

    private func postMouse(type: CGEventType, button: MacroMouseButton,
                           point: CGPoint, clickCount: Int) throws {
        guard let mouse = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: button.cgButton) else {
            throw InputBackendError.eventCreationFailed
        }
        mouse.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, clickCount)))
        mouse.flags = modifierFlags
        postEvent(mouse)
    }

    private func postEvent(_ event: CGEvent) {
        if mode == .background { event.postToPid(targetPID) }
        else { event.post(tap: .cghidEventTap) }
    }

    private func resolvedPoint(_ event: SimplePlaybackEvent, frame: CGRect,
                               recordedWindowSize: CGSize?) -> CGPoint {
        guard event.usesWindowCoordinates else { return event.point }
        let scaled: CGPoint
        if let size = recordedWindowSize, size.width > 0, size.height > 0 {
            scaled = CGPoint(x: event.point.x * frame.width / size.width,
                             y: event.point.y * frame.height / size.height)
        } else {
            scaled = event.point
        }
        return CGPoint(x: frame.minX + min(max(0, scaled.x), max(0, frame.width.nextDown)),
                       y: frame.minY + min(max(0, scaled.y), max(0, frame.height.nextDown)))
    }

    private func isModifier(_ code: CGKeyCode) -> Bool { (54...63).contains(code) }

    private func scrollValue(_ value: Double) -> Int32 {
        guard value.isFinite, value != 0 else { return 0 }
        let clamped = min(max(value.rounded(), Double(Int32.min)), Double(Int32.max))
        let rounded = Int32(clamped)
        return rounded == 0 ? (value > 0 ? 1 : -1) : rounded
    }

    private var modifierFlags: CGEventFlags {
        var flags: CGEventFlags = []
        for code in modifiers {
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
}

enum SimpleTargetValidation {
    static func frame(pid: pid_t, windowID: Int, mode: MousePlaybackMode) throws -> CGRect {
        guard AXIsProcessTrusted() else { throw InputBackendError.accessibilityRequired }
        if mode == .compatibility, !CGPreflightPostEventAccess() {
            throw InputBackendError.eventPostingRequired
        }
        guard kill(pid, 0) == 0 else { throw InputBackendError.targetUnavailable }
        guard let raw = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowID)) as? [[String: Any]],
              let information = raw.first(where: {
                  ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == windowID &&
                  ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
              }),
              let dictionary = information[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: dictionary),
              bounds.width > 0, bounds.height > 0 else {
            throw InputBackendError.targetWindowUnavailable
        }
        return bounds
    }
}

@MainActor
final class SimplePlaybackEngine: MacroPlaybackControlling {
    static var useLegacyFallback: Bool {
        ProcessInfo.processInfo.environment["MACRO_USE_LEGACY_PLAYBACK"] == "1" ||
        UserDefaults.standard.bool(forKey: "UseLegacyPlaybackEngine")
    }

    var onStateChange: ((RunState) -> Void)?
    var onLog: ((String, LogEntry.Level) -> Void)?
    var onProgress: ((PlaybackProgress?) -> Void)?
    var onFinish: ((MacroRunOutcome) -> Void)?
    private(set) var state: RunState = .idle
    private var worker: SimplePlaybackWorker?

    func start(macro: MacroDefinition, target: TargetWindow, backend: any InputBackend) {
        guard state == .idle else { return }
        let plan: SimplePlaybackPlan
        do { plan = try SimplePlaybackPlan(macro: macro) }
        catch {
            onLog?("Macro error: \(error.localizedDescription)", .error)
            onStateChange?(.idle)
            onFinish?(.failed(error.localizedDescription))
            return
        }
        let mode = backend.mousePlaybackMode
        let pid = target.processIdentifier
        let windowID = target.id
        let poster = SimpleCGEventPoster(targetPID: pid, mode: mode)
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let recordedSeconds = Double(plan.durationNs) / 1_000_000_000 * Double(plan.iterationLimit ?? 1)
        let worker = SimplePlaybackWorker(plan: plan, poster: poster,
            validateTarget: { try SimpleTargetValidation.frame(pid: pid, windowID: windowID, mode: mode) },
            onProgress: { [weak self] current, total in
                Task { @MainActor in self?.onProgress?(PlaybackProgress(current: current, total: total)) }
            },
            onComplete: { [weak self] outcome in
                let elapsedSeconds = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000_000
                Task { @MainActor in self?.finish(outcome, elapsedSeconds: elapsedSeconds,
                                                   recordedSeconds: recordedSeconds) }
            })
        self.worker = worker
        setState(.running)
        onLog?("Macro started with simple playback (\(backend.displayName))", .info)
        worker.start()
    }

    func togglePause() {
        guard state == .running || state == .paused else { return }
        let paused = state == .running
        worker?.setPaused(paused)
        setState(paused ? .paused : .running)
        onLog?(paused ? "Macro paused" : "Macro resumed", .info)
    }

    func stop() {
        guard state != .idle else { return }
        worker?.stop()
        onProgress?(nil)
    }

    private func finish(_ outcome: MacroRunOutcome, elapsedSeconds: Double, recordedSeconds: Double) {
        worker = nil
        onProgress?(nil)
        setState(.idle)
        switch outcome {
        case .completed:
            onLog?(String(format: "Macro completed in %.2fs (recorded %.2fs)",
                          elapsedSeconds, recordedSeconds), .info)
        case .stopped: onLog?("Macro stopped", .info)
        case .failed(let message): onLog?("Macro error: \(message)", .error)
        }
        onFinish?(outcome)
    }

    private func setState(_ newState: RunState) {
        state = newState
        onStateChange?(newState)
    }
}
