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
        try await testStopReleasesHeldKey()
        print("Macro engine smoke tests passed")
    }

    private static func testRecordedClickExecution() async throws {
        let backend = FakeBackend()
        let engine = MacroEngine(isAuthorized: { true }, targetIsRunning: { _ in true })
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
        let engine = MacroEngine(isAuthorized: { true }, targetIsRunning: { _ in true })
        let macro = MacroDefinition(
            name: "Drag and Scroll",
            actions: [
                MacroAction(type: .mouseDown, key: nil, duration: 0, x: 10, y: 10),
                MacroAction(type: .move, key: nil, duration: 0, x: 80, y: 60),
                MacroAction(type: .mouseUp, key: nil, duration: 0, x: 80, y: 60),
                MacroAction(type: .scroll, key: nil, duration: 0, x: 80, y: 60, scrollDeltaY: -40)
            ]
        )

        engine.start(macro: macro, target: .testTarget, backend: backend)
        try await waitUntilIdle(engine)
        try expect(
            backend.events == ["mouseDown", "drag", "mouseUp", "scroll"],
            "Recorded drag or scroll sequence was incorrect"
        )
    }

    private static func testCountedExecution() async throws {
        let backend = FakeBackend()
        let engine = MacroEngine(isAuthorized: { true }, targetIsRunning: { _ in true })
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
        let engine = MacroEngine(isAuthorized: { true }, targetIsRunning: { _ in true })
        let macro = MacroDefinition(
            name: "Scaled Pointer",
            actions: [MacroAction(type: .move, key: nil, duration: 0, x: 100, y: 75)],
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

    private static func testStopReleasesHeldKey() async throws {
        let backend = FakeBackend()
        let engine = MacroEngine(isAuthorized: { true }, targetIsRunning: { _ in true })
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
private final class FakeBackend: InputBackend {
    let displayName = "Fake"
    let canVerifyReceipt = true
    var events: [String] = []
    var points: [CGPoint] = []

    func keyDown(_ keyCode: CGKeyCode, target: TargetWindow) throws { events.append("down:\(keyCode)") }
    func keyUp(_ keyCode: CGKeyCode, target: TargetWindow) throws { events.append("up:\(keyCode)") }
    func mouseMove(to point: CGPoint, target: TargetWindow) throws { events.append("move"); points.append(point) }
    func mouseDrag(_ button: MacroMouseButton, to point: CGPoint, target: TargetWindow) throws { events.append("drag"); points.append(point) }
    func mouseDown(_ button: MacroMouseButton, at point: CGPoint, clickCount: Int, target: TargetWindow) throws { events.append("mouseDown") }
    func mouseUp(_ button: MacroMouseButton, at point: CGPoint, clickCount: Int, target: TargetWindow) throws { events.append("mouseUp") }
    func scroll(deltaX: Double, deltaY: Double, at point: CGPoint, target: TargetWindow) throws { events.append("scroll") }
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
