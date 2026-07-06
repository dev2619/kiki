import Foundation
import KikiCore
import WhisperKit

/// Transcripción local con WhisperKit (CoreML). El modelo se descarga
/// de Hugging Face en el primer arranque y queda cacheado en disco.
///
/// ## Serialización de `transcribe`
/// `WhisperTranscriber` es compartido entre el dictado por hotkey
/// (`DictationController`) y el chequeo continuo de frase de activación
/// (`WakeListener`), y ambos pueden invocar `transcribe` desde tareas
/// distintas casi al mismo tiempo (p.ej. un segmento de wake-check en vuelo
/// justo cuando el usuario suelta Fn). WhisperKit no documenta que sea seguro
/// invocarlo concurrentemente desde la misma instancia — y aunque lo fuera,
/// dos inferencias a la vez compitiendo por el ANE degradan la latencia de
/// ambas. Se serializa encadenando cada llamada a la anterior: `transcribe`
/// crea un `Task` que primero espera (`try? await previous?.value`, ignorando
/// su resultado/error) la transcripción encolada justo antes que ella, y solo
/// entonces ejecuta la propia (`doTranscribe`). Es actor para que la lectura
/// + escritura de `activeTranscription` (el enlace de la cadena) sea atómica:
/// como esa sección no tiene ningún `await` de por medio, la reentrancia del
/// actor no puede intercalarse en ella, así que dos llamadas concurrentes
/// siempre encadenan en el orden correcto sin condición de carrera sobre la
/// variable de encadenado — la exclusión mutua real de las inferencias viene
/// de que cada eslabón espera al anterior, no del actor en sí (un actor por
/// sí solo permite reentrancia en sus puntos de `await`).
public actor WhisperTranscriber: Transcribing {
    /// Identificador de modelo resuelto contra el repo HF `argmaxinc/whisperkit-coreml`
    /// (WhisperKit hace glob-match del `model:` contra las carpetas del repo;
    /// comportamiento verificado en 1.0.0, ver nota de versión en `Package.swift`).
    /// Variante CUANTIZADA (954MB) de large-v3 turbo: la full-precision (3GB)
    /// dispara compilaciones ANE de 10-30 min en la primera inferencia — inviable
    /// para dictado (confirmado 2026-07-06: ANECompilerService al 95% CPU con
    /// kiki bloqueado en "Procesando…").
    public static let preferredModel = "large-v3_turbo_954MB"

    private var whisperKit: WhisperKit?
    public private(set) var isReady = false
    /// Enlace de la cadena de serialización, ver doc del tipo.
    private var activeTranscription: Task<String, Error>?

    public init() {}

    /// Carga (y si hace falta descarga) el modelo. Llamar una vez al arrancar.
    public func prepare() async throws {
        let started = Date()
        do {
            // prewarm: fuerza la especialización ANE/CoreML durante la carga
            // ("Cargando modelo…"), nunca durante el primer dictado del usuario.
            whisperKit = try await WhisperKit(WhisperKitConfig(model: Self.preferredModel, prewarm: true))
            KikiLog.log("kiki stt: modelo cargado (\(Self.preferredModel)) en \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        } catch {
            KikiLog.log("kiki stt: \(Self.preferredModel) no disponible (\(error)); usando modelo recomendado")
            whisperKit = try await WhisperKit()
            KikiLog.log("kiki stt: modelo recomendado cargado en \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        }
        isReady = true
    }

    public func transcribe(_ samples: [Float]) async throws -> String {
        let previous = activeTranscription
        let task = Task {
            _ = try? await previous?.value
            return try await self.doTranscribe(samples)
        }
        activeTranscription = task
        return try await task.value
    }

    private func doTranscribe(_ samples: [Float]) async throws -> String {
        guard let whisperKit else {
            throw DictationError.transcriptionFailed("el modelo todavía no está cargado")
        }
        // Spec §6: ES/EN como idiomas de primera clase. La auto-detección abierta
        // de Whisper (~100 idiomas) es poco fiable con dictados cortos — eligió
        // sueco para 2s de español. detectLangauge (sic: typo histórico de la API
        // de WhisperKit, mantenido como alias deprecado hasta 1.0.0 — ver
        // `detectLanguage` sin el typo como sucesor, confirmado en el checkout de
        // 1.0.0) solo devuelve el idioma greedy (su langProbs trae únicamente el
        // token muestreado, no una distribución), así que la restricción es:
        // inglés solo si Whisper lo detectó explícitamente; cualquier otra cosa
        // se trata como español (idioma primario del producto en Fase 1).
        let (detected, _) = try await whisperKit.detectLangauge(audioArray: samples)
        let language = detected == "en" ? "en" : "es"
        KikiLog.log("kiki stt: idioma \(language) (whisper detectó \(detected))")
        var options = DecodingOptions()
        options.task = .transcribe
        options.language = language
        options.detectLanguage = false
        KikiLog.log("kiki stt: inferencia iniciada (\(samples.count) muestras) — la primera tras arrancar puede tardar por compilación ANE/CoreML")
        let started = Date()
        let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
        KikiLog.log("kiki stt: inferencia completada en \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        return results.map(\.text).joined(separator: " ")
    }
}
