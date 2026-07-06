import Foundation
import KikiCore

enum JSONStore {
    static func load<T: Codable>(from fileURL: URL) -> T? {
        // Create directory if it doesn't exist
        let dirURL = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

        // If file doesn't exist, return nil (let caller use default)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        // Try to load and decode
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            return try decoder.decode(T.self, from: data)
        } catch {
            // Log corruption
            let filename = fileURL.lastPathComponent
            KikiLog.log("kiki store: \(filename) corrupto — reiniciando vacío")
            return nil
        }
    }

    static func save<T: Codable>(_ value: T, to fileURL: URL) {
        // Create directory if it doesn't exist
        let dirURL = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

        // Encode and save atomically
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(value)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            KikiLog.log("kiki store: error saving to \(fileURL.lastPathComponent): \(error)")
        }
    }
}
