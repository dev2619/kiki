import SwiftUI
import KikiCore

final class HUDModel: ObservableObject {
    @Published var state: DictationState = .idle
    @Published var level: Float = 0
    @Published var armed: Bool = false
    /// Pill transitorio: confirmación ⌥⌘K y el RESULTADO final tras dictar
    /// (mismo texto que se pega), mostrado un instante con fade.
    @Published var transientText: String?
    @Published var translating: Bool = false
    /// Preview en vivo (Paso 2, Apple Speech). Aún nil hasta integrarlo.
    @Published var liveText: String?
    /// Reporta al `HUDController` cuándo el cursor entra/sale de la nube de
    /// resultado, para pausar el auto-ocultado mientras el usuario la enfoca
    /// (hover-para-persistir). No es @Published: es un callback puro.
    var onHoverChange: ((Bool) -> Void)?
}

/// HUD de dictado — píldora premium (puerto del mockup aprobado 2026-07-17):
/// - Grabando: onda que REACCIONA a la voz (nivel del mic), sin icono.
/// - Procesando: TODO el contorno iluminado con multicolor que GIRA + brillo
///   interior a juego (sin texto ni líneas), y transición suave al resultado.
/// - Resultado: ✓ + texto final con fade.
/// - Manos libres: orbe que respira + "Te escucho…".
struct HUDView: View {
    @ObservedObject var model: HUDModel

    private let colors: [Color] = [
        Color(hex: 0x7C5CFF), Color(hex: 0xEC6EAD),
        Color(hex: 0x38BDF8), Color(hex: 0x34D399), Color(hex: 0x7C5CFF),
    ]
    private var accent: Color { Color(hex: 0xA78BFA) }
    private var pink: Color { Color(hex: 0xEC6EAD) }

    private var stateKey: String {
        if model.transientText != nil { return "transient" }
        switch model.state {
        case .recording: return "rec"
        case .processing: return "proc"
        case .idle: return model.armed ? "wake" : "idle"
        }
    }
    private var isProcessing: Bool { model.transientText == nil && model.state == .processing }

    var body: some View {
        content
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(glassBackground)
            .overlay(edgeGlow)
            .environment(\.colorScheme, .dark)
            .animation(.easeInOut(duration: 0.3), value: stateKey)
    }

