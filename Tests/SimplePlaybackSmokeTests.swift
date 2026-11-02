import CoreGraphics
import Foundation

@main
struct SimplePlaybackSmokeTests {
    static func main() throws {
        try testClicksAndConfiguredActions()
        try testMovementDraggingAndOverlap()
        try testKeyHandoffAndPause()
        try testLateEventCatchesUpWithoutTimelineGrowth()
        try testStopReleasesHeldInputs()
        try testTargetFailureReleasesInput()
        try testEmptyInfiniteRecordingCompletes()
        try testLongRecordingUsesOriginalTimeline()
        print("Simple playback smoke tests passed")
    }

    private static func testClicksAndConfiguredActions() throws {
        let macro = MacroDefinition(name: "Clicks", actions: [
            MacroAction(type: .mouseDown, key: nil, duration: 0, x: 10, y: 10),
            MacroAction(type: .mouseUp, key: nil, duration: 0, delay: 0.05, x: 10, y: 10),
            MacroAction(type: .leftClick, key: nil, duration: 0.06, delay: 0.03, x: 20, y: 20)
        ])
        let plan = try SimplePlaybackPlan(macro: macro)
        try expect(plan.events.count == 4, "Configured click was not expanded into two events")
        let poster = FakeSimplePoster()
        let result = try run(plan, poster: poster)
        try expect(result == .completed, "Click playback did not finish")
        try expect(poster.names == ["mouseDown", "mouseUp", "mouseDown", "mouseUp"], "Click order changed")
        try expect(poster.times[1] - poster.times[0] >= 45_000_000, "Recorded click was too short")
    }

    private static func testMovementDraggingAndOverlap() throws {
        let macro = MacroDefinition(name: "Combined Inputs", actions: [
            MacroAction(type: .keyDown, key: "w", duration: 0),
            MacroAction(type: .mouseDown, key: nil, duration: 0, x: 10, y: 10),
            MacroAction(type: .move, key: nil, duration: 0, delay: 0.02, x: 20, y: 20),
            MacroAction(type: .scroll, key: nil, duration: 0, delay: 0.02, x: 20, y: 20, scrollDeltaY: -3),
            MacroAction(type: .mouseUp, key: nil, duration: 0, delay: 0.02, x: 20, y: 20),
            MacroAction(type: .move, key: nil, duration: 0, delay: 0.02, x: 30, y: 30),
            MacroAction(type: .keyUp, key: "w", duration: 0, delay: 0.02)
        ])
        let poster = FakeSimplePoster()
        let result = try run(SimplePlaybackPlan(macro: macro), poster: poster)
        try expect(result == .completed, "Combined playback did not finish")
        try expect(poster.names == ["down:13", "mouseDown", "drag", "scroll", "mouseUp", "move", "up:13"],
                   "Keyboard, mouse, drag, or scroll order changed")
    }

    private static func testKeyHandoffAndPause() throws {
        let macro = MacroDefinition(name: "Handoff", actions: [
            MacroAction(type: .keyDown, key: "w", duration: 0),
            MacroAction(type: .keyUp, key: "w", duration: 0, delay: 0.12),
            MacroAction(type: .keyDown, key: "d", duration: 0),
            MacroAction(type: .keyUp, key: "d", duration: 0, delay: 0.05)
        ])
        let plan = try SimplePlaybackPlan(macro: macro)
        try expect(plan.events[1].elapsedNs == plan.events[2].elapsedNs,
                   "Immediate W-to-D handoff acquired a delay")
        let poster = FakeSimplePoster()
        let done = DispatchSemaphore(value: 0)
        var outcome: MacroRunOutcome?
        let worker = SimplePlaybackWorker(plan: plan, poster: poster, validateTarget: { .testFrame },
            onProgress: { _, _ in }, onComplete: { value in outcome = value; done.signal() })
        worker.start()
        try waitForEventCount(poster, 1)
        worker.setPaused(true)
        Thread.sleep(forTimeInterval: 0.08)
        try expect(poster.names.count == 1, "Input was posted while paused")
        worker.setPaused(false)
        try expect(done.wait(timeout: .now() + 3) == .success, "Paused worker did not finish")
        try expect(outcome == .completed, "Resume did not complete playback")
        try expect(poster.names == ["down:13", "up:13", "down:2", "up:2"], "Key handoff order changed")
        try expect(poster.times[1] - poster.times[0] >= 175_000_000,
                   "Pause time was not excluded from the W hold")
    }

