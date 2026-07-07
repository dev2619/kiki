import AppKit
import SwiftUI
import KikiCore

/// Panel flotante tipo pill, centrado abajo, que nunca roba el foco
/// de la app donde el usuario está dictando.
@MainActor
final class HUDController {
    /// Duración fija del pill transitorio (`showTransient`) antes de
    /// auto-restaurar la vista normal — ver doc ahí.
    private static let transientDuration: UInt64 = 1_200_000_000 // 1.2s en ns

    private let panel: NSPanel
    private let model = HUDModel()
    /// Incrementado en cada `showTransient`: si llega uno nuevo antes de que
    /// expire el timer del anterior (p. ej. dos toggles rápidos de ⌥⌘K), el
    /// timer viejo se descarta sin restaurar nada — solo el más reciente
    /// controla cuándo se auto-oculta.
    private var transientGeneration = 0

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 48),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: HUDView(model: model))
    }

    func show(state: DictationState) {
        model.state = state
        switch state {
        case .idle:
            // Sesión continua de manos-libres: si sigue armada (pill "👂 Te
            // escucho…" entre utterances), NO ocultar el panel al volver a
            // idle — solo se oculta cuando de verdad no hay nada que mostrar.
            if model.armed {
                positionAtBottomCenter()
                panel.orderFrontRegardless()
            } else {
                panel.orderOut(nil)
            }
        case .recording, .processing:
            positionAtBottomCenter()
            panel.orderFrontRegardless()
        }
    }

    func updateLevel(_ level: Float) {
        model.level = level
    }

    /// Fija si la pill de "Procesando…" debe mostrarse como "Traduciendo…"
    /// en el próximo/actual `.processing`. `AppDelegate` lo llama al leer
    /// `kiki.translateEnabled` justo cuando el estado del dictado pasa a
    /// `.processing` — ver `HUDView`/`HUDModel.translating`.
    func setTranslating(_ on: Bool) {
        model.translating = on
    }

    func showArmed(_ on: Bool) {
        model.armed = on
        if on {
            positionAtBottomCenter()
            panel.orderFrontRegardless()
        } else if model.state == .idle {
            panel.orderOut(nil)
        }
    }

    /// Pill transitorio con texto libre (p. ej. confirmación del atajo
    /// ⌥⌘K): se muestra 1.2s y luego se auto-restaura a lo que `show(state:)`
    /// hubiera mostrado para el `state`/`armed` vigentes en ese momento —
    /// "respeta el estado armado" sin duplicar esa lógica aquí.
    func showTransient(_ text: String) {
        model.transientText = text
        positionAtBottomCenter()
        panel.orderFrontRegardless()
        transientGeneration += 1
        let generation = transientGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.transientDuration)
            guard let self, generation == self.transientGeneration else { return }
            self.model.transientText = nil
            self.show(state: self.model.state)
        }
    }

    private func positionAtBottomCenter() {
        // NSScreen.main returns the screen with the key window (follows focus); intentional for dictation HUD positioning
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + 24))
    }
}
