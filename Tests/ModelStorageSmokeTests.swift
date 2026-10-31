import Foundation

@main
struct ModelStorageSmokeTests {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw TestFailure("Expected the example macro JSON path")
        }

        let exampleURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let exampleData = try Data(contentsOf: exampleURL)
        let macro = try MacroStorage.decoder.decode(MacroDefinition.self, from: exampleData)

        try expect(macro.name == "Roblox Travel Loop", "Unexpected macro name")
        try expect(macro.actions.count == 6, "Expected six example actions")
        try expect(macro.loopMode == .infinite, "Expected an infinite loop")
        try expect(macro.actions.first?.type == .keyDown, "Expected W down first")
        try expect(macro.actions.first?.key == "w", "Expected W as the first key")

        let minimalData = Data(#"{"name":"Minimal","actions":[{"type":"wait","duration":0.05}],"loopMode":"once"}"#.utf8)
        let minimal = try MacroStorage.decoder.decode(MacroDefinition.self, from: minimalData)
        try expect(minimal.actions.count == 1, "Optional JSON fields did not decode")
        try expect(minimal.actions[0].isEnabled, "Missing enabled state should default to true")
        try expect(minimal.actions[0].mouseButton == .left, "Missing mouse button should default to left")
        try expect(minimal.actions[0].clickCount == 1, "Missing click count should default to one")
        try expect(minimal.mousePlaybackMode == .background, "Missing mouse mode should default to background")

        try expect(AppActivity.recordingCountdown(3).countdownValue == 3, "Countdown activity was incorrect")
        try expect(AppActivity.playing.runState == .running, "Playing activity was not running")
        try expect(AppActivity.paused.runState == .paused, "Paused activity was not paused")

        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MacroModelStorageSmoke-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let libraryURL = temporaryDirectory.appendingPathComponent("Macros.json")
        let storage = MacroStorage(fileURL: libraryURL)
        try storage.saveLibrary([macro])
        let loaded = try storage.loadLibrary()
        try expect(loaded == [macro], "JSON library did not round-trip")

        var updated = macro
        updated.name = "Updated"
        try storage.saveLibrary([updated])
        try FileManager.default.removeItem(at: libraryURL)
        let recoveredWithoutPrimary = try storage.loadLibrary()
        try expect(recoveredWithoutPrimary == [macro], "Missing primary library did not recover from backup")

        try storage.saveLibrary([updated])
        try Data("not valid JSON".utf8).write(to: libraryURL, options: .atomic)
        let recovered = try storage.loadLibrary()
        try expect(recovered == [macro], "Corrupt primary library did not recover from backup")

        try storage.saveLibrary([updated])
        try Data("still not valid JSON".utf8).write(to: libraryURL, options: .atomic)
        let preservedBackup = try storage.loadLibrary()
        try expect(preservedBackup == [macro], "A corrupt primary library replaced the healthy backup")

        print("Model/storage smoke tests passed")
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