    private static func testStopReleasesHeldInputs() throws {
        let macro = MacroDefinition(name: "Stop", actions: [
            MacroAction(type: .keyDown, key: "w", duration: 0),
            MacroAction(type: .mouseDown, key: nil, duration: 0, x: 10, y: 10),
            MacroAction(type: .keyUp, key: "w", duration: 0, delay: 5)
        ])
        let poster = FakeSimplePoster()
        let done = DispatchSemaphore(value: 0)
        var outcome: MacroRunOutcome?
        let worker = SimplePlaybackWorker(plan: try SimplePlaybackPlan(macro: macro), poster: poster,
            validateTarget: { .testFrame }, onProgress: { _, _ in },
            onComplete: { value in outcome = value; done.signal() })
        worker.start()
        try waitForEventCount(poster, 2)
        worker.stop()
        try expect(done.wait(timeout: .now() + 2) == .success, "Stop did not wake the worker")
        try expect(outcome == .stopped, "Stopped worker reported the wrong outcome")
        try expect(poster.names == ["down:13", "mouseDown", "up:13", "mouseUp"],
                   "Stop did not release all held inputs")
    }

    private static func testLateEventCatchesUpWithoutTimelineGrowth() throws {
        let macro = MacroDefinition(name: "Late event", actions: [
            MacroAction(type: .keyDown, key: "w", duration: 0),
            MacroAction(type: .keyUp, key: "w", duration: 0, delay: 0.02),
            MacroAction(type: .keyDown, key: "d", duration: 0, delay: 0.10)
        ])
        let plan = try SimplePlaybackPlan(macro: macro)
        let poster = FakeSimplePoster()
        poster.firstPostDelay = 0.08
        let started = DispatchTime.now().uptimeNanoseconds
        let result = try run(plan, poster: poster)
        try expect(result == .completed, "Late event playback did not finish")
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        try expect(poster.names == ["down:13", "up:13", "down:2", "up:2"], "Late event order changed")
        try expect(poster.times[1] - poster.times[0] >= 75_000_000,
                   "Synthetic dispatch delay was not applied")
        try expect(poster.times[2] - poster.times[1] < 65_000_000,
                   "Late first post shifted the later recorded deadline")
        try expect(elapsed < plan.durationNs + 90_000_000,
                   "Lateness was carried forward into the total playback duration")
    }

    private static func testTargetFailureReleasesInput() throws {
        let macro = MacroDefinition(name: "Missing Target", actions: [
            MacroAction(type: .keyDown, key: "w", duration: 0),
            MacroAction(type: .keyUp, key: "w", duration: 0, delay: 0.35)
        ])
        let poster = FakeSimplePoster()
        let done = DispatchSemaphore(value: 0)
        var outcome: MacroRunOutcome?
        var validations = 0
        let worker = SimplePlaybackWorker(plan: try SimplePlaybackPlan(macro: macro), poster: poster,
            validateTarget: {
                validations += 1
                if validations > 1 { throw InputBackendError.targetWindowUnavailable }
                return .testFrame
            }, onProgress: { _, _ in }, onComplete: { value in outcome = value; done.signal() })
        worker.start()
        try expect(done.wait(timeout: .now() + 2) == .success, "Target failure did not stop playback")
        if case .failed = outcome {} else { throw TestFailure("Target failure reported the wrong outcome") }
        try expect(poster.names == ["down:13", "up:13"], "Target failure left W held")
    }

