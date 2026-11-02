import CoreGraphics
import Foundation

@main
@MainActor
struct MacroEngineSmokeTests {
    static func main() async throws {
        try await testCountedExecution()
        try await testRecordedClickExecution()
        try await testDragAndScrollExecution()
        try await testWindowCoordinateScaling()
        try await testInBoundsEdgePointIsUnchanged()
        try await testMovedWindowCoordinates()
        try await testWindowDisappears()
        try await testKeyOnlyWindowDisappears()
        try await testFocusedPlaybackStopsOnFocusChange()
        try await testStopReleasesHeldMouseButton()
        try await testCompatibilityIgnoresRecordedScreenPosition()
        try testLegacyExactScreenSettingsBecomeCompatibility()
        try testRecordedScreenCoordinatesSurviveStorage()
        try testScrollUnitSurvivesStorage()
        try await testKeyRepeatOrder()
        try await testStopReleasesHeldKey()
        try await testDelayedMouseDownPreservesPressDuration()
        try await testDragKeepsActionOrderAndIntervals()
        try await testConsecutiveClicksKeepTheirGap()
        try await testLateKeyboardEventsKeepTheirIntervals()
        try await testLateMoveDoesNotCompressFollowingClick()
        try await testStopDuringProgressDoesNotPostInput()
        try await testImmediateKeyHandoff()
        try await testIntentionalKeyHandoffGapAfterSlowRelease()
        try await testSimultaneousKeyboardAndMouse()
        try await testOverlappingKeys()
        try await testLateKeyUpKeepsFollowingGap()
        try await testConsecutiveClicksAfterSlowRelease()
        try await testMultipleLateDispatches()
        try await testPauseResumeKeepsRemainingInterval()
        try await testPauseDuringProgressBlocksDispatch()
        try await testCompletedPauseBetweenWaitAndDispatch()
        try await testEmergencyStopReleasesOverlappingInputs()
        print("Macro engine smoke tests passed")
    }

    private static func testRecordedClickExecution() async throws {
        let backend = FakeBackend()
        let engine = makeEngine()
        let macro = MacroDefinition(
            name: "Click",
            actions: [
                MacroAction(type: .leftClick, key: nil, duration: 0.01, x: 120, y: 80)
            ]
        )

        engine.start(macro: macro, target: .testTarget, backend: backend)
        try await waitUntilIdle(engine)
        try expect(backend.events == ["mouseDown", "mouseUp"], "Recorded click did not replay as a complete click")
    }

    private static func testDragAndScrollExecution() async throws {
        let backend = FakeBackend()
        let engine = makeEngine()
        let macro = MacroDefinition(
            name: "Drag and Scroll",
            actions: [
                MacroAction(type: .mouseDown, key: nil, duration: 0, x: 10, y: 10),
                MacroAction(type: .move, key: nil, duration: 0, x: 80, y: 60),
                MacroAction(type: .mouseUp, key: nil, duration: 0, x: 80, y: 60),
                MacroAction(type: .scroll, key: nil, duration: 0, x: 80, y: 60, scrollDeltaY: -3, scrollUnit: .line)
            ]
        )

        engine.start(macro: macro, target: .testTarget, backend: backend)
        try await waitUntilIdle(engine)
        try expect(
            backend.events == ["mouseDown", "drag", "mouseUp", "scroll"],
            "Recorded drag or scroll sequence was incorrect"
        )
        try expect(backend.scrollUnits == [.line], "Wheel units were not passed to the playback backend")
    }

    private static func testCountedExecution() async throws {
        let backend = FakeBackend()
        let engine = makeEngine()
        var progress: [PlaybackProgress] = []
        engine.onProgress = { value in
            if let value { progress.append(value) }
        }
        let macro = MacroDefinition(
            name: "Counted",
            actions: [MacroAction(type: .keyPress, key: "e", duration: 0.01)],
            loopMode: .count,
            loopCount: 2
        )

        engine.start(macro: macro, target: .testTarget, backend: backend)
        try await waitUntilIdle(engine)
        try expect(backend.events == ["down:14", "up:14", "down:14", "up:14"], "Counted execution sequence was incorrect")
        try expect(progress == [
            PlaybackProgress(current: 1, total: 2),
            PlaybackProgress(current: 2, total: 2)
        ], "Playback progress was incorrect")
    }

    private static func testWindowCoordinateScaling() async throws {
        let backend = FakeBackend()
        let engine = makeEngine()
        let macro = MacroDefinition(
            name: "Scaled Pointer",
            actions: [MacroAction(type: .move, key: nil, duration: 0, x: 100, y: 75, recordedScreenX: 888, recordedScreenY: 444)],
            recordedWindowWidth: 400,
            recordedWindowHeight: 300
        )

        engine.start(macro: macro, target: .testTarget, backend: backend)
        try await waitUntilIdle(engine)
        try expect(
            backend.points == [CGPoint(x: 200, y: 150)],
            "Window-relative pointer coordinates were not scaled"
        )
    }

