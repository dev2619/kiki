import AppKit

/// Observa la tecla Esc (keyCode 53) globalmente vía NSEvent keyDown.
/// Requiere que la app esté autorizada en Accesibilidad (mismo requisito que
/// `HotkeyMonitor`, ya solicitado en `applicationDidFinishLaunching`).
final class EscMonitor {
    static let escKeyCode: UInt16 = 53

    private let onEscape: () -> Void
    private var monitor: Any?

    init(onEscape: @escaping () -> Void) {
        self.onEscape = onEscape
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        guard event.keyCode == Self.escKeyCode else { return }
        onEscape()
    }
}