    private static func testLongRecordingUsesOriginalTimeline() throws {
        var actions: [MacroAction] = [MacroAction(type: .keyDown, key: "w", duration: 0)]
        for i in 0..<190 {
            actions.append(MacroAction(type: .move, key: nil, duration: 0, delay: 0.002,
                                       x: Double(i), y: 10))
        }
        actions.append(MacroAction(type: .keyUp, key: "w", duration: 0, delay: 0.01))
        actions.append(MacroAction(type: .keyDown, key: "d", duration: 0))
        actions.append(MacroAction(type: .keyUp, key: "d", duration: 0, delay: 0.02))
        let plan = try SimplePlaybackPlan(macro: MacroDefinition(name: "190 Moves", actions: actions))
        let poster = FakeSimplePoster()
        poster.firstPostDelay = 0.05
        let started = DispatchTime.now().uptimeNanoseconds
        let result = try run(plan, poster: poster)
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        try expect(result == .completed, "Long recording did not finish")
        try expect(poster.names.count == 194, "Long recording lost an action")
        try expect(poster.names.first == "down:13" && poster.names.suffix(3) == ["up:13", "down:2", "up:2"],
                   "Long recording changed event order")
        try expect(elapsed >= plan.durationNs, "Playback finished before recorded duration")
        try expect(elapsed < plan.durationNs + 800_000_000,
                   "Long recording was excessively extended by a late first event")
        print("194-action recording: recorded=\(Double(plan.durationNs) / 1_000_000) ms, playback=\(Double(elapsed) / 1_000_000) ms")
    }

    private static func testEmptyInfiniteRecordingCompletes() throws {
        let plan = try SimplePlaybackPlan(macro: MacroDefinition(name: "Empty loop", actions: [], loopMode: .infinite))
        let poster = FakeSimplePoster()
        let result = try run(plan, poster: poster)
        try expect(result == .completed, "Empty infinite recording did not finish")
        try expect(poster.names.isEmpty, "Empty recording posted input")
    }

    private static func run(_ plan: SimplePlaybackPlan, poster: FakeSimplePoster) throws -> MacroRunOutcome {
        let done = DispatchSemaphore(value: 0)
        var outcome: MacroRunOutcome?
        let worker = SimplePlaybackWorker(plan: plan, poster: poster, validateTarget: { .testFrame },
            onProgress: { _, _ in }, onComplete: { value in outcome = value; done.signal() })
        worker.start()
        guard done.wait(timeout: .now() + 3) == .success, let outcome else {
            throw TestFailure("Simple worker did not finish")
        }
        return outcome
    }

    private static func waitForEventCount(_ poster: FakeSimplePoster, _ count: Int) throws {
        let until = Date().addingTimeInterval(1)
        while poster.names.count < count {
            if Date() > until { throw TestFailure("Worker did not dispatch expected inputs") }
            Thread.sleep(forTimeInterval: 0.001)
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw TestFailure(message) }
    }
}

private final class FakeSimplePoster: SimpleEventPosting {
    private let lock = NSLock()
    private var events: [(String, UInt64)] = []
    private var heldKeys = Set<CGKeyCode>()
    private var heldButtons = Set<MacroMouseButton>()
    var firstPostDelay: TimeInterval = 0

    var names: [String] { lock.lock(); defer { lock.unlock() }; return events.map(\.0) }
    var times: [UInt64] { lock.lock(); defer { lock.unlock() }; return events.map(\.1) }

    func post(_ event: SimplePlaybackEvent, in frame: CGRect, recordedWindowSize: CGSize?) throws {
        lock.lock()
        let name: String
        switch event.kind {
        case .keyDown(let key, _): name = "down:\(key)"; heldKeys.insert(key)
        case .keyUp(let key): name = "up:\(key)"; heldKeys.remove(key)
        case .mouseDown(let button): name = "mouseDown"; heldButtons.insert(button)
        case .mouseUp(let button): name = "mouseUp"; heldButtons.remove(button)
        case .move: name = heldButtons.isEmpty ? "move" : "drag"
        case .scroll: name = "scroll"
        }
        events.append((name, DispatchTime.now().uptimeNanoseconds))
        let delay = firstPostDelay
        firstPostDelay = 0
        lock.unlock()
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
    }

    func releaseHeldInputs() {
        lock.lock()
        for key in heldKeys { events.append(("up:\(key)", DispatchTime.now().uptimeNanoseconds)) }
        for _ in heldButtons { events.append(("mouseUp", DispatchTime.now().uptimeNanoseconds)) }
        heldKeys.removeAll()
        heldButtons.removeAll()
        lock.unlock()
    }
}

private extension CGRect {
    static let testFrame = CGRect(x: 0, y: 0, width: 800, height: 600)
}

private struct TestFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
