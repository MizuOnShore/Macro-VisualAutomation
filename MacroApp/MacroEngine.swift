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
    var onStateChange: ((RunState) -> Void)?
    var onLog: ((String, LogEntry.Level) -> Void)?
    var onProgress: ((PlaybackProgress?) -> Void)?
    var onFinish: ((MacroRunOutcome) -> Void)?

    private var task: Task<Void, Never>?
    private var backend: (any InputBackend)?
    private var target: TargetWindow?
    private var heldKeys = Set<CGKeyCode>()
    private var heldButtons = Set<MacroMouseButton>()
    private var lastMousePoint = CGPoint.zero
    private var recordedWindowSize: CGSize?
    private(set) var state: RunState = .idle
    private let isAuthorized: () -> Bool
    private let targetIsRunning: (pid_t) -> Bool

    init(
        isAuthorized: @escaping () -> Bool = { AXIsProcessTrusted() },
        targetIsRunning: @escaping (pid_t) -> Bool = { kill($0, 0) == 0 }
    ) {
        self.isAuthorized = isAuthorized
        self.targetIsRunning = targetIsRunning
    }

    func start(macro: MacroDefinition, target: TargetWindow, backend: any InputBackend) {
        guard state == .idle else { return }
        self.backend = backend
        self.target = target
        recordedWindowSize = macro.recordedWindowSize
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
            self.releaseHeldInputs()
            self.onProgress?(nil)
            self.task = nil
            self.setState(.idle)
            self.onFinish?(outcome)
        }
    }

    func togglePause() {
        guard state == .running || state == .paused else { return }
        setState(state == .paused ? .running : .paused)
        log(state == .paused ? "Macro paused" : "Macro resumed")
    }

    func stop() {
        guard state != .idle else { return }
        task?.cancel()
        releaseHeldInputs()
        onProgress?(nil)
        setState(.idle)
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

            var eventDeadline = DispatchTime.now().uptimeNanoseconds
            for action in enabledActions {
                try Task.checkCancellation()
                eventDeadline = deadline(eventDeadline, adding: action.delay)
                guard isAuthorized() else { throw InputBackendError.accessibilityRequired }
                guard targetIsRunning(target.processIdentifier) else { throw InputBackendError.targetUnavailable }

                eventDeadline = try await waitUntilPausably(eventDeadline)
                let progressCurrent = iterationLimit == nil
                    ? (completedActions % max(1, enabledActions.count)) + 1
                    : completedActions + 1
                onProgress?(PlaybackProgress(current: progressCurrent, total: progressTotal))
                try await execute(action, target: target, backend: backend)
                // Actions such as a configured Key Press or mouse click have an
                // intrinsic duration. The next recorded delay starts after them.
                switch action.type {
                case .keyPress, .holdKey, .wait, .leftClick, .rightClick, .middleClick:
                    eventDeadline = max(eventDeadline, DispatchTime.now().uptimeNanoseconds)
                case .keyDown, .keyUp, .mouseDown, .mouseUp, .move, .scroll:
                    break
                }
                completedActions += 1
            }
        }
    }

    private func execute(
        _ action: MacroAction,
        target: TargetWindow,
        backend: any InputBackend
    ) async throws {
        switch action.type {
        case .keyDown:
            let code = try keyCode(for: action)
            try backend.keyDown(code, target: target)
            heldKeys.insert(code)
            log("\(action.key?.uppercased() ?? "KEY") DOWN")

        case .keyUp:
            let code = try keyCode(for: action)
            try backend.keyUp(code, target: target)
            heldKeys.remove(code)
            log("\(action.key?.uppercased() ?? "KEY") UP")

        case .keyPress:
            let code = try keyCode(for: action)
            try backend.keyDown(code, target: target)
            heldKeys.insert(code)
            try await sleepPausably(seconds: max(0.01, action.duration))
            try backend.keyUp(code, target: target)
            heldKeys.remove(code)
            log("\(action.key?.uppercased() ?? "KEY") PRESS")

        case .holdKey:
            let code = try keyCode(for: action)
            try backend.keyDown(code, target: target)
            heldKeys.insert(code)
            log("\(action.key?.uppercased() ?? "KEY") HOLD")
            try await sleepPausably(seconds: action.duration)
            try backend.keyUp(code, target: target)
            heldKeys.remove(code)
            log("\(action.key?.uppercased() ?? "KEY") RELEASE")

        case .wait:
            log("WAIT \(String(format: "%.3f", action.duration))s")
            try await sleepPausably(seconds: action.duration)

        case .leftClick, .rightClick, .middleClick:
            let button: MacroMouseButton = switch action.type {
            case .leftClick: .left
            case .rightClick: .right
            default: .middle
            }
            let point = resolvedPoint(action, target: target)
            try backend.mouseDown(button, at: point, clickCount: action.clickCount, target: target)
            heldButtons.insert(button)
            lastMousePoint = point
            try await sleepPausably(seconds: max(0.01, action.duration))
            try backend.mouseUp(button, at: point, clickCount: action.clickCount, target: target)
            heldButtons.remove(button)
            log("\(button.title.uppercased()) CLICK at \(Int(point.x)), \(Int(point.y))")

        case .mouseDown:
            let point = resolvedPoint(action, target: target)
            try backend.mouseDown(action.mouseButton, at: point, clickCount: action.clickCount, target: target)
            heldButtons.insert(action.mouseButton)
            lastMousePoint = point
            log("\(action.mouseButton.title.uppercased()) MOUSE DOWN")

        case .mouseUp:
            let point = resolvedPoint(action, target: target)
            try backend.mouseUp(action.mouseButton, at: point, clickCount: action.clickCount, target: target)
            heldButtons.remove(action.mouseButton)
            lastMousePoint = point
            log("\(action.mouseButton.title.uppercased()) MOUSE UP")

        case .move:
            let point = resolvedPoint(action, target: target)
            if let button = heldButtons.first {
                try backend.mouseDrag(button, to: point, target: target)
            } else {
                try backend.mouseMove(to: point, target: target)
            }
            lastMousePoint = point
            log("MOVE to \(Int(point.x)), \(Int(point.y))")

        case .scroll:
            let point = resolvedPoint(action, target: target)
            try backend.scroll(
                deltaX: action.scrollDeltaX,
                deltaY: action.scrollDeltaY,
                at: point,
                target: target
            )
            lastMousePoint = point
            log("SCROLL \(Int(action.scrollDeltaX)), \(Int(action.scrollDeltaY))")
        }
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
            let localX = min(max(0, scaledPoint.x), max(0, target.bounds.width - 1))
            let localY = min(max(0, scaledPoint.y), max(0, target.bounds.height - 1))
            return CGPoint(x: target.bounds.minX + localX, y: target.bounds.minY + localY)
        }
        return point
    }

    private func sleepPausably(seconds: Double) async throws {
        guard seconds.isFinite, seconds > 0 else { return }
        _ = try await waitUntilPausably(deadline(DispatchTime.now().uptimeNanoseconds, adding: seconds))
    }

    /// Schedules against a monotonic absolute deadline so Task.sleep's wake-up
    /// jitter does not get added to every action and accumulate over a macro.
    private func waitUntilPausably(_ requestedDeadline: UInt64) async throws -> UInt64 {
        var deadline = requestedDeadline
        while true {
            try Task.checkCancellation()
            if state == .paused {
                let pauseStartedAt = DispatchTime.now().uptimeNanoseconds
                try await waitWhilePaused()
                let resumedAt = DispatchTime.now().uptimeNanoseconds
                let (extendedDeadline, overflow) = deadline.addingReportingOverflow(resumedAt - pauseStartedAt)
                deadline = overflow ? UInt64.max : extendedDeadline
                continue
            }

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
            return
        }

        for key in heldKeys { try? backend.keyUp(key, target: target) }
        for button in heldButtons { try? backend.mouseUp(button, at: lastMousePoint, clickCount: 1, target: target) }
        if !heldKeys.isEmpty || !heldButtons.isEmpty { log("Released all held automation inputs") }
        heldKeys.removeAll()
        heldButtons.removeAll()
    }

    private func setState(_ newState: RunState) {
        state = newState
        onStateChange?(newState)
    }

    private func log(_ message: String, level: LogEntry.Level = .info) {
        onLog?(message, level)
    }
}
