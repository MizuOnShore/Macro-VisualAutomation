import AppKit

@main
struct HotkeyEventSafetySmokeTests {
    static func main() throws {
        let shortcut = HotkeyShortcut.recordDefault
        guard let mouseMoved = NSEvent.mouseEvent(
            with: .mouseMoved,
            location: CGPoint(x: 100, y: 100),
            modifierFlags: [],
            timestamp: 1,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 0,
            pressure: 0
        ) else {
            throw TestFailure("Could not construct mouse event")
        }

        try expect(!shortcut.matches(mouseMoved), "Mouse movement must never be matched as a hotkey")
        print("Hotkey event safety smoke tests passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw TestFailure(message) }
    }
}

private struct TestFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