    @ViewBuilder
    private var content: some View {
        if let transientText = model.transientText {
            resultRow(transientText)
                .onHover { model.onHoverChange?($0) }
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
        } else if model.state == .recording {
            waveform.transition(.opacity.combined(with: .scale(scale: 0.97)))
        } else if model.state == .processing {
            // el contorno + interior hacen todo; sin contenido central
            Color.clear.frame(height: 30).transition(.opacity)
        } else if model.armed {
            wakeRow.transition(.opacity.combined(with: .scale(scale: 0.97)))
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }

    // MARK: - Grabando (onda reactiva a la voz)

    private var waveform: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<30, id: \.self) { i in
                    Capsule()
                        .fill(barColor(i, count: 30))
                        .frame(width: 3, height: recBarHeight(i, count: 30, t: t))
                }
            }
            .frame(height: 32)
        }
    }

    /// Altura guiada por el NIVEL del mic (`model.level`): en silencio la onda
    /// queda casi plana; al hablar sube. Una oscilación senoidal sutil, escalada
    /// por el propio nivel, le da vida orgánica solo cuando hay voz.
    private func recBarHeight(_ i: Int, count n: Int, t: Double) -> CGFloat {
        let center = 1 - abs(Double(i) - Double(n - 1) / 2) / (Double(n - 1) / 2)
        let shape = 0.45 + 0.55 * center
        let level = Double(min(max(model.level, 0) * 9, 1))
        let life = 0.82 + 0.18 * sin(t * 9 + Double(i))
        return 5 + CGFloat(level * 28 * shape * life)
    }

    // MARK: - Resultado

    /// Resultado final: texto completo (sin truncar). La altura de la nube la
    /// calcula `HUDController` para que crezca hasta caber; si excede el máximo,
    /// este `ScrollView` habilita scroll interno.
    private func resultRow(_ text: String) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(Color(hex: 0x34D399))
                    .shadow(color: Color(hex: 0x34D399).opacity(0.5), radius: 4)
                Text(text)
                    .font(.system(size: 14, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Manos libres

    private var wakeRow: some View {
        HStack(spacing: 11) {
            TimelineView(.animation) { timeline in
                let pulse = sin(timeline.date.timeIntervalSinceReferenceDate * 3.4) * 0.5 + 0.5
                Circle()
                    .fill(RadialGradient(colors: [accent, Color(hex: 0x7C5CFF)],
                        center: .init(x: 0.35, y: 0.3), startRadius: 0, endRadius: 7))
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(accent.opacity(0.5 * (1 - pulse)), lineWidth: 6)
                        .scaleEffect(1 + pulse * 0.9))
            }
            .frame(width: 20, height: 20)
            Text("Te escucho…").font(.system(size: 14, weight: .medium))
        }
    }

    // MARK: - Procesado: contorno multicolor girando + brillo interior

    /// Gradiente angular multicolor con el ángulo de inicio desplazado → al
    /// animar `deg` los colores GIRAN alrededor sin rotar la geometría.
    private func conic(_ deg: Double) -> AngularGradient {
        AngularGradient(
            gradient: Gradient(colors: colors),
            center: .center,
            startAngle: .degrees(deg), endAngle: .degrees(deg + 360))
    }

    @ViewBuilder
    private var edgeGlow: some View {
        TimelineView(.animation) { timeline in
            let deg = timeline.date.timeIntervalSinceReferenceDate * 106  // ~3.4s/vuelta
            ZStack {
                Capsule().strokeBorder(conic(deg), lineWidth: 3.5).blur(radius: 3.5).opacity(0.55) // bloom
                Capsule().strokeBorder(conic(deg), lineWidth: 2)                                    // trazo nítido
            }
            .opacity(isProcessing ? 1 : 0)
            .animation(.easeInOut(duration: 0.35), value: isProcessing)
        }
        .allowsHitTesting(false)
    }

    /// Fondo: vidrio premium + (al procesar) un wash multicolor interior a
    /// juego con el borde, girando y difuso.
    private var glassBackground: some View {
        ZStack {
            glass
            TimelineView(.animation) { timeline in
                let deg = timeline.date.timeIntervalSinceReferenceDate * 80
                Capsule()
                    .fill(conic(deg))
                    .blur(radius: 26)
                    .opacity(isProcessing ? 0.22 : 0)
                    .animation(.easeInOut(duration: 0.4), value: isProcessing)
            }
            .clipShape(Capsule())
        }
    }

    private var glass: some View {
        Capsule()
            .fill(.ultraThinMaterial)
            .overlay(Capsule().fill(LinearGradient(
                colors: [Color(hex: 0x221F30).opacity(0.55), Color(hex: 0x0C0B11).opacity(0.66)],
                startPoint: .top, endPoint: .bottom)))
            .overlay(Capsule().fill(RadialGradient(
                colors: [accent.opacity(0.15), .clear],
                center: .init(x: 0.2, y: 0.0), startRadius: 0, endRadius: 220)))
            .overlay(Capsule().strokeBorder(LinearGradient(
                colors: [Color.white.opacity(0.28), Color.white.opacity(0.07)],
                startPoint: .top, endPoint: .bottom), lineWidth: 1))
    }

    // MARK: - Helpers

    private func barColor(_ i: Int, count n: Int) -> LinearGradient {
        let tt = Double(i) / Double(n - 1)
        let top = Color(hue: (262 - tt * 40) / 360, saturation: 1.0, brightness: 0.86)
        return LinearGradient(colors: [top, pink], startPoint: .top, endPoint: .bottom)
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}
