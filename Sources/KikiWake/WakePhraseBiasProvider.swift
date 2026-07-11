import KikiCore

/// Términos de sesgo (initial prompt de Whisper) para el verificador tiny de
/// la frase de activación (F4). Sin este bias, tiny transcribe la frase ES
/// de forma irreconocible ("SKHAIM KIKI" — experimento 2026-07-11, ver
/// docs del plan F4); con él, 4/4 fixtures positivos matchean y el control
/// negativo se sigue rechazando. Es una clase (no struct) porque
/// `DictionaryProviding` es class-bound: el transcriber la referencia weak,
/// así que quien la inyecta (AppDelegate) debe retenerla fuerte.
public final class WakePhraseBiasProvider: DictionaryProviding {
    public init() {}

    public func terms() -> [String] {
        ["escúchame", "kiki", "listen to me kiki"]
    }
}
