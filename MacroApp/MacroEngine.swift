import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum MacroRunOutcome: Equatable {
    case completed
    case stopped
    case failed(String)
}

@MainActor
final class MacroEngine {
    private struct DispatchStamp {
        let preCall: UInt64
        let postReturn: UInt64
    }

    #if DEBUG
    private struct PlaybackProfile {
        var startedAt: UInt64 = 0
        var recordedDelayNs: UInt64 = 0
        var actions = 0
        var moves = 0
        var lastActionAt: UInt64 = 0
        var timelineShiftNs: UInt64 = 0
        var windowResolutionNs: UInt64 = 0
        var focusCheckNs: UInt64 = 0
        var progressNs: UInt64 = 0
        var backendNs: UInt64 = 0
        var moveBackendNs: UInt64 = 0
        var wakeLateNs: UInt64 = 0
        var maxWakeLateNs: UInt64 = 0
        var readyBacklogNs: UInt64 = 0
        var maxDispatchLateNs: UInt64 = 0
        var maxMoveDispatchLateNs: UInt64 = 0
    }
    #endif

    var onStateChange: ((RunState) -> Void)?
    var onLog: ((String, LogEntry.Level) -> Void)?
    var onProgress: ((PlaybackProgress?) -> Void)?
    var onFinish: ((MacroRunOutcome) -> Void)?
    #if DEBUG
    var onDispatchTiming: ((Int, String, UInt64?, UInt64, UInt64) -> Void)?
    #endif

    private var task: Task<Void, Never>?
    private var backend: (any InputBackend)?
    private var target: TargetWindow?
    private var heldKeys = Set<CGKeyCode>()
    private var heldButtons = Set<MacroMouseButton>()
    private var heldKeyDownAt: [CGKeyCode: DispatchStamp] = [:]
    private var heldButtonDownAt: [MacroMouseButton: DispatchStamp] = [:]
    private var pauseStartedAt: UInt64?
    private var completedPauseDuration: UInt64 = 0
    private var accountedPauseDuration: UInt64 = 0
    private var lastMousePoint = CGPoint.zero
    private var recordedWindowSize: CGSize?
    private var recordedWindowOrigin: CGPoint?
    private var lastTargetRefreshAt: UInt64 = 0
    private var lastProgressNotification: UInt64 = 0
    private var lastMoveLog: UInt64 = 0
    private var lastFocusCheckAt: UInt64 = 0
    #if DEBUG
    private let accuracyLoggingEnabled = ProcessInfo.processInfo.environment["MACRO_ACCURACY_LOG"] == "1"
    private var playbackProfile = PlaybackProfile()
    #endif
    private(set) var state: RunState = .idle
    private let isAuthorized: () -> Bool
    private let targetIsRunning: (pid_t) -> Bool
    private let targetWindowResolver: (TargetWindow) -> TargetWindow?
    private let frontmostPID: () -> pid_t?
    private let focusedWindowStatus: (TargetWindow) -> TargetWindowFocus

