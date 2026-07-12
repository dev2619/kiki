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

    /// Identificador del modelo MLX que carga esta instancia (F3 Task 2 —
    /// mirror de `WhisperTranscriber.modelName`). Sin `switchModel` (ver
    /// análisis de sincronización en `prepare`/init doc), esta propiedad solo
    /// se reasigna dentro de `prepare()` — antes de que `isReady` sea `true`
    /// y por tanto antes de que ningún `refine()` pueda haberla leído — así
    /// que mutarla ahí no reintroduce la carrera que motivó no implementar
    /// `switchModel` todavía.
    private(set) var modelName: String

    /// Diccionario personal del usuario (Fase 3, Task 3/4).
    ///
    /// Contrato de threading: a diferencia de `WhisperTranscriber` (actor),
    /// `LLMRefiner` es una clase plana sin aislamiento — `refine()` corre en
    /// el executor concurrente donde `DictationController` (MainActor) la
    /// invoca dentro de `withThrowingTimeout`/`withThrowingTaskGroup`
    /// (`group.addTask { ... }` NO hereda MainActor), es decir, **fuera** de
    /// MainActor. Una `weak var` simple es segura aquí bajo el patrón real
    /// de uso: se fija UNA vez durante el wiring de arranque (antes de que
    /// exista ningún dictado en vuelo) y nunca se reasigna después — no hay
    /// escritura concurrente con las lecturas de `refine()`, así que no hace
    /// falta lock. Si ese patrón cambiara (p. ej. reinyectar el proveedor en
    /// caliente mientras hay refinamientos en curso), esto necesitaría un
    /// lock o pasar a un tipo `Sendable`/actor — igual que el conformer de
    /// `DictionaryProviding` en sí (el adapter de `KikiStore` en Task 4) debe
    /// poder responder `terms()` desde cualquier hilo, ver nota equivalente
    /// en `WhisperTranscriber`.
    private weak var dictionaryProvider: DictionaryProviding?

    /// - Parameter model: variante MLX a cargar (F3 Task 2 — mirror de
    ///   `WhisperTranscriber.init(model:)`); default `preferredModel`.
    public init(model: String = LLMRefiner.preferredModel) {
        self.modelName = model
    }

    /// Modelo MLX actualmente activo (el que sirve `refine`), tras la última
    /// carga exitosa. Mirror de `WhisperTranscriber.currentModel`.
    public var currentModel: String { modelName }

    /// Inyecta (o quita, pasando `nil`) el proveedor del diccionario personal
    /// que se agrega al system prompt de `RefinePrompt`. Ver nota de
    /// threading en la propiedad `dictionaryProvider`.
    public func setDictionaryProvider(_ provider: DictionaryProviding?) {
        dictionaryProvider = provider
    }

    /// Carga (y si hace falta descarga) el modelo. Llamar una vez al arrancar.
    ///
    /// - Parameter progressHandler: reporta progreso 0...1 de la descarga
    ///   desde Hugging Face. API real verificada en el checkout de
    ///   `mlx-swift-examples`: `ModelFactory.loadContainer(hub:configuration:progressHandler:)`
    ///   (`Libraries/MLXLMCommon/ModelFactory.swift`) ya acepta un
    ///   `@Sendable (Progress) -> Void` — a diferencia de WhisperKit, no hizo
    ///   falta ningún rodeo de dos pasos, solo pasar el parámetro que la
    ///   llamada anterior ignoraba. El progreso solo cubre la descarga
    ///   (`downloadModel` dentro de `LLMModelFactory._load`, ver
    ///   `Libraries/MLXLLM/LLMModelFactory.swift:455-461`); la carga de pesos
    ///   safetensors→MLX que sigue no reporta progreso adicional, por eso se
    ///   fuerza `progressHandler?(1.0)` al terminar (mismo patrón que el
    ///   fallback de `WhisperTranscriber.prepare`). Puede dispararse desde
    ///   cualquier hilo — el llamador salta a MainActor antes de tocar UI.
    ///
    /// F3 Task 2 — NO HAY `switchModel` todavía (análisis de sincronización,
    /// ver también el doc de `modelContainer`/`dictionaryProvider` arriba):
    /// `LLMRefiner` es una clase plana sin actor/lock/queue protegiendo
    /// `modelContainer`/`isReady` — el diseño actual es seguro únicamente
    /// porque son "write-once": `prepare()` los escribe UNA vez, antes de que
    /// `refine()` (que corre en un executor arbitrario, fuera de MainActor,
    /// ver doc de clase) pueda haberlos leído, y nunca se reescriben después.
    /// Un `switchModel` real reescribiría `modelContainer` en caliente
    /// mientras un `refine()` en vuelo podría estar leyéndolo — eso rompe la
    /// invariante write-once que hace segura la ausencia de lock hoy, y el
    /// archivo no tiene ningún primitivo existente (queue/lock/MainActor)
    /// para reusar y hacer esa conmutación segura. Introducir uno nuevo
    /// (p. ej. un `NSLock` ad hoc) no sería "seguir el patrón del archivo"
    /// sino inventar uno — decisión de diseño que un humano debería revisar,
    /// no asumir en silencio. Por eso este paso solo entrega el refactor
    /// prepare→loadModel + `init(model:)` + `currentModel`; `switchModel` en
    /// `LLMRefiner` queda BLOQUEADO — ver reporte de Task 2 para el análisis
    /// completo y las opciones (actor, lock dedicado, o confinar todo a un
    /// executor serial) que Task 3 debería decidir antes de exponer swap de
    /// modelo del refinador en la UI.
    public func prepare(progressHandler: (@Sendable (Double) -> Void)? = nil) async throws {
        let started = Date()
        do {
            modelContainer = try await loadModel(named: modelName, progressHandler: progressHandler)
            KikiLog.log("kiki refine: modelo cargado (\(modelName)) en \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        } catch {
            KikiLog.log("kiki refine: \(modelName) no disponible (\(error))")
            // F3 Task 2: mismo hop de fallback-a-base que `WhisperTranscriber.prepare`
            // — si el modelo preferido (no-base) falló, intentar el base ANTES
            // del fallback genérico. `preferredModel` es la constante que el
            // assert de consistencia de `AppDelegate` mantiene igual a
            // `ModelCatalog.baseOption(for: .refine).id`.
            guard modelName != Self.preferredModel else {
                throw error
            }
            KikiLog.log("kiki refine: intentando modelo base (\(Self.preferredModel))")
            modelContainer = try await loadModel(named: Self.preferredModel, progressHandler: progressHandler)
            modelName = Self.preferredModel
            KikiLog.log("kiki refine: modelo base cargado en \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        }
        isReady = true

        // Límite de cache de buffers de MLX: se fija una sola vez al cargar el
        // modelo (no en cada refine()) — kiki es una app de fondo de larga
        // duración (no un proceso CLI de un solo uso), así que el límite debe
        // regir para todo el proceso, no resetearse por dictado. 20MB es
        // generoso para las activaciones de una generación de texto corto
        // (≤512 tokens).
        GPU.set(cacheLimit: 20 * 1024 * 1024)
    }

    /// Descarga (con progreso real vía `LLMModelFactory.loadContainer`) y
    /// carga `model` (parametrizado — F3 Task 2: extraído de `prepare` para
    /// reusarlo en el fallback a base). Ver doc de `prepare` para el detalle
    /// de la API de progreso y por qué no hay `switchModel` todavía que
    /// también lo reuse.
    private func loadModel(
        named model: String,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws -> ModelContainer {
        let configuration = ModelConfiguration(id: model)
        let container = try await LLMModelFactory.shared.loadContainer(
            configuration: configuration,
            progressHandler: { progress in
                progressHandler?(progress.fractionCompleted)
            })
        progressHandler?(1.0)
        return container
    }

    public func refine(
        _ text: String, profile: AppProfile, language: String = "es", translate: Bool = false
    ) async throws -> String {
        guard isReady, let modelContainer else {
            throw DictationError.transcriptionFailed("LLM no cargado")
        }

        let dictionaryTerms = dictionaryProvider?.terms() ?? []
        let (system, user) = RefinePrompt.messages(
            for: text, profile: profile, dictionaryTerms: dictionaryTerms, language: language, translate: translate)
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
            // temperature: 0 → decodificación greedy (determinística). El
            // refinado es una tarea de reescritura fiel al texto dictado, no
            // de generación creativa: queremos que el modelo elija siempre
            // el token más probable en vez de muestrear, lo que además
            // reduce la varianza entre corridas (de-flakea los tests
            // gated de este archivo).
            let parameters = GenerateParameters(maxTokens: maxTokens, temperature: 0)

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
