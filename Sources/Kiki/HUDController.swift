import AppKit
import SwiftUI
import KikiCore

/// Panel flotante tipo pill, centrado abajo, que nunca roba el foco
/// de la app donde el usuario está dictando.
@MainActor
final class HUDController {
    private let panel: NSPanel
    private let model = HUDModel()

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

    func showArmed(_ on: Bool) {
        model.armed = on
        if on {
            positionAtBottomCenter()
            panel.orderFrontRegardless()
        } else if model.state == .idle {
            panel.orderOut(nil)
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
