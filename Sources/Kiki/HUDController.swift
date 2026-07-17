import AppKit
import SwiftUI
import KikiCore

/// Panel flotante tipo pill, centrado abajo, que nunca roba el foco
/// de la app donde el usuario está dictando.
@MainActor
final class HUDController {
    /// Duración fija del pill transitorio (`showTransient`) antes de
    /// auto-restaurar la vista normal — ver doc ahí.
    private static let transientDuration: UInt64 = 2_200_000_000 // 2.2s en ns
    /// Gracia tras salir el cursor de la nube (hover-para-persistir): se oculta
    /// poco después de que el cursor la abandona, no de golpe.
    private static let hoverExitGrace: UInt64 = 600_000_000 // 0.6s en ns
    /// Tamaños por estado (compactos — la píldora NO es una barra gigante
    /// vacía). El cambio entre estados es una transición ANIMADA suave (ver
    /// `applyLayout`), no un salto por-palabra: grabando/procesando comparten
    /// el tamaño compacto (sin salto entre ellos), y solo al revelar el
    /// RESULTADO crece a `resultSize` un instante.
    private static let recordingSize = NSSize(width: 220, height: 50)  // onda reactiva a la voz
    private static let processingSize = NSSize(width: 220, height: 50) // contorno multicolor girando (mismo ancho → sin salto rec→proc)
    private static let armedSize = NSSize(width: 200, height: 50)      // "Te escucho…"
    // Resultado: ancho fijo, ALTO dinámico según el texto (crece hasta caber;
    // más allá del máximo hay scroll interno en `HUDView.resultRow`).
    private static let resultWidth: CGFloat = 440
    private static let minResultHeight: CGFloat = 58
    private static let maxResultHeight: CGFloat = 220

    private let panel: NSPanel
    private let model = HUDModel()
    /// Incrementado en cada `showTransient`: si llega uno nuevo antes de que
    /// expire el timer del anterior (p. ej. dos toggles rápidos de ⌥⌘K), el
    /// timer viejo se descarta sin restaurar nada — solo el más reciente
    /// controla cuándo se auto-oculta.
    private var transientGeneration = 0
    /// Tamaño calculado para el resultado transitorio en curso (alto dinámico).
    private var pendingResultSize = NSSize(width: 440, height: 58)

