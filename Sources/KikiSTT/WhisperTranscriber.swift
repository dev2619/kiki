import Foundation
import KikiCore
import WhisperKit

/// Transcripción local con WhisperKit (CoreML). El modelo se descarga
/// de Hugging Face en el primer arranque y queda cacheado en disco.
public final class WhisperTranscriber: Transcribing {
    /// Identificador de modelo resuelto contra el repo HF `argmaxinc/whisperkit-coreml`
    /// (WhisperKit 0.18 hace glob-match del `model:` contra las carpetas del repo).
    /// "large-v3_turbo" resuelve a la carpeta `openai_whisper-large-v3_turbo`
    /// (variante turbo de large-v3, sin cuantizar — disponible para chips M2/M3/M4).
    public static let preferredModel = "large-v3_turbo"

    private var whisperKit: WhisperKit?
    public private(set) var isReady = false

    public init() {}

    /// Carga (y si hace falta descarga) el modelo. Llamar una vez al arrancar.
    public func prepare() async throws {
        let started = Date()
        do {
            whisperKit = try await WhisperKit(WhisperKitConfig(model: Self.preferredModel))
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
        var options = DecodingOptions()
        options.task = .transcribe
        options.detectLanguage = true // ES/EN auto (spec §6)
        KikiLog.log("kiki stt: inferencia iniciada (\(samples.count) muestras) — la primera tras arrancar puede tardar por compilación ANE/CoreML")
        let started = Date()
        let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
        KikiLog.log("kiki stt: inferencia completada en \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        return results.map(\.text).joined(separator: " ")
    }
}
