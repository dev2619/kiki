import Foundation
import KikiCore
import WhisperKit

/// Transcripción local con WhisperKit (CoreML). El modelo se descarga
/// de Hugging Face en el primer arranque y queda cacheado en disco.
public final class WhisperTranscriber: Transcribing {
    /// Identificador de modelo resuelto contra el repo HF `argmaxinc/whisperkit-coreml`
    /// (WhisperKit 0.18 hace glob-match del `model:` contra las carpetas del repo).
    /// Variante CUANTIZADA (954MB) de large-v3 turbo: la full-precision (3GB)
    /// dispara compilaciones ANE de 10-30 min en la primera inferencia — inviable
    /// para dictado (confirmado 2026-07-06: ANECompilerService al 95% CPU con
    /// kiki bloqueado en "Procesando…").
    public static let preferredModel = "large-v3_turbo_954MB"

    private var whisperKit: WhisperKit?
    public private(set) var isReady = false

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
        guard let whisperKit else {
            throw DictationError.transcriptionFailed("el modelo todavía no está cargado")
        }
        // Spec §6: ES/EN como idiomas de primera clase. La auto-detección abierta
        // de Whisper (~100 idiomas) es poco fiable con dictados cortos — eligió
        // sueco para 2s de español. detectLangauge (sic: typo de WhisperKit 0.18)
        // solo devuelve el idioma greedy (su langProbs trae únicamente el token
        // muestreado, no una distribución), así que la restricción es: inglés
        // solo si Whisper lo detectó explícitamente; cualquier otra cosa se
        // trata como español (idioma primario del producto en Fase 1).
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
