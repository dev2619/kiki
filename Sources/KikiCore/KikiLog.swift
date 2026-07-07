import Foundation

/// Logger local de kiki: escribe a ~/Library/Logs/kiki.log además de NSLog.
/// Cero telemetría — el archivo nunca sale del equipo. NSLog no llega al
/// unified log en apps con firma ad-hoc lanzadas vía `open`, por eso el archivo.
public enum KikiLog {
    private static let queue = DispatchQueue(label: "com.dev2619.kiki.log")
    private static let formatter = ISO8601DateFormatter()
    private static let logURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("kiki.log")
    }()

    /// true cuando el proceso es un test runner (XCTest) — los tests no deben
    /// escribir al kiki.log real del usuario (confunde el diagnóstico en campo).
    private static let isTestRun =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    public static func log(_ message: String) {
        NSLog("%@", message)
        guard !isTestRun else { return }
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: logURL)
            }
        }
    }
}