    private static func testInBoundsEdgePointIsUnchanged() async throws {
        let backend = FakeBackend()
        let engine = makeEngine()
        let point = CGPoint(x: 799.75, y: 599.5)
        let macro = MacroDefinition(name: "Edge Pointer", actions: [
            MacroAction(type: .move, key: nil, duration: 0, x: point.x, y: point.y)
        ], recordedWindowWidth: 800, recordedWindowHeight: 600)
        engine.start(macro: macro, target: .testTarget, backend: backend)
        try await waitUntilIdle(engine)
        try expect(backend.points == [point], "Valid in-window coordinates changed during clamping")
    }

    private static func testMovedWindowCoordinates() async throws {
        let backend = FakeBackend()
        var refreshCount = 0
        let engine = makeEngine(targetWindowResolver: { target in
            refreshCount += 1
            return TargetWindow(
                id: target.id, applicationName: target.applicationName, windowTitle: target.windowTitle,
                processIdentifier: target.processIdentifier, bundleIdentifier: target.bundleIdentifier,
                bounds: refreshCount == 1
                    ? target.bounds
                    : CGRect(x: 300, y: 200, width: 400, height: 300)
            )
        })
        let macro = MacroDefinition(
            name: "Moving Window",
            actions: [
                MacroAction(type: .move, key: nil, duration: 0, x: 100, y: 75),
                MacroAction(type: .mouseDown, key: nil, duration: 0, delay: 0.04, x: 100, y: 75)
            ],
            recordedWindowWidth: 400, recordedWindowHeight: 300
        )
        engine.start(macro: macro, target: .testTarget, backend: backend)
        try await waitUntilIdle(engine)
        try expect(backend.points == [CGPoint(x: 200, y: 150), CGPoint(x: 400, y: 275)],
                   "Playback did not follow the moved and resized target window")
    }

    private static func testWindowDisappears() async throws {
        let backend = FakeBackend()
        let engine = makeEngine(targetWindowResolver: { _ in nil })
        var outcome: MacroRunOutcome?
        engine.onFinish = { outcome = $0 }
        engine.start(macro: MacroDefinition(name: "Missing Window", actions: [
            MacroAction(type: .move, key: nil, duration: 0, x: 20, y: 20)
        ]), target: .testTarget, backend: backend)
        try await waitUntilIdle(engine)
        try expect(outcome == .failed(InputBackendError.targetWindowUnavailable.localizedDescription),
                   "Playback did not stop when its exact target window disappeared")
        try expect(backend.events.isEmpty, "Playback sent input after the target window disappeared")
    }

    private static func testKeyOnlyWindowDisappears() async throws {
        let backend = FakeBackend()
        let engine = makeEngine(targetWindowResolver: { _ in nil })
        var outcome: MacroRunOutcome?
        engine.onFinish = { outcome = $0 }
        engine.start(macro: MacroDefinition(name: "Missing Key Window", actions: [
            MacroAction(type: .keyDown, key: "w", duration: 0)
        ]), target: .testTarget, backend: backend)
        try await waitUntilIdle(engine)
        try expect(outcome == .failed(InputBackendError.targetWindowUnavailable.localizedDescription),
                   "Key-only playback continued after the selected window disappeared")
        try expect(backend.events.isEmpty, "Key was sent to a process with no selected window")
    }

    private static func testFocusedPlaybackStopsOnFocusChange() async throws {
        let backend = FakeBackend(mousePlaybackMode: .compatibility)
        var checks = 0
        let engine = makeEngine(frontmostPID: {
            checks += 1
            return checks == 1 ? TargetWindow.testTarget.processIdentifier : nil
        })
        var outcome: MacroRunOutcome?
        engine.onFinish = { outcome = $0 }
        engine.start(macro: MacroDefinition(name: "Focus Change", actions: [
            MacroAction(type: .keyDown, key: "w", duration: 0),
            MacroAction(type: .keyUp, key: "w", duration: 0, delay: 0.02)
        ]), target: .testTarget, backend: backend)
        try await waitUntilIdle(engine)
        try expect(outcome == .failed(InputBackendError.targetFocusChanged.localizedDescription),
                   "Focused playback did not stop after losing application focus")
        try expect(backend.events == ["down:13", "up:13"], "Held key was not released on focus failure")
    }

    private static func testStopReleasesHeldMouseButton() async throws {
        let backend = FakeBackend()
        let engine = makeEngine()
        engine.start(macro: MacroDefinition(name: "Drag Stop", actions: [
            MacroAction(type: .mouseDown, key: nil, duration: 0, x: 10, y: 10),
            MacroAction(type: .mouseUp, key: nil, duration: 0, delay: 5, x: 20, y: 20)
        ]), target: .testTarget, backend: backend)
        try await Task.sleep(nanoseconds: 50_000_000)
        engine.stop()
        try await waitUntilIdle(engine)
        try expect(backend.events == ["mouseDown", "mouseUp"], "Stop left the mouse button held")
    }

