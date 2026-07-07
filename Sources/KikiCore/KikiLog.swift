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
    /// escribir al kiki.log real del usuario (confunde el diagnóstico en
    /// campo). `XCTestConfigurationFilePath` solo lo fija Xcode al correr
    /// tests desde el IDE/`xcodebuild`; bajo `swift test` (SwiftPM) esa
    /// variable de entorno queda sin setear, así que la detección fallaba
    /// silenciosamente en ese flujo y las líneas de log de la suite
    /// terminaban ensuciando el kiki.log real. `NSClassFromString("XCTestCase")`
    /// es un segundo chequeo independiente del entorno: si el binario XCTest
    /// está linkeado (cualquier test runner, SwiftPM incluido), la clase
    /// existe en el runtime de Obj-C aunque la env var no esté seteada.
    private static let isTestRun =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || NSClassFromString("XCTestCase") != nil

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
