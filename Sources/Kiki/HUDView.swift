import SwiftUI
import KikiCore

final class HUDModel: ObservableObject {
    @Published var state: DictationState = .idle
    @Published var level: Float = 0
    @Published var armed: Bool = false
    /// Texto de un pill transitorio (p. ej. confirmación del atajo ⌥⌘K).
    /// Tiene prioridad de render sobre `state`/`armed` mientras no sea nil —
    /// ver `HUDController.showTransient`.
    @Published var transientText: String?
    /// `true` cuando el modo "Traducir al dictar" está activo — cambia el
    /// texto de la pill de "Procesando…" a "Traduciendo…" mientras
    /// `state == .processing`, para que el usuario sepa que ese dictado se
    /// está traduciendo, no solo limpiando. `AppDelegate` lo fija justo al
    /// entrar a `.processing` (ver `HUDController.setTranslating`).
    @Published var translating: Bool = false
}

struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
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
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Capsule().fill(Color.black.opacity(0.75)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
