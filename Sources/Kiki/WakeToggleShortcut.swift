import AppKit

/// Atajo global ⌥⌘K para alternar el modo manos-libres sin pasar por el menú
/// — Fase 3.6, task-361. Mismo patrón que `HotkeyMonitor`, pero con DOS
/// monitores en vez de uno: un `addGlobalMonitorForEvents` (dispara con kiki
/// en segundo plano, la app no tiene foco) y un `addLocalMonitorForEvents`
/// (dispara cuando una ventana propia de kiki — p. ej. Ajustes — tiene el
/// foco; los monitores globales de AppKit no ven eventos dirigidos a la
/// propia app). El monitor local devuelve `nil` cuando matchea para
/// consumir el evento (evita el beep de "atajo sin handler" y que ⌥⌘K se le
/// cuele a algún control con foco); si no matchea, devuelve el evento sin
/// tocar para que siga su propagación normal.
final class WakeToggleShortcut {
    private static let keyCode: UInt16 = 40 // "k"
    private static let requiredFlags: NSEvent.ModifierFlags = [.option, .command]
    /// Máscara contra la que se comparan los flags del evento: los mismos
    /// bits "device independent" que usa `HotkeyMonitor`, menos `.capsLock`
    /// — Bloq Mayús no debe invalidar el atajo.
    private static let relevantFlagsMask: NSEvent.ModifierFlags =
        NSEvent.ModifierFlags.deviceIndependentFlagsMask.subtracting(.capsLock)

    private let onToggle: () -> Void
    private var globalMonitor: Any?
    private var localMonitor: Any?

    init(onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
    }

    func start() {
        guard globalMonitor == nil, localMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.matches(event) else { return }
            self.onToggle()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.matches(event) else { return event }
            self.onToggle()
            return nil
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func matches(_ event: NSEvent) -> Bool {
        guard event.keyCode == Self.keyCode else { return false }
        let flags = event.modifierFlags.intersection(Self.relevantFlagsMask)
        return flags == Self.requiredFlags
    }
}
