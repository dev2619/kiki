import Foundation

public enum DictationState: Equatable {
    case idle
    case recording
    case processing
}

public enum DictationError: Error, Equatable {
    case audioUnavailable(String)
    case transcriptionFailed(String)
    case insertionFailed(String)
}

/// Captura de micrófono. `stop()` devuelve las muestras acumuladas
/// en 16 kHz mono Float32.
public protocol AudioRecording: AnyObject {
    func start() throws
    func stop() -> [Float]
}

public protocol Transcribing: AnyObject {
    func transcribe(_ samples: [Float]) async throws -> String

    /// Como `transcribe`, pero cuando `knownLanguage` no es `nil` reutiliza ese
    /// idioma y OMITE la detección de idioma — que en Whisper es un pase de
    /// inferencia COMPLETO extra sobre todo el buffer. Lo usa el pase final del
    /// dictado live (`LiveTranscriptionCoordinator.finish`), donde el idioma ya
    /// lo fijaron los pases intermedios de la MISMA sesión (el wake está
    /// detenido durante el dictado por hotkey, así que no hay interferencia).
    /// Corta ~a la mitad la latencia del "procesando" al soltar. Las gates
    /// anti-alucinación del pase estricto se mantienen intactas.
    ///
    /// Default: ignora el hint (idéntico a `transcribe`) — para mocks de test
    /// y conformers que no expongan el atajo.
    func transcribe(_ samples: [Float], knownLanguage: String?) async throws -> String
}

public extension Transcribing {
    func transcribe(_ samples: [Float], knownLanguage: String?) async throws -> String {
        try await transcribe(samples)
    }
}

/// Transcripción leniente para parciales de display (F1 fix 2026-07-12):
/// sin gates anti-alucinación — el texto NUNCA se inserta, solo pinta la
/// burbuja live; los pases finales/insertables usan `Transcribing` (con gates).
public protocol LenientTranscribing: AnyObject {
    func transcribeLenient(_ samples: [Float]) async throws -> String
}

public protocol TextInserting: AnyObject {
    func insert(_ text: String) throws
}

@MainActor
public protocol DictationControllerDelegate: AnyObject {
    func dictationStateDidChange(_ state: DictationState)
    func dictationDidFail(_ error: DictationError)
    /// Se dispara justo después de insertar texto con éxito (path de snippet
    /// o de refinado/crudo), en ambos modos (hotkey y manos-libres). Default
    /// vacío vía extensión para no romper conformers/tests existentes que no
    /// lo necesitan.
    /// - Parameter text: el texto que se insertó (para mostrarlo como
    ///   confirmación en el HUD — resultado coherente con el portapapeles).
    func dictationDidInsert(_ text: String)
    /// Parcial en vivo del `LiveTranscriptionCoordinator` activo durante un
    /// dictado live (F1 Task 3). `nil` limpia la burbuja HUD — se entrega así
    /// explícitamente al terminar (`hotkeyReleased`) o cancelar (`cancel()`)
    /// un dictado live, nunca a través de `onPartial` (que solo dispara con
    /// texto no vacío, ver `LiveTranscriptionCoordinator`). Llega en
    /// MainActor, igual que el resto de este delegate. Sin default vía
    /// extensión a propósito: los conformers existentes (`AppDelegate`, spies
    /// de test) deben decidir explícitamente qué hacer con el parcial.
    func dictationLivePartialDidChange(_ text: String?)
}

extension DictationControllerDelegate {
    public func dictationDidInsert(_ text: String) {}
}

public enum AppProfile: String, Equatable, CaseIterable {
    case code, chat, email, docs, neutral
}

public protocol ContextProviding: AnyObject {
    func currentProfile() -> AppProfile
}

public protocol Refining: AnyObject {
    /// Devuelve el texto refinado. Lanza si falla; el controller degrada a crudo.
    ///
    /// - Parameters:
    ///   - language: Idioma detectado por Whisper para este dictado ("es"/"en").
    ///     Se usa para FIJAR el idioma de salida del refinado — ver
    ///     `RefinePrompt` — en vez de dejar que el LLM adivine/derive al
    ///     español por defecto (bug de fidelidad, ver `DictationController`).
    ///   - translate: Cuando es `true`, el refinado traduce el texto AL OTRO
    ///     idioma (es→en / en→es) en vez de solo limpiarlo en el idioma
    ///     detectado. Modo opt-in (Ajustes → "Traducir al dictar").
    func refine(_ text: String, profile: AppProfile, language: String, translate: Bool) async throws -> String
}

public struct HistoryRecord: Equatable {
    public let rawText: String
    public let finalText: String
    public let profile: AppProfile
    public let audioSeconds: Double

    public init(rawText: String, finalText: String, profile: AppProfile, audioSeconds: Double) {
        self.rawText = rawText
        self.finalText = finalText
        self.profile = profile
        self.audioSeconds = audioSeconds
    }
}

public protocol HistoryRecording: AnyObject {
    func record(_ entry: HistoryRecord)
}

public protocol SnippetExpanding: AnyObject {
    /// Devuelve la plantilla si el texto (dictado completo) coincide con un trigger; nil si no.
    func expand(_ text: String) -> String?
}

public protocol DictionaryProviding: AnyObject {
    func terms() -> [String]
}

/// Expone el idioma detectado por Whisper en la transcripción más reciente
/// (Fase: fidelidad de idioma). `WhisperTranscriber` es un actor y ya expone
/// una propiedad `lastDetectedLanguage`, pero un protocolo no puede tener un
/// requerimiento `func` con el mismo nombre base que una propiedad
/// almacenada del mismo tipo (colisión de declaración) — de ahí el nombre
/// `detectedLanguage()` distinto para el requerimiento del protocolo, que
/// internamente solo reenvía esa propiedad. Declarado `async` porque el
/// conformer real es un actor: el acceso desde fuera de su aislamiento
/// siempre requiere `await`, aun cuando el cuerpo de la implementación sea
/// síncrono puertas adentro.
///
/// Optional por diseño: `DictationController` recibe un
/// `languageProvider: LanguageDetecting?` con default `nil`, que hace que el
/// idioma caiga a `"es"` — el comportamiento previo a este fix — así los 30+
/// tests existentes del controller compilan y pasan sin tocarlos.
public protocol LanguageDetecting: AnyObject {
    func detectedLanguage() async -> String
}
