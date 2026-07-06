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
/// MLXLMCommon) resuelto en 2.25.9 contra `mlx-swift` 0.25.6.
///
/// Nota de cancelación (importante — no volver a `ChatSession`/`respond(to:)`
/// sin releer esto): la API de alto nivel `ChatSession.respond(to:)`
/// (Libraries/MLXLMCommon/Streamlined.swift) llama internamente a
/// `MLXLMCommon.generate(input:context:iterator:) { _ in .more }` con un
/// callback fijo que nunca devuelve `.stop` — es decir, ChatSession no le da
/// al llamador ninguna forma de cortar la generación a mitad de camino. El
/// `withThrowingTimeout` de `DictationController` corre `refine()` en un
/// `Task` hijo dentro de un `withThrowingTaskGroup` y lo cancela si gana la
/// carrera el `Task.sleep` del timeout, pero esa cancelación es un no-op si
/// nadie dentro del loop de generación la revisa: el `Task` cancelado sigue
/// ejecutando hasta que `session.respond` retorna por su cuenta, y el "timeout
/// de 5s" nunca corta nada en la práctica.
///
/// Por eso aquí se usa el API de más bajo nivel (`context.processor.prepare`
/// + `TokenIterator` + `MLXLMCommon.generate(input:context:iterator:didGenerate:)`
/// — Libraries/MLXLMCommon/Evaluate.swift líneas ~597-631) directamente:  el
/// `for token in iterator` de esa función SÍ evalúa el callback `didGenerate`
/// después de cada token, así que basta con devolver `.stop` cuando
/// `Task.isCancelled` es true para que el loop corte tras el token en curso
/// (no instantáneo, pero acotado al tiempo de un solo forward pass, no al de
/// toda la generación).
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

        // Límite de cache de buffers de MLX: se fija una sola vez al cargar el
        // modelo (no en cada refine()) — kiki es una app de fondo de larga
        // duración (no un proceso CLI de un solo uso), así que el límite debe
        // regir para todo el proceso, no resetearse por dictado. 20MB es
        // generoso para las activaciones de una generación de texto corto
        // (≤512 tokens).
        GPU.set(cacheLimit: 20 * 1024 * 1024)

        KikiLog.log("kiki refine: modelo cargado (\(Self.preferredModel)) en \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
    }

    public func refine(_ text: String, profile: AppProfile) async throws -> String {
        guard isReady, let modelContainer else {
            throw DictationError.transcriptionFailed("LLM no cargado")
        }

        let (system, user) = RefinePrompt.messages(for: text, profile: profile)
        let messages: [Chat.Message] = [.system(system), .user(user)]

        let started = Date()
        let output = try await modelContainer.perform { context in
            let userInput = UserInput(chat: messages)
            let input = try await context.processor.prepare(input: userInput)

            // maxTokens escala con el tamaño real del prompt ya tokenizado
            // (`input.text.tokens.size`, el mismo valor que usa
            // `GenerateResult.promptTokenCount`) en vez de un tope fijo: un
            // dictado corto no debería poder disparar una generación de 512
            // tokens completa, y esto además acota el peor caso si la
            // cancelación tarda en propagarse (ver nota de clase arriba).
            let promptTokenCount = input.text.tokens.size
            let maxTokens = min(512, promptTokenCount * 2 + 64)
            let parameters = GenerateParameters(maxTokens: maxTokens, temperature: 0.3)

            let iterator = try TokenIterator(
                input: input, model: context.model, parameters: parameters)
            let result: GenerateResult = MLXLMCommon.generate(
                input: input, context: context, iterator: iterator
            ) { _ in
                Task.isCancelled ? .stop : .more
            }

            // Si nos cancelaron a mitad de generación, NO devolvemos el texto
            // a medias como si fuera un refinado válido: forzamos un throw
            // acá mismo para que el llamador (withThrowingTimeout en
            // DictationController) vea un error, exactamente igual que si la
            // generación hubiera fallado — así el controller cae al texto
            // crudo de Whisper en vez de insertar una oración cortada.
            try Task.checkCancellation()

            return result.output
        }
        KikiLog.log("kiki refine: generación completada en \(String(format: "%.1f", Date().timeIntervalSince(started)))s")

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
