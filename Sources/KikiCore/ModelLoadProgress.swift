import Foundation

/// Agrega el progreso (0...1) de las DOS fases de carga de modelos del
/// primer arranque (Whisper STT ~1GB, luego Qwen LLM ~1.6GB) en un único
/// progreso total (0...1) para la ventana de "Preparando kiki…"
/// (`ModelLoadProgressWindowController`, `Sources/Kiki`) y el ítem de menú
/// "Descargando modelos… X%" (`AppDelegate.updateLoadProgress`).
///
/// Función pura (sin AppKit/WhisperKit/MLX) para poder testear la
/// ponderación de forma determinista — ver `Tests/KikiCoreTests/ModelLoadProgressTests.swift`.
public enum ModelLoadProgress {
    /// Peso de la fase 1 (Whisper) sobre el total mostrado. Whisper
    /// (~1GB, variante cuantizada `large-v3_turbo_954MB` — ver
    /// `WhisperTranscriber.preferredModel`) es más liviano que Qwen (~1.6GB,
    /// `LLMRefiner.preferredModel`) dentro de los ~2.7GB totales del primer
    /// arranque: 0.4/0.6 refleja esa proporción sin acoplar el peso exacto a
    /// bytes reales (WhisperKit y MLX no exponen tamaño total de forma
    /// uniforme antes de empezar la descarga).
    public static let phase1Weight: Double = 0.4

    /// Peso de la fase 2 (Qwen). Complemento de `phase1Weight` — las dos
    /// fases son secuenciales (Whisper primero, luego Qwen) y juntas cubren
    /// el 100% del progreso mostrado.
    public static let phase2Weight: Double = 1 - phase1Weight

    /// Combina el progreso de cada fase (0...1 cada una) en el progreso
    /// total (0...1) de la ventana de arranque.
    ///
    /// Ambos parámetros se clampan a `[0, 1]` antes de ponderar: un callback
    /// de WhisperKit/MLX que reportara un valor fuera de rango (p. ej. por un
    /// glitch de `Progress.fractionCompleted`) no debe poder hacer retroceder
    /// la barra por debajo del peso ya ganado de la fase anterior, ni
    /// dispararla por encima de 1.0.
    public static func overall(phase1: Double, phase2: Double) -> Double {
        let p1 = clamp(phase1)
        let p2 = clamp(phase2)
        return p1 * phase1Weight + p2 * phase2Weight
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
