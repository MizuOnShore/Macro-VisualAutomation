import Foundation

protocol AutomationStoring: Sendable {
    func loadAutomations() throws -> [AutomationDefinition]
    func saveAutomations(_ automations: [AutomationDefinition]) throws
}

struct AutomationStorage: AutomationStoring {
    private let fileURL: URL
    private var backupURL: URL {
        fileURL.deletingPathExtension().appendingPathExtension("backup.json")
    }

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.fileURL = base
                .appendingPathComponent("Macro", isDirectory: true)
                .appendingPathComponent("Automations.json")
        }
    }

    func loadAutomations() throws -> [AutomationDefinition] {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                return try Self.decode(Data(contentsOf: fileURL))
            } catch {
                guard FileManager.default.fileExists(atPath: backupURL.path) else { throw error }
                return try Self.decode(Data(contentsOf: backupURL))
            }
        }
        guard FileManager.default.fileExists(atPath: backupURL.path) else { return [] }
        return try Self.decode(Data(contentsOf: backupURL))
    }

    func saveAutomations(_ automations: [AutomationDefinition]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: fileURL.path),
           let current = try? Data(contentsOf: fileURL),
           (try? Self.decode(current)) != nil {
            try current.write(to: backupURL, options: .atomic)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(automations).write(to: fileURL, options: .atomic)
    }

    private static func decode(_ data: Data) throws -> [AutomationDefinition] {
        let decoder = JSONDecoder()
        return try decoder.decode([AutomationDefinition].self, from: data)
    }
}