    init() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.recordingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Sombra flotante del panel (sigue la forma redondeada del vidrio
        // SwiftUI). El look de vidrio premium (blur + degradado + borde
        // iluminado + halo) vive en `HUDView.glass` — puerto del mockup
        // aprobado; ya no se usa NSVisualEffectView (a nivel statusBar el
        // blur behind-window renderizaba gris plano).
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: HUDView(model: model))
        // Hover-para-persistir: la nube de resultado avisa cuándo el cursor
        // entra/sale para pausar o reanudar el auto-ocultado.
        model.onHoverChange = { [weak self] hovering in
            self?.handleResultHover(hovering)
        }
    }

    func show(state: DictationState) {
        model.state = state
        // Fuera del resultado transitorio, la nube vuelve a ignorar el ratón
        // (no roba clics a la app donde el usuario dicta).
        if model.transientText == nil {
            panel.ignoresMouseEvents = true
        }
        // Defensa: un caller que llegue a idle sin updateLiveText(nil) no debe
        // filtrar el texto de la sesión anterior a la próxima burbuja.
        if case .idle = state {
            model.liveText = nil
        }
        switch state {
        case .idle:
            // Sesión continua de manos-libres: si sigue armada (pill "👂 Te
            // escucho…" entre utterances), NO ocultar el panel al volver a
            // idle — solo se oculta cuando de verdad no hay nada que mostrar.
            if model.armed {
                applyLayout(animated: true)
                panel.orderFrontRegardless()
            } else {
                panel.orderOut(nil)
            }
        case .recording, .processing:
            applyLayout(animated: true)
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
            applyLayout(animated: true)
            panel.orderFrontRegardless()
        } else if model.state == .idle {
            panel.orderOut(nil)
        }
    }

    /// Recibe el parcial en vivo. Desde el rediseño "solo onda" el HUD YA NO
    /// muestra este texto (durante el dictado se ve una onda), así que esto
    /// solo actualiza el modelo por compatibilidad — el panel lo gobierna
    /// `show(state:)`. Se mantiene el método porque `AppDelegate` lo llama
    /// desde `dictationLivePartialDidChange` (incluido el `nil` de limpieza).
    func updateLiveText(_ text: String?) {
        model.liveText = text
    }

    /// Pill transitorio con texto libre (p. ej. confirmación del atajo
    /// ⌥⌘K): se muestra 1.2s y luego se auto-restaura a lo que `show(state:)`
    /// hubiera mostrado para el `state`/`armed` vigentes en ese momento —
    /// "respeta el estado armado" sin duplicar esa lógica aquí.
    func showTransient(_ text: String) {
        model.transientText = text
        pendingResultSize = Self.computeResultSize(for: text)
        // Habilitar eventos de ratón para detectar hover-para-persistir. Fuera
        // del resultado se restaura a `true` en `show(state:)`.
        panel.ignoresMouseEvents = false
        applyLayout(animated: true)
        panel.orderFrontRegardless()
        scheduleTransientDismiss(delay: Self.transientDuration)
    }

    /// Programa el auto-ocultado del pill transitorio con control de generación:
    /// un timer nuevo invalida los previos (toggles rápidos, hover, salida).
    private func scheduleTransientDismiss(delay: UInt64) {
        transientGeneration += 1
        let generation = transientGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self, generation == self.transientGeneration else { return }
            self.model.transientText = nil
            self.panel.ignoresMouseEvents = true
            self.show(state: self.model.state)
        }
    }

    /// Hover-para-persistir: mientras el cursor está DENTRO de la nube de
    /// resultado se cancela el auto-ocultado; al salir se oculta tras una breve
    /// gracia. Si el usuario nunca la toca, rige el timer normal de 2.2 s.
    private func handleResultHover(_ hovering: Bool) {
        guard model.transientText != nil else { return }
        if hovering {
            // invalida cualquier timer pendiente → la nube permanece
            transientGeneration += 1
        } else {
            scheduleTransientDismiss(delay: Self.hoverExitGrace)
        }
    }

    /// Mide el alto necesario para el texto del resultado (ancho fijo), acotado
    /// entre el mínimo y el máximo; más allá del máximo, hay scroll interno.
    private static func computeResultSize(for text: String) -> NSSize {
        let font = NSFont.systemFont(ofSize: 14, weight: .medium)
        let horizontalPadding: CGFloat = 22 * 2   // .padding(.horizontal, 22)
        let iconColumn: CGFloat = 17 + 11         // ✓ + spacing del HStack
        let textWidth = resultWidth - horizontalPadding - iconColumn
        let bounding = (text as NSString).boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font])
        let verticalPadding: CGFloat = 12 * 2     // .padding(.vertical, 12)
        let height = min(max(ceil(bounding.height) + verticalPadding, minResultHeight), maxResultHeight)
        return NSSize(width: resultWidth, height: height)
    }

    /// Tamaño objetivo según el contenido actual.
    private func targetSize() -> NSSize {
        if model.transientText != nil { return pendingResultSize }
        switch model.state {
        case .recording: return Self.recordingSize
        case .processing: return Self.processingSize
        case .idle: return Self.armedSize   // solo visible si `armed`
        }
    }

    /// Redimensiona la píldora al tamaño de su contenido y la recentra
    /// abajo-centro, opcionalmente ANIMADO (transición suave entre estados en
    /// vez de un salto). Reemplaza el viejo tamaño fijo gigante.
    private func applyLayout(animated: Bool) {
        // NSScreen.main returns the screen with the key window (follows focus); intentional for dictation HUD positioning
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = targetSize()
        let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 24)
        panel.setFrame(NSRect(origin: origin, size: size), display: true, animate: animated)
    }
}
