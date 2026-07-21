import Foundation

/// Disparadores de voz que un motor de wake-word puede reconocer al instante,
/// sin transcribir (a diferencia del camino Whisper-por-segmento). Cada uno
/// mapea a una frase entrenada en el motor:
/// - `.dictate`        → "escúchame kiki" / "listen to me kiki"
/// - `.startHandsFree` → "manos libres kiki"
/// - `.stopHandsFree`  → "kiki detente"
public enum WakeTrigger: Equatable {
    case dictate
    case startHandsFree
    case stopHandsFree
}

/// Motor de detección de palabra clave ON-DEVICE. Corre de forma continua sobre
/// el audio del micrófono y dispara `onTrigger` en cuanto reconoce una de sus
/// frases — sub-segundo, sin transcribir. Es la clave de la fluidez: Whisper
/// queda reservado SOLO para el dictado real, no para detectar comandos.
///
/// Abstracción deliberada (2026-07-18): kiki no depende de un motor concreto.
/// La primera implementación es `PorcupineWakeWordDetector`; cambiar a un motor
/// 100% abierto (openWakeWord/LiveKit) antes de distribuir = solo otra
/// implementación de este protocolo, sin tocar `WakeListener`/`AppDelegate`.
///
/// Contrato de threading: `process(_:)` se alimenta desde el hilo/cola de audio
/// (frames en tiempo real, nunca bloquear). `onTrigger` se invoca en ese mismo
/// contexto — el caller es responsable de saltar a su cola/`MainActor`.
public protocol WakeWordDetecting: AnyObject {
    /// Se dispara al reconocer una frase. Invocado en el contexto de audio.
    var onTrigger: ((WakeTrigger) -> Void)? { get set }

    /// Alimenta un chunk de audio 16 kHz mono Float32 (el mismo formato que
    /// produce `AudioRecorder`/el tap del `WakeListener`). El motor bufferea
    /// internamente al tamaño de frame que necesite.
    func process(_ samples16kMono: [Float])

    /// Libera el motor (modelos/recursos nativos). Idempotente.
    func stop()
}