    private static func testCompatibilityIgnoresRecordedScreenPosition() async throws {
        let backend = FakeBackend(mousePlaybackMode: .compatibility)
        let engine = makeEngine()
        let macro = MacroDefinition(
            name: "Compatibility Pointer",
            actions: [MacroAction(type: .move, key: nil, duration: 0, x: 100, y: 75, recordedScreenX: 888, recordedScreenY: 444)],
            mousePlaybackMode: .compatibility,
            recordedWindowWidth: 400,
            recordedWindowHeight: 300
        )

        engine.start(macro: macro, target: .testTarget, backend: backend)
        try await waitUntilIdle(engine)
        try expect(backend.points == [CGPoint(x: 200, y: 150)],
                   "Compatibility playback used the old absolute screen position")
    }

    private static func testLegacyExactScreenSettingsBecomeCompatibility() throws {
        let legacyMacro = Data(#"{"name":"Legacy","mousePlaybackMode":"exactScreen","actions":[{"type":"move","x":100,"y":75,"recordedScreenX":888,"recordedScreenY":444}]}"#.utf8)
        let macro = try JSONDecoder().decode(MacroDefinition.self, from: legacyMacro)
        try expect(macro.mousePlaybackMode == .compatibility, "Legacy Exact Screen macro did not switch to Compatibility")
        let savedMacro = String(decoding: try JSONEncoder().encode(macro), as: UTF8.self)
        try expect(savedMacro.contains(#""mousePlaybackMode":"compatibility""#),
                   "Legacy macro saved the removed playback mode")

        let legacyOverride = Data(#""exactScreen""#.utf8)
        let override = try JSONDecoder().decode(MacroPlaybackOverride.self, from: legacyOverride)
        try expect(override == .compatibility, "Legacy Exact Screen automation override did not switch to Compatibility")
        let savedOverride = String(decoding: try JSONEncoder().encode(override), as: UTF8.self)
        try expect(savedOverride == #""compatibility""#, "Legacy automation override saved the removed mode")
    }

    private static func testRecordedScreenCoordinatesSurviveStorage() throws {
        let macro = MacroDefinition(
            name: "Recorded Pointer",
            actions: [MacroAction(
                type: .mouseDown, key: nil, duration: 0,
                x: 100, y: 75, recordedScreenX: 888, recordedScreenY: 444
            )]
        )
        let restored = try JSONDecoder().decode(MacroDefinition.self, from: JSONEncoder().encode(macro))
        try expect(restored.actions[0].recordedScreenX == 888 && restored.actions[0].recordedScreenY == 444,
                   "Saved recordings lost their exact screen coordinates")
    }

    private static func testScrollUnitSurvivesStorage() throws {
        let macro = MacroDefinition(name: "Wheel", actions: [
            MacroAction(type: .scroll, key: nil, duration: 0, scrollDeltaY: 3, scrollUnit: .line)
        ])
        let restored = try JSONDecoder().decode(MacroDefinition.self, from: JSONEncoder().encode(macro))
        try expect(restored.actions[0].scrollUnit == .line, "Wheel units were lost while saving")
        let legacyJSON = Data(#"{"name":"Old Wheel","actions":[{"type":"scroll","scrollDeltaY":30}]}"#.utf8)
        let legacyRestored = try JSONDecoder().decode(MacroDefinition.self, from: legacyJSON)
        try expect(legacyRestored.actions[0].scrollUnit == .pixel, "Older recordings should retain pixel playback")
    }

    private static func testKeyRepeatOrder() async throws {
        let backend = FakeBackend()
        let engine = makeEngine()
        let macro = MacroDefinition(
            name: "Repeated Key",
            actions: [
                MacroAction(type: .keyDown, key: "w", duration: 0),
                MacroAction(type: .keyDown, key: "w", duration: 0, delay: 0.01, isKeyRepeat: true),
                MacroAction(type: .keyUp, key: "w", duration: 0, delay: 0.01)
            ]
        )

        engine.start(macro: macro, target: .testTarget, backend: backend)
        try await waitUntilIdle(engine)
        try expect(backend.events == ["down:13", "repeat:13", "up:13"], "Key repeat order changed during playback")
    }

    private static func testStopReleasesHeldKey() async throws {
        let backend = FakeBackend()
        let engine = makeEngine()
        let macro = MacroDefinition(
            name: "Release",
            actions: [
                MacroAction(type: .keyDown, key: "w", duration: 0),
                MacroAction(type: .wait, key: nil, duration: 5)
            ]
        )

        engine.start(macro: macro, target: .testTarget, backend: backend)
        try await Task.sleep(nanoseconds: 50_000_000)
        engine.stop()
        try await Task.sleep(nanoseconds: 50_000_000)
        try expect(backend.events.contains("down:13"), "W was not pressed")
        try expect(backend.events.contains("up:13"), "Stop did not release W")
    }

    private static func testDelayedMouseDownPreservesPressDuration() async throws {
        let backend = FakeBackend()
        backend.firstMouseDownDelay = 0.08
        let engine = makeEngine()
        engine.start(macro: MacroDefinition(name: "Delayed Mouse Down", actions: [
            MacroAction(type: .mouseDown, key: nil, duration: 0, x: 10, y: 10),
            MacroAction(type: .mouseUp, key: nil, duration: 0, delay: 0.10, x: 10, y: 10)
        ]), target: .testTarget, backend: backend)
        try await waitUntilIdle(engine)
        try expect(backend.events == ["mouseDown", "mouseUp"], "A delayed mouse press changed action order")
        try expect(backend.eventTimes[1] >= backend.firstMouseDownReturn + 99_000_000,
                   "A late mouse-down shortened the recorded 100 ms press")
    }

    private static func testDragKeepsActionOrderAndIntervals() async throws {
        let backend = FakeBackend()
        backend.firstMouseDownDelay = 0.07
        let engine = makeEngine()
        engine.start(macro: MacroDefinition(name: "Delayed Drag", actions: [
            MacroAction(type: .mouseDown, key: nil, duration: 0, x: 10, y: 10),
            MacroAction(type: .move, key: nil, duration: 0, delay: 0.03, x: 20, y: 20),
            MacroAction(type: .mouseUp, key: nil, duration: 0, delay: 0.04, x: 20, y: 20)
        ]), target: .testTarget, backend: backend)
        try await waitUntilIdle(engine)
        try expect(backend.events == ["mouseDown", "drag", "mouseUp"], "Drag action order changed")
        try expect(backend.eventTimes[1] >= backend.firstMouseDownReturn + 29_000_000,
                   "The first drag movement caught up after a late mouse-down")
        try expect(backend.eventTimes[2] >= backend.eventTimes[1] + 39_000_000,
                   "Mouse-up caught up to a delayed drag movement")
    }

    private static func testConsecutiveClicksKeepTheirGap() async throws {
        let backend = FakeBackend()
        backend.firstMouseDownDelay = 0.08
        let engine = makeEngine()
        engine.start(macro: MacroDefinition(name: "Consecutive Clicks", actions: [
            MacroAction(type: .mouseDown, key: nil, duration: 0, x: 10, y: 10),
            MacroAction(type: .mouseUp, key: nil, duration: 0, delay: 0.06, x: 10, y: 10),
            MacroAction(type: .mouseDown, key: nil, duration: 0, delay: 0.05, x: 10, y: 10),
            MacroAction(type: .mouseUp, key: nil, duration: 0, delay: 0.06, x: 10, y: 10)
        ]), target: .testTarget, backend: backend)
        try await waitUntilIdle(engine)
        try expect(backend.events == ["mouseDown", "mouseUp", "mouseDown", "mouseUp"],
                   "Consecutive click order changed")
        try expect(backend.eventTimes[1] >= backend.firstMouseDownReturn + 59_000_000,
                   "The first click was shortened")
        try expect(backend.eventTimes[2] >= backend.eventTimes[1] + 49_000_000,
                   "The gap between consecutive clicks was compressed")
        try expect(backend.eventTimes[3] >= backend.eventTimes[2] + 59_000_000,
                   "The second click was shortened")
    }

    private static func testLateKeyboardEventsKeepTheirIntervals() async throws {
        let backend = FakeBackend()
        backend.firstKeyDownDelay = 0.08
        let engine = makeEngine()
        engine.start(macro: MacroDefinition(name: "Late Key", actions: [
            MacroAction(type: .keyDown, key: "w", duration: 0),
            MacroAction(type: .keyDown, key: "w", duration: 0, delay: 0.03, isKeyRepeat: true),
            MacroAction(type: .keyUp, key: "w", duration: 0, delay: 0.07)
        ]), target: .testTarget, backend: backend)
        try await waitUntilIdle(engine)
        try expect(backend.events == ["down:13", "repeat:13", "up:13"], "Late keyboard event order changed")
        try expect(backend.eventTimes[1] >= backend.firstKeyDownReturn + 29_000_000,
                   "A key repeat caught up after a late key-down")
        try expect(backend.eventTimes[2] >= backend.eventTimes[1] + 69_000_000,
                   "A key-up shortened the recorded key hold")
    }

    private static func testLateMoveDoesNotCompressFollowingClick() async throws {
        let backend = FakeBackend()
        let engine = makeEngine()
        engine.onProgress = { progress in
            if progress?.current == 1 { Thread.sleep(forTimeInterval: 0.08) }
        }
        engine.start(macro: MacroDefinition(name: "Late Move", actions: [
            MacroAction(type: .move, key: nil, duration: 0, x: 10, y: 10),
            MacroAction(type: .mouseDown, key: nil, duration: 0, delay: 0.06, x: 10, y: 10),
            MacroAction(type: .mouseUp, key: nil, duration: 0, delay: 0.04, x: 10, y: 10)
        ]), target: .testTarget, backend: backend)
        try await waitUntilIdle(engine)
        try expect(backend.events == ["move", "mouseDown", "mouseUp"], "Late move changed action order")
        try expect(backend.eventTimes[1] >= backend.eventTimes[0] + 59_000_000,
                   "A click caught up after a late mouse move")
    }

    private static func testStopDuringProgressDoesNotPostInput() async throws {
        let backend = FakeBackend()
        let engine = makeEngine()
        engine.onProgress = { progress in
            if progress?.current == 1 { engine.stop() }
        }
        engine.start(macro: MacroDefinition(name: "Stop Before Dispatch", actions: [
            MacroAction(type: .mouseDown, key: nil, duration: 0, x: 10, y: 10)
        ]), target: .testTarget, backend: backend)
        try await waitUntilIdle(engine)
        try expect(backend.events.isEmpty, "Cancellation during progress posted a new input event")
    }

    private static func testImmediateKeyHandoff() async throws {
        let backend = FakeBackend()
        backend.firstKeyDownDelay = 0.06
        let engine = makeEngine()
        let timing = TimingProbe(engine)
        engine.start(macro: MacroDefinition(name: "Immediate Key Handoff", actions: [
            MacroAction(type: .keyDown, key: "w", duration: 0),
            MacroAction(type: .keyUp, key: "w", duration: 0, delay: 0.08),
            MacroAction(type: .keyDown, key: "d", duration: 0, delay: 0),
            MacroAction(type: .keyUp, key: "d", duration: 0, delay: 0.06)
        ]), target: .testTarget, backend: backend)
        try await waitUntilIdle(engine)
        try expect(backend.events == ["down:13", "up:13", "down:2", "up:2"], "Key handoff order changed")
        try expect(backend.eventTimes[1] >= backend.firstKeyDownReturn + 79_000_000,
                   "A late W press shortened its hold")
        try expect(timing.call(2).deadline == timing.call(1).actual,
                   "An immediate W-to-D handoff acquired a scheduled gap")
        try expect(backend.eventTimes[3] >= backend.eventTimes[2] + 59_000_000,
                   "The D hold was shortened")
    }

    private static func testIntentionalKeyHandoffGapAfterSlowRelease() async throws {
        let backend = FakeBackend()
        backend.firstKeyUpDelay = 0.07
        let engine = makeEngine()
        let timing = TimingProbe(engine)
        engine.start(macro: MacroDefinition(name: "Key Handoff Gap", actions: [
            MacroAction(type: .keyDown, key: "w", duration: 0),
            MacroAction(type: .keyUp, key: "w", duration: 0, delay: 0.06),
            MacroAction(type: .keyDown, key: "d", duration: 0, delay: 0.10),
            MacroAction(type: .keyUp, key: "d", duration: 0, delay: 0.05)
        ]), target: .testTarget, backend: backend)
        try await waitUntilIdle(engine)
        try expect(backend.events == ["down:13", "up:13", "down:2", "up:2"], "Key handoff order changed")
        let scheduledGap = timing.call(2).deadline - timing.call(1).actual
        try expect(scheduledGap == 100_000_000,
                   "A slow key-up added an unintended scheduled gap: \(Double(scheduledGap) / 1_000_000) ms")
        try expect(backend.eventTimes[2] >= backend.firstKeyUpReturn,
                   "D was pressed before the W release call returned")
    }

    private static func testSimultaneousKeyboardAndMouse() async throws {
        let backend = FakeBackend()
        let engine = makeEngine()
        engine.start(macro: MacroDefinition(name: "Key And Mouse Overlap", actions: [
            MacroAction(type: .keyDown, key: "w", duration: 0),
            MacroAction(type: .mouseDown, key: nil, duration: 0, x: 10, y: 10),
            MacroAction(type: .mouseUp, key: nil, duration: 0, delay: 0.05, x: 10, y: 10),
            MacroAction(type: .keyUp, key: "w", duration: 0, delay: 0.05)
        ]), target: .testTarget, backend: backend)
        try await waitUntilIdle(engine)
        try expect(backend.events == ["down:13", "mouseDown", "mouseUp", "up:13"],
                   "Simultaneous key and mouse event order changed")
        try expect(backend.eventTimes[1] < backend.eventTimes[2] && backend.eventTimes[2] < backend.eventTimes[3],
                   "Key and mouse holds did not overlap as recorded")
        try expect(backend.eventTimes[2] >= backend.eventTimes[1] + 49_000_000,
                   "The overlapping mouse hold was shortened")
    }

    private static func testOverlappingKeys() async throws {
        let backend = FakeBackend()
        let engine = makeEngine()
        engine.start(macro: MacroDefinition(name: "Overlapping Keys", actions: [
            MacroAction(type: .keyDown, key: "w", duration: 0),
            MacroAction(type: .keyDown, key: "d", duration: 0, delay: 0.04),
            MacroAction(type: .keyUp, key: "w", duration: 0, delay: 0.06),
            MacroAction(type: .keyUp, key: "d", duration: 0, delay: 0.06)
        ]), target: .testTarget, backend: backend)
        try await waitUntilIdle(engine)
        try expect(backend.events == ["down:13", "down:2", "up:13", "up:2"],
                   "Overlapping key order changed")
        try expect(backend.eventTimes[1] >= backend.eventTimes[0] + 39_000_000,
                   "The D press came too soon")
        try expect(backend.eventTimes[2] >= backend.eventTimes[1] + 59_000_000,
                   "The overlapping W release came too soon")
        try expect(backend.eventTimes[3] >= backend.eventTimes[2] + 59_000_000,
                   "The D release came too soon")
    }

    private static func testLateKeyUpKeepsFollowingGap() async throws {
        let backend = FakeBackend()
        let engine = makeEngine()
        let timing = TimingProbe(engine)
        engine.onProgress = { progress in
            if progress?.current == 2 { Thread.sleep(forTimeInterval: 0.08) }
        }
        engine.start(macro: MacroDefinition(name: "Late Key Up", actions: [
            MacroAction(type: .keyDown, key: "w", duration: 0),
            MacroAction(type: .keyUp, key: "w", duration: 0, delay: 0.05),
            MacroAction(type: .keyDown, key: "d", duration: 0, delay: 0.06)
        ]), target: .testTarget, backend: backend)
        try await waitUntilIdle(engine)
        try expect(backend.events == ["down:13", "up:13", "down:2", "up:2"],
                   "Late key-up or cleanup changed action order")
        try expect(timing.call(2).deadline == timing.call(1).actual + 60_000_000,
                   "A late key-up changed the scheduled gap before D")
        try expect(backend.eventTimes[2] >= backend.eventTimes[1] + 59_000_000,
                   "A late key-up compressed the following gap")
    }

    private static func testConsecutiveClicksAfterSlowRelease() async throws {
        let backend = FakeBackend()
        backend.firstMouseUpDelay = 0.07
        let engine = makeEngine()
        let timing = TimingProbe(engine)
        engine.start(macro: MacroDefinition(name: "Clicks After Slow Release", actions: [
            MacroAction(type: .mouseDown, key: nil, duration: 0, x: 10, y: 10),
            MacroAction(type: .mouseUp, key: nil, duration: 0, delay: 0.06, x: 10, y: 10),
            MacroAction(type: .mouseDown, key: nil, duration: 0, delay: 0.10, x: 10, y: 10),
            MacroAction(type: .mouseUp, key: nil, duration: 0, delay: 0.06, x: 10, y: 10)
        ]), target: .testTarget, backend: backend)
        try await waitUntilIdle(engine)
        try expect(backend.events == ["mouseDown", "mouseUp", "mouseDown", "mouseUp"],
                   "Consecutive click order changed")
        let scheduledGap = timing.call(2).deadline - timing.call(1).actual
        try expect(scheduledGap == 100_000_000,
                   "A slow mouse-up added an unintended scheduled gap between clicks")
    }

    private static func testMultipleLateDispatches() async throws {
        let backend = FakeBackend()
        let engine = makeEngine()
        let timing = TimingProbe(engine)
        engine.onProgress = { progress in
            if progress?.current == 1 { Thread.sleep(forTimeInterval: 0.07) }
            if progress?.current == 3 { Thread.sleep(forTimeInterval: 0.06) }
        }
        engine.start(macro: MacroDefinition(name: "Two Late Events", actions: [
            MacroAction(type: .keyDown, key: "w", duration: 0),
            MacroAction(type: .keyUp, key: "w", duration: 0, delay: 0.05),
            MacroAction(type: .keyDown, key: "d", duration: 0, delay: 0.05),
            MacroAction(type: .keyUp, key: "d", duration: 0, delay: 0.05)
        ]), target: .testTarget, backend: backend)
        try await waitUntilIdle(engine)
        try expect(backend.events == ["down:13", "up:13", "down:2", "up:2"], "Multiple late events changed order")
        try expect(backend.eventTimes[1] >= backend.eventTimes[0] + 49_000_000,
                   "First late event shortened W hold")
        try expect(backend.eventTimes[2] >= backend.eventTimes[1] + 59_000_000,
                   "Second late event compressed the W-to-D gap")
        try expect(backend.eventTimes[3] >= backend.eventTimes[2] + 49_000_000,
                   "Second late event shortened D hold")
        try expect(timing.call(1).deadline == timing.call(0).returned + 50_000_000,
                   "First lateness was applied more than once")
        try expect(timing.call(2).deadline == timing.call(1).actual + 50_000_000,
                   "Second lateness was applied more than once")
        try expect(timing.call(3).deadline == timing.call(2).returned + 50_000_000,
                   "A delayed D press changed its scheduled hold")
    }

    private static func testPauseResumeKeepsRemainingInterval() async throws {
        let backend = FakeBackend()
        let engine = makeEngine()
        let timing = TimingProbe(engine)
        engine.start(macro: MacroDefinition(name: "Pause During Hold", actions: [
            MacroAction(type: .keyDown, key: "w", duration: 0),
            MacroAction(type: .keyUp, key: "w", duration: 0, delay: 0.16),
            MacroAction(type: .keyDown, key: "d", duration: 0, delay: 0)
        ]), target: .testTarget, backend: backend)
        while backend.events.isEmpty { try await Task.sleep(nanoseconds: 1_000_000) }
        try await Task.sleep(nanoseconds: 30_000_000)
        let pauseRequestedAt = DispatchTime.now().uptimeNanoseconds
        engine.togglePause()
        try await Task.sleep(nanoseconds: 90_000_000)
        let resumeRequestedAt = DispatchTime.now().uptimeNanoseconds
        engine.togglePause()
        try await waitUntilIdle(engine)
        try expect(backend.events == ["down:13", "up:13", "down:2", "up:2"],
                   "Pause/resume changed event order")
        let hold = backend.eventTimes[1] - backend.eventTimes[0]
        try expect(hold >= 240_000_000,
                   "Pause/resume did not preserve the remaining W hold")
        try expect(timing.call(1).deadline >= timing.call(0).deadline + 160_000_000
                   + (resumeRequestedAt - pauseRequestedAt) - 1_000_000,
                   "The scheduler lost part of the paused interval")
        try expect(timing.call(2).deadline == timing.call(1).actual,
                   "Pause/resume introduced a scheduled W-to-D handoff gap")
    }

    private static func testPauseDuringProgressBlocksDispatch() async throws {
        let backend = FakeBackend()
        let engine = makeEngine()
        engine.onProgress = { progress in
            if progress?.current == 1 { engine.togglePause() }
        }
        engine.start(macro: MacroDefinition(name: "Pause Before Dispatch", actions: [
            MacroAction(type: .keyDown, key: "w", duration: 0)
        ]), target: .testTarget, backend: backend)
        while engine.state != .paused { try await Task.sleep(nanoseconds: 1_000_000) }
        try await Task.sleep(nanoseconds: 30_000_000)
        try expect(backend.events.isEmpty, "Input was posted after playback paused")
        engine.togglePause()
        try await waitUntilIdle(engine)
        try expect(backend.events == ["down:13", "up:13"], "Resume or cleanup lost the held key")
    }

    private static func testCompletedPauseBetweenWaitAndDispatch() async throws {
        let backend = FakeBackend()
        let engine = makeEngine()
        let timing = TimingProbe(engine)
        var pauseEndedAt: UInt64 = 0
        engine.onProgress = { progress in
            if progress?.current == 1 {
                engine.togglePause()
                Thread.sleep(forTimeInterval: 0.03)
                engine.togglePause()
                pauseEndedAt = DispatchTime.now().uptimeNanoseconds
            }
        }
        engine.start(macro: MacroDefinition(name: "Completed Pause Before Dispatch", actions: [
            MacroAction(type: .keyDown, key: "w", duration: 0)
        ]), target: .testTarget, backend: backend)
        try await waitUntilIdle(engine)
        try expect(backend.events == ["down:13", "up:13"], "Completed pause changed event order")
        try expect(timing.call(0).deadline >= pauseEndedAt - 1_000_000,
                   "A completed pause between waits was omitted from the action deadline")
    }

    private static func testEmergencyStopReleasesOverlappingInputs() async throws {
        let backend = FakeBackend()
        let engine = makeEngine()
        engine.start(macro: MacroDefinition(name: "Emergency Stop Held Inputs", actions: [
            MacroAction(type: .keyDown, key: "w", duration: 0),
            MacroAction(type: .mouseDown, key: nil, duration: 0, x: 10, y: 10),
            MacroAction(type: .keyUp, key: "w", duration: 0, delay: 5)
        ]), target: .testTarget, backend: backend)
        while backend.events.count < 2 { try await Task.sleep(nanoseconds: 1_000_000) }
        engine.togglePause()
        engine.stop()
        try await waitUntilIdle(engine)
        try expect(backend.events == ["down:13", "mouseDown", "up:13", "mouseUp"],
                   "Emergency stop left an overlapping key or mouse button held")
    }

    private static func makeEngine(
        targetWindowResolver: @escaping (TargetWindow) -> TargetWindow? = { $0 },
        frontmostPID: @escaping () -> pid_t? = { TargetWindow.testTarget.processIdentifier }
    ) -> MacroEngine {
        MacroEngine(isAuthorized: { true }, targetIsRunning: { _ in true },
                    targetWindowResolver: targetWindowResolver, frontmostPID: frontmostPID,
                    focusedWindowStatus: { _ in .matched })
    }

    private static func waitUntilIdle(_ engine: MacroEngine) async throws {
        let deadline = Date().addingTimeInterval(2)
        while engine.state != .idle {
            if Date() > deadline { throw EngineTestFailure("Engine did not finish in time") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw EngineTestFailure(message) }
    }
}

@MainActor
private final class TimingProbe {
    struct Call {
        let deadline: UInt64
        let actual: UInt64
        let returned: UInt64
    }

    private var calls: [Int: Call] = [:]

    init(_ engine: MacroEngine) {
        engine.onDispatchTiming = { [weak self] index, _, deadline, actual, returned in
            guard let deadline else { return }
            self?.calls[index] = Call(deadline: deadline, actual: actual, returned: returned)
        }
    }

    func call(_ index: Int) -> Call { calls[index]! }
}

@MainActor
private final class FakeBackend: InputBackend {
    let displayName = "Fake"
    let canVerifyReceipt = true
    let mousePlaybackMode: MousePlaybackMode
    var events: [String] = []
    var points: [CGPoint] = []
    var scrollUnits: [MacroScrollUnit] = []
    var eventTimes: [UInt64] = []
    var firstMouseDownDelay: TimeInterval = 0
    var firstKeyDownDelay: TimeInterval = 0
    var firstKeyUpDelay: TimeInterval = 0
    var firstMouseUpDelay: TimeInterval = 0
    var firstMouseDownReturn: UInt64 = 0
    var firstKeyDownReturn: UInt64 = 0
    var firstKeyUpReturn: UInt64 = 0

    init(mousePlaybackMode: MousePlaybackMode = .background) {
        self.mousePlaybackMode = mousePlaybackMode
    }

    func keyDown(_ keyCode: CGKeyCode, target: TargetWindow) throws {
        eventTimes.append(DispatchTime.now().uptimeNanoseconds)
        events.append("down:\(keyCode)")
    }
    func keyDown(_ keyCode: CGKeyCode, target: TargetWindow, isRepeat: Bool) throws {
        eventTimes.append(DispatchTime.now().uptimeNanoseconds)
        events.append("\(isRepeat ? "repeat" : "down"):\(keyCode)")
        if firstKeyDownDelay > 0 {
            Thread.sleep(forTimeInterval: firstKeyDownDelay)
            firstKeyDownReturn = DispatchTime.now().uptimeNanoseconds
            firstKeyDownDelay = 0
        }
    }
    func keyUp(_ keyCode: CGKeyCode, target: TargetWindow) throws {
        eventTimes.append(DispatchTime.now().uptimeNanoseconds)
        events.append("up:\(keyCode)")
        if firstKeyUpDelay > 0 {
            Thread.sleep(forTimeInterval: firstKeyUpDelay)
            firstKeyUpReturn = DispatchTime.now().uptimeNanoseconds
            firstKeyUpDelay = 0
        }
    }
    func mouseMove(to point: CGPoint, target: TargetWindow) throws {
        eventTimes.append(DispatchTime.now().uptimeNanoseconds)
        events.append("move"); points.append(point)
    }
    func mouseDrag(_ button: MacroMouseButton, to point: CGPoint, target: TargetWindow) throws {
        eventTimes.append(DispatchTime.now().uptimeNanoseconds)
        events.append("drag"); points.append(point)
    }
    func mouseDown(_ button: MacroMouseButton, at point: CGPoint, clickCount: Int, target: TargetWindow) throws {
        eventTimes.append(DispatchTime.now().uptimeNanoseconds)
        events.append("mouseDown"); points.append(point)
        if firstMouseDownDelay > 0 {
            Thread.sleep(forTimeInterval: firstMouseDownDelay)
            firstMouseDownReturn = DispatchTime.now().uptimeNanoseconds
            firstMouseDownDelay = 0
        }
    }
    func mouseUp(_ button: MacroMouseButton, at point: CGPoint, clickCount: Int, target: TargetWindow) throws {
        eventTimes.append(DispatchTime.now().uptimeNanoseconds)
        events.append("mouseUp")
        if firstMouseUpDelay > 0 {
            Thread.sleep(forTimeInterval: firstMouseUpDelay)
            firstMouseUpDelay = 0
        }
    }
    func scroll(deltaX: Double, deltaY: Double, units: MacroScrollUnit, at point: CGPoint, target: TargetWindow) throws {
        eventTimes.append(DispatchTime.now().uptimeNanoseconds)
        events.append("scroll"); scrollUnits.append(units)
    }
}

private extension TargetWindow {
    static let testTarget = TargetWindow(
        id: 1,
        applicationName: "Test",
        windowTitle: "Test",
        processIdentifier: 1,
        bundleIdentifier: "test.target",
        bounds: CGRect(x: 0, y: 0, width: 800, height: 600)
    )
}

private struct EngineTestFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
