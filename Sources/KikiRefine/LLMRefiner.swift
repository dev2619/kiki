import Foundation
import KikiCore
import MLX
import MLXLLM
import MLXLMCommon

// MARK: - Metal build constraint (léase antes de tocar builds/CI de este target)
//
// El target `Cmlx` de `mlx-swift` compila shaders `.metal` a un `default.metallib`
// vía el sistema de build de Xcode (integración con el compilador Metal). El CLI
// puro de SwiftPM (`swift build` / `swift test`) NO tiene esa integración, así
// que `swift build` compila este target sin problema (no requiere Metal en build
// time) pero cualquier ejecución en runtime que toque GPU/MLXArray revienta con
// "Failed to load the default metallib" si el proceso host no vino de xcodebuild.
// Cita del README de mlx-swift: "the ultimate build has to be done via Xcode".
// Consecuencias prácticas:
//   - El target de la app (`Kiki`, que enlaza `KikiRefine`) debe compilarse con
//     xcodebuild, no con `swift build` — Task 5 cambia el Makefile para reflejar
//     esto.
//   - El test gated de este archivo (`LLMRefinerIntegrationTests`) requiere
//     xcodebuild, no `swift test`:
//     TEST_RUNNER_KIKI_LLM_TEST=1 xcodebuild test -scheme kiki \
//       -destination 'platform=macOS' \
//       -only-testing:KikiRefineTests/LLMRefinerIntegrationTests
//     (requiere el Metal Toolchain de Xcode instalado:
//     `xcodebuild -downloadComponent MetalToolchain`; variable de entorno vía el
//     prefijo `TEST_RUNNER_` porque xcodebuild no hereda el shell env al proceso
//     de test). Ver `.superpowers/sdd/task-2a4-report.md` para la investigación
//     completa y evidencia de test.
//
/// Refinamiento local con un LLM vía MLX (Apple Silicon / Metal). Descarga el
/// modelo de Hugging Face en el primer arranque y lo cachea en disco (igual
/// que `WhisperTranscriber`).
///
/// Nota de dependencias: se usa `mlx-swift-examples` (Libraries/MLXLLM +
/// MLXLMCommon) resuelto en 2.25.7 contra `mlx-swift` 0.25.6. La API de alto
/// nivel `ChatSession` (Libraries/MLXLMCommon/Streamlined.swift) reemplaza al
/// patrón de más bajo nivel (`context.processor.prepare` + `TokenIterator` +
/// `MLXLMCommon.generate` manual) que aparece en el sketch original de la
/// tarea — `ChatSession` ya encapsula ese mismo flujo y expone
/// `instructions:` (system prompt) + `respond(to:)` (user prompt), que es
/// exactamente la forma de `RefinePrompt.messages`. Se crea una `ChatSession`
/// nueva por cada `refine()` (no se reutiliza across-calls) porque el system
/// prompt cambia según `AppProfile` y cada dictado es independiente — no
/// queremos que el historial de un dictado contamine el siguiente.
public final class LLMRefiner: Refining {
    /// Qwen2.5 3B Instruct cuantizado a 4-bit — balance tamaño/calidad/latencia
    /// para refinamiento de texto corto en Apple Silicon.
    public static let preferredModel = "mlx-community/Qwen2.5-3B-Instruct-4bit"

    private var modelContainer: ModelContainer?
    public private(set) var isReady = false

    public init() {}

    /// Carga (y si hace falta descarga) el modelo. Llamar una vez al arrancar.
    public func prepare() async throws {
        let started = Date()
        let configuration = ModelConfiguration(id: Self.preferredModel)
        modelContainer = try await LLMModelFactory.shared.loadContainer(configuration: configuration)
        isReady = true
        KikiLog.log("kiki refine: modelo cargado (\(Self.preferredModel)) en \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
    }

    public func refine(_ text: String, profile: AppProfile) async throws -> String {
        guard isReady, let modelContainer else {
            throw DictationError.transcriptionFailed("LLM no cargado")
        }

        let (system, user) = RefinePrompt.messages(for: text, profile: profile)
        let parameters = GenerateParameters(maxTokens: 512, temperature: 0.3)
        let session = ChatSession(modelContainer, instructions: system, generateParameters: parameters)

        let started = Date()
        let result = try await session.respond(to: user)
        KikiLog.log("kiki refine: generación completada en \(String(format: "%.1f", Date().timeIntervalSince(started)))s")

        // Libera memoria cacheada de MLX tras generar: kiki es una app de
        // fondo de larga duración (no un proceso CLI de un solo uso como
        // llm-tool), así que no queremos que el cache de buffers de MLX
        // crezca sin límite entre dictados. 20MB es generoso para las
        // activaciones de una generación de texto corto (≤512 tokens).
        GPU.set(cacheLimit: 20 * 1024 * 1024)

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
