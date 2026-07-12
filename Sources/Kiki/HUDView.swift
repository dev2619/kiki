import SwiftUI
import KikiCore

final class HUDModel: ObservableObject {
    @Published var state: DictationState = .idle
    @Published var level: Float = 0
    @Published var armed: Bool = false
    /// Texto de un pill transitorio (p. ej. confirmación del atajo ⌥⌘K).
    /// Tiene prioridad de render sobre `state`/`armed` — y sobre la burbuja
    /// de `liveText` — mientras no sea nil — ver `HUDController.showTransient`.
    @Published var transientText: String?
    /// `true` cuando el modo "Traducir al dictar" está activo — cambia el
    /// texto de la pill de "Procesando…" a "Traduciendo…" mientras
    /// `state == .processing`, para que el usuario sepa que ese dictado se
    /// está traduciendo, no solo limpiando. `AppDelegate` lo fija justo al
    /// entrar a `.processing` (ver `HUDController.setTranslating`).
    @Published var translating: Bool = false
    /// Transcripción parcial en vivo del dictado actual. Cuando no es nil y
    /// el estado es `.recording`/`.processing`, reemplaza el pill por la
    /// burbuja de texto (ver `HUDView.showBubble`) — ver
    /// `HUDController.updateLiveText`.
    @Published var liveText: String?
}

struct HUDView: View {
    @ObservedObject var model: HUDModel

    /// La burbuja de texto en vivo reemplaza el pill mientras se dicta:
    /// requiere `liveText` no-nil, ningún `transientText` activo (que tiene
    /// prioridad — ver doc en `HUDModel`) y estado `.recording` o
    /// `.processing` (pase final, breve, tras soltar el atajo).
    private var showBubble: Bool {
        model.transientText == nil && model.liveText != nil
            && (model.state == .recording || model.state == .processing)
    }

    var body: some View {
        content
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(background)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        if showBubble, let liveText = model.liveText {
            bubbleBody(liveText)
        } else {
            pillBody
        }
    }

    @ViewBuilder
    private var background: some View {
        if showBubble {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.75))
        } else {
            Capsule().fill(Color.black.opacity(0.75))
        }
    }

    @ViewBuilder
    private var pillBody: some View {
        HStack(spacing: 10) {
            if let transientText = model.transientText {
                Text(transientText)
            } else {
                switch model.state {
                case .recording:
                    Circle()
                        .fill(.red)
                        .frame(width: 12, height: 12)
                        .scaleEffect(1 + CGFloat(min(model.level * 8, 1.5)))
                        .animation(.easeOut(duration: 0.1), value: model.level)
                    Text("Escuchando…")
                case .processing:
                    ProgressView()
                        .controlSize(.small)
                    Text(model.translating ? "Traduciendo…" : "Procesando…")
                case .idle:
                    if model.armed {
                        Text("👂 Te escucho…")
                    } else {
                        EmptyView()
                    }
                }
            }
        }
    }

    /// Contenido de la burbuja: punto rojo pulsante mientras se graba, o un
    /// spinner pequeño en el pase final de `.processing` (breve, en vez de
    /// volver al pill "Procesando…") — más el texto en vivo, hasta ~3 líneas.
    /// `.truncationMode(.head)` recorta el inicio si excede esas líneas, para
    /// que siempre se vea la parte más reciente de lo dictado.
    @ViewBuilder
    private func bubbleBody(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if model.state == .recording {
                Circle()
                    .fill(.red)
                    .frame(width: 12, height: 12)
                    .scaleEffect(1 + CGFloat(min(model.level * 8, 1.5)))
                    .animation(.easeOut(duration: 0.1), value: model.level)
                    .padding(.top, 2)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            Text(text)
                .lineLimit(3)
                .truncationMode(.head)
        }
        .frame(maxWidth: 420, alignment: .leading)
    }
}
