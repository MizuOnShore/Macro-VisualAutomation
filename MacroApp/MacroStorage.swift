import Foundation
import SwiftUI
import UniformTypeIdentifiers

protocol MacroStoring: Sendable {
    func loadLibrary() throws -> [MacroDefinition]
    func saveLibrary(_ macros: [MacroDefinition]) throws
}

struct MacroStorage: MacroStoring {
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
                .appendingPathComponent("Macros.json")
        }
    }

    func loadLibrary() throws -> [MacroDefinition] {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let data = try Data(contentsOf: fileURL)
                return try Self.decoder.decode([MacroDefinition].self, from: data)
            } catch {
                guard FileManager.default.fileExists(atPath: backupURL.path) else { throw error }
                let backupData = try Data(contentsOf: backupURL)
                return try Self.decoder.decode([MacroDefinition].self, from: backupData)
            }
        }
        if FileManager.default.fileExists(atPath: backupURL.path) {
            let backupData = try Data(contentsOf: backupURL)
            return try Self.decoder.decode([MacroDefinition].self, from: backupData)
        }
        return []
    }

    func saveLibrary(_ macros: [MacroDefinition]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: fileURL.path),
           let currentData = try? Data(contentsOf: fileURL),
           (try? Self.decoder.decode([MacroDefinition].self, from: currentData)) != nil {
            try currentData.write(to: backupURL, options: .atomic)
        }
        let data = try Self.encoder.encode(macros)
        try data.write(to: fileURL, options: .atomic)
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static var decoder: JSONDecoder { JSONDecoder() }
}

struct MacroJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var macro: MacroDefinition

    init(macro: MacroDefinition) {
        self.macro = macro
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        macro = try MacroStorage.decoder.decode(MacroDefinition.self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try MacroStorage.encoder.encode(macro))
    }
}
