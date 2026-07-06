import AVFoundation
import ApplicationServices
import KikiCore

enum Permissions {
    /// Dispara el prompt de micrófono en el primer arranque.
    static func requestMicrophoneAccess() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            KikiLog.log("kiki permisos: micrófono \(granted ? "concedido" : "denegado")")
        }
    }

    /// Muestra el prompt del sistema para Accesibilidad si no está concedido.
    /// Necesario para el monitor global de Fn y el Cmd+V sintético.
    @discardableResult
    static func ensureAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        KikiLog.log("kiki permisos: accesibilidad \(trusted ? "concedida" : "pendiente")")
        return trusted
    }
}
