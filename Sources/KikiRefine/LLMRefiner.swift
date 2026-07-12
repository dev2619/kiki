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

    /// F3 Task 2 (ronda de completion) — CONFINAMIENTO A MAINACTOR, no lock
    /// ad hoc: `LLMRefiner` es una clase plana sin actor/queue propio, y
    /// `refine()` corre deliberadamente FUERA de MainActor (ver doc de clase
    /// arriba, nota de cancelación / `dictionaryProvider`). En vez de
    /// convertir la clase entera a `actor` (habría obligado a reverificar
    /// que el hop de actor no reintroduce el bug de cancelación que motivó
    /// el `TokenIterator` de bajo nivel) o inventar un `NSLock` ad hoc, la
    /// decisión (controller, ver `task-2-report.md` § Completion round) fue
    /// aislar SOLO el estado mutable (`modelContainer`/`modelName`) a
    /// `@MainActor` — el mismo patrón que ya usa el resto de la app para
    /// cruzar hacia/desde engines de fondo (ver `AppDelegate.loadModelInBackground`,
    /// que ya salta a MainActor antes de tocar UI). Todas las ESCRITURAS
    /// (`prepare()`, `switchModel()`) pasan por `await MainActor.run { ... }`
    /// explícito; toda LECTURA desde fuera de MainActor (`refine()`) también.
    /// El compilador however exige `await` en cualquier acceso — eso es
    /// justamente la garantía: no hay forma de tocar estas dos propiedades
    /// sin pasar por el mismo executor serial (MainActor), así que dos
    /// escrituras (p. ej. un `switchModel` en vuelo con `prepare()`, o dos
    /// `switchModel` concurrentes) quedan serializadas por MainActor mismo,
    /// sin condición de carrera sobre el propio storage.
    @MainActor private var modelContainer: ModelContainer?
    public private(set) var isReady = false

    /// Identificador del modelo MLX que carga esta instancia (F3 Task 2 —
    /// mirror de `WhisperTranscriber.modelName`). `@MainActor` por el mismo
    /// motivo que `modelContainer` arriba — ver esa doc. Se reasigna dentro
    /// de `prepare()` (fallback a base) y de `switchModel()` (conmutación
    /// exitosa), siempre vía `await MainActor.run { ... }`.
    @MainActor private(set) var modelName: String

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
    /// carga o conmutación exitosa. Mirror de `WhisperTranscriber.currentModel`
    /// — `@MainActor` porque lee `modelName` (ver doc ahí), así que los
    /// llamadores externos necesitan `await refiner.currentModel`, igual que
    /// con el actor de Whisper.
    @MainActor public var currentModel: String { modelName }

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
    /// F3 Task 2 (ronda de completion) — `switchModel` YA implementado, ver
    /// más abajo. `modelContainer`/`modelName` se leen/escriben SIEMPRE vía
    /// `await MainActor.run { ... }` (ver doc de `modelContainer` arriba) en
    /// vez de acceso directo, así que el orden de las dos ramas (éxito /
    /// fallback-a-base) queda serializado por MainActor sin importar en qué
    /// executor arbitrario esté corriendo esta función.
    public func prepare(progressHandler: (@Sendable (Double) -> Void)? = nil) async throws {
        let started = Date()
        let requestedModel = await MainActor.run { modelName }
        do {
            let container = try await loadModel(named: requestedModel, progressHandler: progressHandler)
            await MainActor.run { self.modelContainer = container }
            KikiLog.log("kiki refine: modelo cargado (\(requestedModel)) en \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        } catch {
            KikiLog.log("kiki refine: \(requestedModel) no disponible (\(error))")
            // F3 Task 2: mismo hop de fallback-a-base que `WhisperTranscriber.prepare`
            // — si el modelo preferido (no-base) falló, intentar el base ANTES
            // del fallback genérico. `preferredModel` es la constante que el
            // assert de consistencia de `AppDelegate` mantiene igual a
            // `ModelCatalog.baseOption(for: .refine).id`.
            guard requestedModel != Self.preferredModel else {
                throw error
            }
            KikiLog.log("kiki refine: intentando modelo base (\(Self.preferredModel))")
            let container = try await loadModel(named: Self.preferredModel, progressHandler: progressHandler)
            await MainActor.run {
                self.modelContainer = container
                self.modelName = Self.preferredModel
            }
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

    /// F3: carga `model` y conmuta al terminar. El refine en vuelo (si hay)
    /// conserva el contenedor anterior — snapshot al entrar; el siguiente
    /// refine usa el nuevo. Si la carga falla, el activo queda intacto y el
    /// error se propaga (la UI lo muestra; nada se persiste hasta el éxito).
    /// No-op si `model` ya es el modelo activo (no dispara una recarga
    /// idéntica). Nunca toca `isReady`: mirror exacto de
    /// `WhisperTranscriber.switchModel` (ver doc ahí), adaptado al
    /// confinamiento a `@MainActor` de `modelContainer`/`modelName` en vez de
    /// aislamiento de actor completo.
    public func switchModel(to model: String, progressHandler: (@Sendable (Double) -> Void)? = nil) async throws {
        let current = await MainActor.run { modelName }
        guard model != current else { return }
        let container = try await loadModel(named: model, progressHandler: progressHandler)
        await MainActor.run {
            self.modelContainer = container
            self.modelName = model
        }
        KikiLog.log("kiki refine: modelo conmutado a \(model)")
    }

    /// Descarga (con progreso real vía `LLMModelFactory.loadContainer`) y
    /// carga `model` (parametrizado — F3 Task 2: extraído de `prepare` para
    /// reusarlo en el fallback a base y también en `switchModel`). Ver doc de
    /// `prepare` para el detalle de la API de progreso.
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
        guard isReady else {
            throw DictationError.transcriptionFailed("LLM no cargado")
        }
        // F3 Task 2 (ronda de completion) — snapshot al entrar, igual que
        // `WhisperTranscriber.doTranscribe` con `whisperKit`: un
        // `switchModel` que conmute MIENTRAS este `refine()` está en vuelo
        // NO debe afectarlo — se lee `modelContainer` UNA sola vez aquí (vía
        // el hop a MainActor donde vive, ver doc de la propiedad) y de ahí en
        // adelante se usa solo la constante local `container`, nunca la
        // propiedad. Semántica intencional: este refine termina con el
        // contenedor viejo; el SIGUIENTE refine (que hará su propio snapshot)
        // ya ve el nuevo.
        guard let container = await MainActor.run(body: { self.modelContainer }) else {
            throw DictationError.transcriptionFailed("LLM no cargado")
        }

        let dictionaryTerms = dictionaryProvider?.terms() ?? []
        let (system, user) = RefinePrompt.messages(
            for: text, profile: profile, dictionaryTerms: dictionaryTerms, language: language, translate: translate)
        let messages: [Chat.Message] = [.system(system), .user(user)]

        let started = Date()
        let output = try await container.perform { context in
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
