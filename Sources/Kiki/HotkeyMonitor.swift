import AppKit

/// Observa la tecla Fn (🌐, keyCode 63) globalmente vía NSEvent flagsChanged.
/// Requiere que la app esté autorizada en Accesibilidad.
final class HotkeyMonitor {
    static let fnKeyCode: UInt16 = 63

    private let onPress: () -> Void
    private let onRelease: () -> Void
    private var monitor: Any?
    private var isDown = false

    init(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        self.onPress = onPress
        self.onRelease = onRelease
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        guard event.keyCode == Self.fnKeyCode else { return }
        let pressed = event.modifierFlags.contains(.function)
        if pressed && !isDown {
            isDown = true
            onPress()
        } else if !pressed && isDown {
            isDown = false
            onRelease()
        }
    }
}
