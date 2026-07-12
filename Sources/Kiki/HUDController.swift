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
    /// Tamaño original del panel — pill de una línea.
    private static let pillSize = NSSize(width: 220, height: 48)
    /// Tamaño del panel cuando la burbuja de texto en vivo está activa (ver
    /// `HUDView.showBubble`) — fijo, más grande para ~3 líneas de texto.
    private static let bubbleSize = NSSize(width: 440, height: 110)

    private let panel: NSPanel
    private let model = HUDModel()
    /// Incrementado en cada `showTransient`: si llega uno nuevo antes de que
    /// expire el timer del anterior (p. ej. dos toggles rápidos de ⌥⌘K), el
    /// timer viejo se descarta sin restaurar nada — solo el más reciente
    /// controla cuándo se auto-oculta.
    private var transientGeneration = 0

    init() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.pillSize),
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
        resizeForCurrentContent()
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
        resizeForCurrentContent()
        if on {
            positionAtBottomCenter()
            panel.orderFrontRegardless()
        } else if model.state == .idle {
            panel.orderOut(nil)
        }
    }

    /// Fija la transcripción parcial en vivo del dictado actual. Si no es
    /// nil, asegura que el panel esté visible (el estado `.recording` ya lo
    /// muestra normalmente; esto cubre además el pase final breve de
    /// `.processing`) y redimensiona el panel a la burbuja — ver
    /// `resizeForCurrentContent`/`HUDView.showBubble`.
    func updateLiveText(_ text: String?) {
        model.liveText = text
        resizeForCurrentContent()
        if text != nil {
            positionAtBottomCenter()
            panel.orderFrontRegardless()
        }
    }

    /// Pill transitorio con texto libre (p. ej. confirmación del atajo
    /// ⌥⌘K): se muestra 1.2s y luego se auto-restaura a lo que `show(state:)`
    /// hubiera mostrado para el `state`/`armed` vigentes en ese momento —
    /// "respeta el estado armado" sin duplicar esa lógica aquí.
    func showTransient(_ text: String) {
        model.transientText = text
        resizeForCurrentContent()
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

    /// Misma condición que `HUDView.showBubble` — duplicada aquí porque el
    /// controller no tiene acceso directo al cuerpo de la vista y necesita
    /// decidir el tamaño del panel antes de dibujarla.
    private var shouldShowBubble: Bool {
        model.transientText == nil && model.liveText != nil
            && (model.state == .recording || model.state == .processing)
    }

    /// Ajusta el tamaño del panel al contenido actual: `bubbleSize` para la
    /// burbuja de texto en vivo, `pillSize` (tamaño original) en cualquier
    /// otro caso. No reposiciona — los llamadores ya invocan
    /// `positionAtBottomCenter()` después para recentrar bottom-center con
    /// el nuevo tamaño.
    private func resizeForCurrentContent() {
        let target = shouldShowBubble ? Self.bubbleSize : Self.pillSize
        guard panel.frame.size != target else { return }
        panel.setContentSize(target)
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