    init(
        isAuthorized: @escaping () -> Bool = { AXIsProcessTrusted() },
        targetIsRunning: @escaping (pid_t) -> Bool = { kill($0, 0) == 0 },
        targetWindowResolver: @escaping (TargetWindow) -> TargetWindow? = { TargetManager().currentWindow(matching: $0) },
        frontmostPID: @escaping () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier },
        focusedWindowStatus: @escaping (TargetWindow) -> TargetWindowFocus = { TargetManager().focusedWindowStatus(matching: $0) }
    ) {
        self.isAuthorized = isAuthorized
        self.targetIsRunning = targetIsRunning
        self.targetWindowResolver = targetWindowResolver
        self.frontmostPID = frontmostPID
        self.focusedWindowStatus = focusedWindowStatus
    }

    func start(macro: MacroDefinition, target: TargetWindow, backend: any InputBackend) {
        guard state == .idle else { return }
        self.backend = backend
        self.target = target
        backend.resetInputState()
        heldKeyDownAt.removeAll()
        heldButtonDownAt.removeAll()
        pauseStartedAt = nil
        completedPauseDuration = 0
        accountedPauseDuration = 0
        recordedWindowSize = macro.recordedWindowSize
        recordedWindowOrigin = macro.recordedWindowOrigin
        lastTargetRefreshAt = 0
        lastProgressNotification = 0
        lastMoveLog = 0
        lastFocusCheckAt = 0
        #if DEBUG
        playbackProfile = PlaybackProfile()
        #endif
        ClickDiagnostics.log("stage=playback_start macroID=\(macro.id) mode=\(backend.mousePlaybackMode.rawValue) selectedPID=\(target.processIdentifier) selectedWindow=\(target.id) selectedFrame=\(target.bounds) recordedFrame=\(String(describing: macro.recordedWindowOrigin.flatMap { origin in macro.recordedWindowSize.map { CGRect(origin: origin, size: $0) } }))")
        setState(.running)
        log("Macro started with \(backend.displayName)")

        task = Task { [weak self] in
            guard let self else { return }
            var outcome: MacroRunOutcome = .completed
            do {
                try await self.run(macro: macro, target: target, backend: backend)
                if !Task.isCancelled { self.log("Macro completed") }
            } catch is CancellationError {
                outcome = .stopped
                self.log("Macro stopped")
            } catch {
                outcome = .failed(error.localizedDescription)
                self.log("Macro error: \(error.localizedDescription)", level: .error)
            }
            #if DEBUG
            self.logPlaybackProfile(macroID: macro.id, outcome: outcome)
            #endif
            self.releaseHeldInputs()
            self.onProgress?(nil)
            self.task = nil
            self.setState(.idle)
            self.onFinish?(outcome)
        }
    }

    func togglePause() {
        guard state == .running || state == .paused else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        if state == .running {
            pauseStartedAt = now
            setState(.paused)
        } else {
            if let pauseStartedAt {
                completedPauseDuration = addingSaturating(completedPauseDuration, now - pauseStartedAt)
            }
            pauseStartedAt = nil
            setState(.running)
        }
        log(state == .paused ? "Macro paused" : "Macro resumed")
    }

    func stop() {
        guard state != .idle else { return }
        task?.cancel()
        releaseHeldInputs()
        onProgress?(nil)
        // Keep this run active until its task has unwound. A new run must not
        // start while the canceled task can still release held input.
    }

    private func run(
        macro: MacroDefinition,
        target: TargetWindow,
        backend: any InputBackend
    ) async throws {
        let iterationLimit: Int? = switch macro.loopMode {
        case .once: 1
        case .count: max(1, macro.loopCount)
        case .infinite: nil
        }

        let enabledActions = macro.actions.filter(\.isEnabled)
        guard !enabledActions.isEmpty else { return }
        let progressTotal = max(1, iterationLimit.map { enabledActions.count * $0 } ?? enabledActions.count)
        var completedActions = 0

        var iteration = 0
        while iterationLimit == nil || iteration < iterationLimit! {
            try Task.checkCancellation()
            iteration += 1
            if iteration > 1 { log("Loop \(iteration)") }

            let playbackStart = DispatchTime.now().uptimeNanoseconds
            #if DEBUG
            if playbackProfile.startedAt == 0 { playbackProfile.startedAt = playbackStart }
            #endif
            var recordedDeadline = playbackStart
            var timelineShift: UInt64 = 0
            for (index, action) in enabledActions.enumerated() {
                try Task.checkCancellation()
                recordedDeadline = deadline(recordedDeadline, adding: action.delay)
                guard isAuthorized() else { throw InputBackendError.accessibilityRequired }
                guard targetIsRunning(target.processIdentifier) else { throw InputBackendError.targetUnavailable }

                let requestedDeadline = addingSaturating(recordedDeadline, timelineShift)
                #if DEBUG
                let waitStartedAt = DispatchTime.now().uptimeNanoseconds
                #endif
                var eventDeadline = try await waitUntilPausably(requestedDeadline)
                #if DEBUG
                let readyAt = DispatchTime.now().uptimeNanoseconds
                if waitStartedAt >= eventDeadline {
                    playbackProfile.readyBacklogNs = addingSaturating(
                        playbackProfile.readyBacklogNs, waitStartedAt - eventDeadline)
                } else if readyAt > eventDeadline {
                    let late = readyAt - eventDeadline
                    playbackProfile.wakeLateNs = addingSaturating(playbackProfile.wakeLateNs, late)
                    playbackProfile.maxWakeLateNs = max(playbackProfile.maxWakeLateNs, late)
                }
                #endif
                // A pause extends the logical timeline without counting as
                // dispatch lag. The existing pause behavior is preserved.
                recordedDeadline = addingSaturating(recordedDeadline, eventDeadline - requestedDeadline)
                let progressCurrent = iterationLimit == nil
                    ? (completedActions % max(1, enabledActions.count)) + 1
                    : completedActions + 1
                let progressTime = DispatchTime.now().uptimeNanoseconds
                if action.type != .move || progressTime &- lastProgressNotification >= 100_000_000 {
                    onProgress?(PlaybackProgress(current: progressCurrent, total: progressTotal))
                    #if DEBUG
                    playbackProfile.progressNs = addingSaturating(
                        playbackProfile.progressNs, DispatchTime.now().uptimeNanoseconds - progressTime)
                    #endif
                    lastProgressNotification = progressTime
                }
                try Task.checkCancellation()
                if state == .paused || completedPauseDuration != accountedPauseDuration {
                    let resumedDeadline = try await waitUntilPausably(eventDeadline)
                    recordedDeadline = addingSaturating(recordedDeadline, resumedDeadline - eventDeadline)
                    eventDeadline = resumedDeadline
                }
                let dispatch = try await execute(action, index: index, deadline: eventDeadline,
                                                 playbackStart: playbackStart, target: target, backend: backend)
                // Carry the largest observed lag forward, rather than adding
                // each late action's lag again. A new press uses backend return
                // as a conservative start bound so its release cannot shorten
                // the recorded hold. Other actions use their dispatch attempt:
                // backend work on a release must not add an extra scheduled gap.
                if let dispatch {
                    let reference = (action.type == .keyDown && !action.isKeyRepeat) || action.type == .mouseDown
                        ? dispatch.postReturn : dispatch.preCall
                    timelineShift = max(timelineShift, reference &- min(reference, recordedDeadline))
                }
                // Actions such as a configured Key Press or mouse click have an
                // intrinsic duration. The next recorded delay starts after them.
                switch action.type {
                case .keyPress, .holdKey, .wait, .leftClick, .rightClick, .middleClick:
                    let now = DispatchTime.now().uptimeNanoseconds
                    recordedDeadline = max(recordedDeadline, now &- min(now, timelineShift))
                case .keyDown, .keyUp, .mouseDown, .mouseUp, .move, .scroll:
                    break
                }
                completedActions += 1
                #if DEBUG
                playbackProfile.actions += 1
                if action.type == .move { playbackProfile.moves += 1 }
                playbackProfile.recordedDelayNs = addingSaturating(
                    playbackProfile.recordedDelayNs, deadline(0, adding: action.delay))
                playbackProfile.timelineShiftNs = timelineShift
                playbackProfile.lastActionAt = DispatchTime.now().uptimeNanoseconds
                if playbackProfile.actions.isMultiple(of: 25) {
                    logPlaybackCheckpoint(index: index)
                }
                #endif
            }
        }
    }

    private func execute(
        _ action: MacroAction,
        index: Int,
        deadline: UInt64,
        playbackStart: UInt64,
        target: TargetWindow,
        backend: any InputBackend
    ) async throws -> DispatchStamp? {
        let selectedTarget = target
        let target: TargetWindow
        do {
            #if DEBUG
            let resolutionStartedAt = DispatchTime.now().uptimeNanoseconds
            #endif
            target = try currentTarget(for: action, initial: selectedTarget)
            #if DEBUG
            playbackProfile.windowResolutionNs = addingSaturating(
                playbackProfile.windowResolutionNs,
                DispatchTime.now().uptimeNanoseconds - resolutionStartedAt)
            let focusStartedAt = DispatchTime.now().uptimeNanoseconds
            #endif
            if action.type != .wait { try verifyFocus(for: action, target: target, backend: backend) }
            #if DEBUG
            playbackProfile.focusCheckNs = addingSaturating(
                playbackProfile.focusCheckNs, DispatchTime.now().uptimeNanoseconds - focusStartedAt)
            #endif
        } catch {
            if isClickAction(action) {
                ClickDiagnostics.log("stage=playback_blocked index=\(index) actionID=\(action.id) type=\(action.type.rawValue) selectedPID=\(selectedTarget.processIdentifier) selectedWindow=\(selectedTarget.id) error=\(error.localizedDescription)")
            }
            throw error
        }
        switch action.type {
        case .keyDown:
            let code = try keyCode(for: action)
            let stamp = try timedPost(action, phase: action.isKeyRepeat ? "repeat" : "down", index: index,
                                      deadline: deadline, playbackStart: playbackStart, target: target, backend: backend) {
                try backend.keyDown(code, target: target, isRepeat: action.isKeyRepeat)
            }
            heldKeys.insert(code)
            if !action.isKeyRepeat { heldKeyDownAt[code] = stamp }
            if !action.isKeyRepeat { log("\(action.key?.uppercased() ?? "KEY") DOWN") }
            return stamp

        case .keyUp:
            let code = try keyCode(for: action)
            let stamp = try timedPost(action, phase: "up", index: index, deadline: deadline,
                                      playbackStart: playbackStart, target: target, backend: backend) {
                try backend.keyUp(code, target: target)
            }
            traceHold(action, phase: "key", index: index, down: heldKeyDownAt.removeValue(forKey: code), up: stamp)
            heldKeys.remove(code)
            log("\(action.key?.uppercased() ?? "KEY") UP")
            return stamp

        case .keyPress:
            let code = try keyCode(for: action)
            let down = try timedPost(action, phase: "down", index: index, deadline: deadline,
                                     playbackStart: playbackStart, target: target, backend: backend) {
                try backend.keyDown(code, target: target)
            }
            heldKeys.insert(code)
            heldKeyDownAt[code] = down
            let upDeadline = try await sleepPausably(seconds: max(0.01, action.duration))
            let up = try timedPost(action, phase: "up", index: index, deadline: upDeadline,
                                   playbackStart: playbackStart, target: target, backend: backend) {
                try backend.keyUp(code, target: target)
            }
            traceHold(action, phase: "key", index: index, down: heldKeyDownAt.removeValue(forKey: code), up: up)
            heldKeys.remove(code)
            log("\(action.key?.uppercased() ?? "KEY") PRESS")
            return up

        case .holdKey:
            let code = try keyCode(for: action)
            let down = try timedPost(action, phase: "down", index: index, deadline: deadline,
                                     playbackStart: playbackStart, target: target, backend: backend) {
                try backend.keyDown(code, target: target)
            }
            heldKeys.insert(code)
            heldKeyDownAt[code] = down
            log("\(action.key?.uppercased() ?? "KEY") HOLD")
            let upDeadline = try await sleepPausably(seconds: action.duration)
            let up = try timedPost(action, phase: "up", index: index, deadline: upDeadline,
                                   playbackStart: playbackStart, target: target, backend: backend) {
                try backend.keyUp(code, target: target)
            }
            traceHold(action, phase: "key", index: index, down: heldKeyDownAt.removeValue(forKey: code), up: up)
            heldKeys.remove(code)
            log("\(action.key?.uppercased() ?? "KEY") RELEASE")
            return up

        case .wait:
            log("WAIT \(String(format: "%.3f", action.duration))s")
            _ = try await sleepPausably(seconds: action.duration)
            return nil

        case .leftClick, .rightClick, .middleClick:
            let button: MacroMouseButton = switch action.type {
            case .leftClick: .left
            case .rightClick: .right
            default: .middle
            }
            let point = resolvedPoint(action, target: target)
            let down = try sendClick(action, phase: "down", index: index, deadline: deadline, playbackStart: playbackStart,
                          selectedTarget: selectedTarget, target: target, point: point, backend: backend) {
                try backend.mouseDown(button, at: point, clickCount: action.clickCount, target: target)
            }
            heldButtons.insert(button)
            heldButtonDownAt[button] = down
            lastMousePoint = point
            let upDeadline = try await sleepPausably(seconds: max(0.01, action.duration))
            let up = try sendClick(action, phase: "up", index: index, deadline: upDeadline, playbackStart: playbackStart,
                          selectedTarget: selectedTarget, target: target, point: point, backend: backend) {
                try backend.mouseUp(button, at: point, clickCount: action.clickCount, target: target)
            }
            heldButtons.remove(button)
            traceHold(action, phase: "mouse", index: index, down: heldButtonDownAt.removeValue(forKey: button), up: up)
            log("\(button.title.uppercased()) CLICK at \(Int(point.x)), \(Int(point.y))")
            return up

        case .mouseDown:
            let point = resolvedPoint(action, target: target)
            let stamp = try sendClick(action, phase: "down", index: index, deadline: deadline, playbackStart: playbackStart,
                          selectedTarget: selectedTarget, target: target, point: point, backend: backend) {
                try backend.mouseDown(action.mouseButton, at: point, clickCount: action.clickCount, target: target)
            }
            heldButtons.insert(action.mouseButton)
            heldButtonDownAt[action.mouseButton] = stamp
            lastMousePoint = point
            log("\(action.mouseButton.title.uppercased()) MOUSE DOWN")
            return stamp

        case .mouseUp:
            let point = resolvedPoint(action, target: target)
            let stamp = try sendClick(action, phase: "up", index: index, deadline: deadline, playbackStart: playbackStart,
                          selectedTarget: selectedTarget, target: target, point: point, backend: backend) {
                try backend.mouseUp(action.mouseButton, at: point, clickCount: action.clickCount, target: target)
            }
            heldButtons.remove(action.mouseButton)
            traceHold(action, phase: "mouse", index: index, down: heldButtonDownAt.removeValue(forKey: action.mouseButton), up: stamp)
            lastMousePoint = point
            log("\(action.mouseButton.title.uppercased()) MOUSE UP")
            return stamp

        case .move:
            let point = resolvedPoint(action, target: target)
            let stamp = try timedPost(action, phase: heldButtons.isEmpty ? "move" : "drag", index: index,
                                      deadline: deadline, playbackStart: playbackStart, target: target, backend: backend) {
                if let button = heldButtons.first {
                    try backend.mouseDrag(button, to: point, target: target)
                } else {
                    try backend.mouseMove(to: point, target: target)
                }
            }
            lastMousePoint = point
            let logTime = DispatchTime.now().uptimeNanoseconds
            if logTime &- lastMoveLog >= 250_000_000 {
                log("MOVE to \(Int(point.x)), \(Int(point.y))")
                lastMoveLog = logTime
            }
            return stamp

        case .scroll:
            let point = resolvedPoint(action, target: target)
            let stamp = try timedPost(action, phase: "scroll", index: index, deadline: deadline,
                                      playbackStart: playbackStart, target: target, backend: backend) {
                try backend.scroll(deltaX: action.scrollDeltaX, deltaY: action.scrollDeltaY,
                                   units: action.scrollUnit, at: point, target: target)
            }
            lastMousePoint = point
            log("SCROLL \(Int(action.scrollDeltaX)), \(Int(action.scrollDeltaY))")
            return stamp
        }
    }

    private func currentTarget(for action: MacroAction, initial: TargetWindow) throws -> TargetWindow {
        switch action.type {
        case .wait:
            return target ?? initial
        default:
            break
        }

        let now = DispatchTime.now().uptimeNanoseconds
        // Discovering a window on every 120 Hz movement sample can itself
        // introduce replay lag. Button transitions always get a fresh frame.
        if action.type == .move, lastTargetRefreshAt != 0,
           now &- lastTargetRefreshAt < 30_000_000, let target {
            return target
        }
        guard let current = targetWindowResolver(initial) else {
            throw InputBackendError.targetWindowUnavailable
        }
        target = current
        lastTargetRefreshAt = now
        return current
    }

    private func verifyFocus(for action: MacroAction, target: TargetWindow, backend: any InputBackend) throws {
        guard backend.mousePlaybackMode == .compatibility else { return }
        guard frontmostPID() == target.processIdentifier else { throw InputBackendError.targetFocusChanged }
        let now = DispatchTime.now().uptimeNanoseconds
        if action.type == .move && lastFocusCheckAt != 0 && now &- lastFocusCheckAt < 100_000_000 { return }
        lastFocusCheckAt = now
        if case .different = focusedWindowStatus(target) { throw InputBackendError.targetFocusChanged }
    }

    private func timedPost(_ action: MacroAction, phase: String, index: Int, deadline: UInt64?,
                           playbackStart: UInt64, target: TargetWindow, backend: any InputBackend,
                           post: () throws -> Void) throws -> DispatchStamp {
        let preCall = DispatchTime.now().uptimeNanoseconds
        do {
            try post()
        } catch {
            #if DEBUG
            if accuracyLoggingEnabled {
                ClickDiagnostics.log("stage=timing index=\(index) actionID=\(action.id) type=\(action.type.rawValue) phase=\(phase) expectedNs=\(deadline.map(String.init) ?? "none") preCallNs=\(preCall) outcome=backendError")
            }
            #endif
            throw error
        }
        let stamp = DispatchStamp(preCall: preCall, postReturn: DispatchTime.now().uptimeNanoseconds)
        #if DEBUG
        playbackProfile.backendNs = addingSaturating(playbackProfile.backendNs, stamp.postReturn - stamp.preCall)
        if action.type == .move {
            playbackProfile.moveBackendNs = addingSaturating(
                playbackProfile.moveBackendNs, stamp.postReturn - stamp.preCall)
        }
        if let deadline, preCall > deadline {
            let late = preCall - deadline
            playbackProfile.maxDispatchLateNs = max(playbackProfile.maxDispatchLateNs, late)
            if action.type == .move {
                playbackProfile.maxMoveDispatchLateNs = max(playbackProfile.maxMoveDispatchLateNs, late)
            }
        }
        onDispatchTiming?(index, phase, deadline, preCall, stamp.postReturn)
        if accuracyLoggingEnabled {
            ClickDiagnostics.log("stage=timing index=\(index) actionID=\(action.id) type=\(action.type.rawValue) phase=\(phase) mode=\(backend.mousePlaybackMode.rawValue) pid=\(target.processIdentifier) window=\(target.id) expectedNs=\(deadline.map(String.init) ?? "none") expectedElapsedMs=\(deadline.map { Double($0 &- min($0, playbackStart)) / 1_000_000 } ?? .nan) actualDispatchAttemptNs=\(preCall) backendReturnNs=\(stamp.postReturn) latenessMs=\(deadline.map { (Double(preCall) - Double($0)) / 1_000_000 } ?? .nan) outcome=postCallReturned")
        }
        #endif
        return stamp
    }

    #if DEBUG
    private func logPlaybackCheckpoint(index: Int) {
        guard ClickDiagnostics.enabled, playbackProfile.startedAt != 0 else { return }
        let p = playbackProfile
        ClickDiagnostics.log("stage=playback_timing_checkpoint index=\(index) actions=\(p.actions) moves=\(p.moves) recordedDelayMs=\(Double(p.recordedDelayNs) / 1_000_000) elapsedMs=\(Double(p.lastActionAt - p.startedAt) / 1_000_000) timelineShiftMs=\(Double(p.timelineShiftNs) / 1_000_000) windowResolutionMs=\(Double(p.windowResolutionNs) / 1_000_000) focusCheckMs=\(Double(p.focusCheckNs) / 1_000_000) backendMs=\(Double(p.backendNs) / 1_000_000) moveBackendMs=\(Double(p.moveBackendNs) / 1_000_000) progressMs=\(Double(p.progressNs) / 1_000_000) wakeLateMs=\(Double(p.wakeLateNs) / 1_000_000) maxWakeLateMs=\(Double(p.maxWakeLateNs) / 1_000_000) readyBacklogMs=\(Double(p.readyBacklogNs) / 1_000_000) maxDispatchLateMs=\(Double(p.maxDispatchLateNs) / 1_000_000) maxMoveDispatchLateMs=\(Double(p.maxMoveDispatchLateNs) / 1_000_000)")
    }

    private func logPlaybackProfile(macroID: UUID, outcome: MacroRunOutcome) {
        guard ClickDiagnostics.enabled, playbackProfile.startedAt != 0 else { return }
        let p = playbackProfile
        let result: String = switch outcome {
        case .completed: "completed"
        case .stopped: "stopped"
        case .failed: "failed"
        }
        ClickDiagnostics.log("stage=playback_timing_summary macroID=\(macroID) outcome=\(result) actions=\(p.actions) moves=\(p.moves) recordedDelayMs=\(Double(p.recordedDelayNs) / 1_000_000) elapsedMs=\(Double(DispatchTime.now().uptimeNanoseconds - p.startedAt) / 1_000_000) timelineShiftMs=\(Double(p.timelineShiftNs) / 1_000_000) pausedMs=\(Double(completedPauseDuration) / 1_000_000) windowResolutionMs=\(Double(p.windowResolutionNs) / 1_000_000) focusCheckMs=\(Double(p.focusCheckNs) / 1_000_000) backendMs=\(Double(p.backendNs) / 1_000_000) moveBackendMs=\(Double(p.moveBackendNs) / 1_000_000) progressMs=\(Double(p.progressNs) / 1_000_000) wakeLateMs=\(Double(p.wakeLateNs) / 1_000_000) maxWakeLateMs=\(Double(p.maxWakeLateNs) / 1_000_000) readyBacklogMs=\(Double(p.readyBacklogNs) / 1_000_000) maxDispatchLateMs=\(Double(p.maxDispatchLateNs) / 1_000_000) maxMoveDispatchLateMs=\(Double(p.maxMoveDispatchLateNs) / 1_000_000)")
    }
    #endif

    private func traceHold(_ action: MacroAction, phase: String, index: Int,
                           down: DispatchStamp?, up: DispatchStamp) {
        #if DEBUG
        guard accuracyLoggingEnabled, let down else { return }
        ClickDiagnostics.log("stage=press_duration index=\(index) actionID=\(action.id) kind=\(phase) durationBasis=backendCallStart actualPressDurationMs=\(Double(up.preCall &- down.preCall) / 1_000_000) afterDownReturnMs=\(Double(up.preCall &- down.postReturn) / 1_000_000) downDispatchAttemptNs=\(down.preCall) upDispatchAttemptNs=\(up.preCall)")
        #endif
    }

    private func isClickAction(_ action: MacroAction) -> Bool {
        switch action.type {
        case .mouseDown, .mouseUp, .leftClick, .rightClick, .middleClick: true
        default: false
        }
    }

    private func sendClick(_ action: MacroAction, phase: String, index: Int, deadline: UInt64?,
                           playbackStart: UInt64, selectedTarget: TargetWindow, target: TargetWindow,
                           point: CGPoint, backend: any InputBackend, post: () throws -> Void) throws -> DispatchStamp {
        let frontmostAtDispatch = ClickDiagnostics.enabled ? frontmostPID() : nil
        let prePost = DispatchTime.now().uptimeNanoseconds
        do {
            let stamp = try timedPost(action, phase: phase, index: index, deadline: deadline,
                                      playbackStart: playbackStart, target: target, backend: backend, post: post)
            traceClick(action, phase: phase, index: index, deadline: deadline, playbackStart: playbackStart,
                       selectedTarget: selectedTarget, target: target, point: point, backend: backend,
                       prePost: stamp.preCall, frontmostAtDispatch: frontmostAtDispatch, outcome: "postCallReturned")
            return stamp
        } catch {
            traceClick(action, phase: phase, index: index, deadline: deadline, playbackStart: playbackStart,
                       selectedTarget: selectedTarget, target: target, point: point, backend: backend,
                       prePost: prePost, frontmostAtDispatch: frontmostAtDispatch, outcome: "error")
            throw error
        }
    }

    private func traceClick(_ action: MacroAction, phase: String, index: Int, deadline: UInt64?,
                            playbackStart: UInt64, selectedTarget: TargetWindow, target: TargetWindow,
                            point: CGPoint, backend: any InputBackend, prePost: UInt64,
                            frontmostAtDispatch: pid_t?, outcome: String) {
        guard ClickDiagnostics.enabled else { return }
        let expected = deadline.map(String.init) ?? "noneConfiguredClickUp"
        let lateMs = deadline.map { (Double(prePost) - Double($0)) / 1_000_000 }
        let recordedScreen = CGPoint(x: action.recordedScreenX ?? .nan, y: action.recordedScreenY ?? .nan)
        let screenDelta = CGPoint(x: point.x - recordedScreen.x, y: point.y - recordedScreen.y)
        let recordedFrame = recordedWindowOrigin.flatMap { origin in
            recordedWindowSize.map { CGRect(origin: origin, size: $0) }
        }
        let scaledLocal = recordedWindowSize.map { size in
            CGPoint(x: (action.x ?? 0) * target.bounds.width / size.width,
                    y: (action.y ?? 0) * target.bounds.height / size.height)
        }
        let unclamped = scaledLocal.map { CGPoint(x: target.bounds.minX + $0.x, y: target.bounds.minY + $0.y) }
        let clampDelta = unclamped.map { CGPoint(x: point.x - $0.x, y: point.y - $0.y) }
        ClickDiagnostics.log("stage=playback_ready index=\(index) actionID=\(action.id) type=\(action.type.rawValue) phase=\(phase) outcome=\(outcome) mode=\(backend.mousePlaybackMode.rawValue) selectedPID=\(selectedTarget.processIdentifier) selectedWindow=\(selectedTarget.id) currentPID=\(target.processIdentifier) currentWindow=\(target.id) frontmostPID=\(frontmostAtDispatch ?? -1) recordedFrame=\(String(describing: recordedFrame)) currentFrame=\(target.bounds) recordedScreen=\(recordedScreen) recordedRelative=(\(action.x ?? .nan),\(action.y ?? .nan)) scaledLocal=\(String(describing: scaledLocal)) finalScreen=\(point) screenDelta=\(screenDelta) clampDelta=\(String(describing: clampDelta)) recordedDelaySec=\(action.delay) expectedNs=\(expected) actualPrePostNs=\(prePost) expectedElapsedMs=\(deadline.map { Double($0 - playbackStart) / 1_000_000 } ?? .nan) lateMs=\(lateMs ?? .nan)")
    }

    private func keyCode(for action: MacroAction) throws -> CGKeyCode {
        guard let key = action.key, let code = KeyCodeMapper.code(for: key) else {
            throw InputBackendError.invalidKey(action.key ?? "empty")
        }
        return code
    }

    private func resolvedPoint(_ action: MacroAction, target: TargetWindow) -> CGPoint {
        let point = CGPoint(x: action.x ?? 0, y: action.y ?? 0)
        if action.usesWindowCoordinates {
            let scaledPoint: CGPoint
            if let recordedWindowSize,
               recordedWindowSize.width > 0,
               recordedWindowSize.height > 0 {
                scaledPoint = CGPoint(
                    x: point.x * target.bounds.width / recordedWindowSize.width,
                    y: point.y * target.bounds.height / recordedWindowSize.height
                )
            } else {
                scaledPoint = point
            }
            let localX = min(max(0, scaledPoint.x), max(0, target.bounds.width.nextDown))
            let localY = min(max(0, scaledPoint.y), max(0, target.bounds.height.nextDown))
            return CGPoint(x: target.bounds.minX + localX, y: target.bounds.minY + localY)
        }
        return point
    }

    private func sleepPausably(seconds: Double) async throws -> UInt64 {
        let requested = deadline(DispatchTime.now().uptimeNanoseconds, adding: seconds)
        return try await waitUntilPausably(requested)
    }

    /// Schedules against a monotonic absolute deadline so Task.sleep's wake-up
    /// jitter does not get added to every action and accumulate over a macro.
    private func waitUntilPausably(_ requestedDeadline: UInt64) async throws -> UInt64 {
        var deadline = requestedDeadline
        var observedPauseDuration = accountedPauseDuration
        while true {
            try Task.checkCancellation()
            if state == .paused {
                try await waitWhilePaused()
            }
            let newPauseDuration = completedPauseDuration
            deadline = addingSaturating(deadline, newPauseDuration - observedPauseDuration)
            observedPauseDuration = newPauseDuration
            accountedPauseDuration = newPauseDuration

            let now = DispatchTime.now().uptimeNanoseconds
            guard deadline > now else { return deadline }
            // Use a short scheduling slice without starving the event queue.
            try await Task.sleep(nanoseconds: min(deadline - now, 5_000_000))
        }
    }

    private func deadline(_ startingAt: UInt64, adding seconds: Double) -> UInt64 {
        guard seconds.isFinite, seconds > 0 else { return startingAt }
        let remaining = UInt64.max - startingAt
        let requested = seconds * 1_000_000_000
        guard requested.isFinite, requested < Double(remaining) else { return UInt64.max }
        return startingAt + UInt64(requested)
    }

    private func addingSaturating(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : sum
    }

    private func waitWhilePaused() async throws {
        while state == .paused {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func releaseHeldInputs() {
        guard let backend, let target else {
            heldKeys.removeAll()
            heldButtons.removeAll()
            heldKeyDownAt.removeAll()
            heldButtonDownAt.removeAll()
            return
        }

        for key in heldKeys { try? backend.keyUp(key, target: target) }
        for button in heldButtons { try? backend.mouseUp(button, at: lastMousePoint, clickCount: 1, target: target) }
        if !heldKeys.isEmpty || !heldButtons.isEmpty { log("Released all held automation inputs") }
        heldKeys.removeAll()
        heldButtons.removeAll()
        heldKeyDownAt.removeAll()
        heldButtonDownAt.removeAll()
        backend.resetInputState()
    }

    private func setState(_ newState: RunState) {
        state = newState
        onStateChange?(newState)
    }

    private func log(_ message: String, level: LogEntry.Level = .info) {
        onLog?(message, level)
    }
}
