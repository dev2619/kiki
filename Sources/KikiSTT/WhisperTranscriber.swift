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
public actor WhisperTranscriber: Transcribing, LanguageDetecting {
    /// Identificador de modelo resuelto contra el repo HF `argmaxinc/whisperkit-coreml`
    /// (WhisperKit hace glob-match del `model:` contra las carpetas del repo;
    /// comportamiento verificado en 1.0.0, ver nota de versión en `Package.swift`).
    /// Variante CUANTIZADA (954MB) de large-v3 turbo: la full-precision (3GB)
    /// dispara compilaciones ANE de 10-30 min en la primera inferencia — inviable
    /// para dictado (confirmado 2026-07-06: ANECompilerService al 95% CPU con
    /// kiki bloqueado en "Procesando…").
    public static let preferredModel = "large-v3_turbo_954MB"

    /// Modelo dedicado a verificar la frase de activación (F4, spec
    /// 2026-07-11): tiny multilingüe ~75MB, inferencia ~100-200ms. Su texto
    /// decide si la frase se dijo; NUNCA se inserta como dictado (regla de
    /// calidad — ver WakeListener.applyMatch).
    public static let wakeModel = "openai_whisper-tiny"

    /// Presupuesto de tokens del "initial prompt" de Whisper (`DecodingOptions.promptTokens`,
    /// ver nota de API abajo). WhisperKit ya trunca internamente el prompt a
    /// `(maxTokenContext / 2) - 1` tokens (`TextDecoder.swift`), pero acotamos
    /// aparte a un valor bajo porque el glosario es una lista corta de
    /// términos, no texto narrativo: un prompt largo compite por contexto con
    /// la transcripción real y no aporta nada pasado cierto tamaño.
    private static let maxDictionaryPromptTokens = 120

    /// Frecuencia de muestreo fija del pipeline de audio de kiki (ver
    /// `AudioResampler.resampleTo16kMono`, `Sources/KikiAudio`). Se usa aquí
    /// solo para derivar `audioSeconds` a partir de `samples.count` en la
    /// gate de alucinaciones — no afecta a WhisperKit, que recibe las
    /// muestras crudas.
    private static let sampleRate: Double = 16_000

    // MARK: - Rechazo de alucinaciones (silencio/ruido)
    //
    // Bug de campo (2026-07-06): ~1.2s de silencio ambiente sin habla real →
    // Whisper "alucina" una de sus frases clásicas de training data
    // ("Thank you.", "Gracias.") con alta confianza aparente en el texto,
    // pero baja confianza real en sus propias métricas internas. WhisperKit
    // expone esas métricas por segmento en `TranscriptionSegment`
    // (`noSpeechProb`, `avgLogprob`; verificado en el checkout de WhisperKit,
    // `Sources/WhisperKit/Core/Models.swift:574-585`). Se usan como gate
    // primaria; una denylist de frases conocidas actúa como defensa
    // secundaria para el residual donde la confianza es ambigua.

    /// Umbral de `noSpeechProb` (probabilidad, calculada por el propio
    /// Whisper, de que el segmento NO contenga habla) a partir del cual la
    /// transcripción se descarta como alucinación de silencio. 0.6 se eligió
    /// por encima del punto medio (0.5) para no descartar habla real
    /// ambigua/con ruido de fondo, mientras sigue cubriendo el caso de campo
    /// (silencio puro produce noSpeechProb típicamente >0.7-0.9).
    static let noSpeechProbThreshold: Float = 0.6

    /// Umbral de `avgLogprob` (log-probabilidad promedio de los tokens
    /// generados) por debajo del cual el texto se considera de confianza tan
    /// baja que es más probable que sea una alucinación que habla real.
    /// -1.0 es el mismo valor de referencia que usa el propio whisper.cpp/
    /// openai-whisper como `logprob_threshold` para decidir si reintentar la
    /// decodificación por sospecha de mala transcripción.
    static let avgLogProbThreshold: Float = -1.0

    /// Duración de audio (segundos) por debajo de la cual, ADEMÁS de la gate
    /// de confianza, se consulta la denylist de frases-fantasma conocidas.
    /// Las frases de la lista pueden decirse de verdad, pero casi siempre
    /// como parte de un dictado más largo — en segmentos de audio cortos
    /// aisladas, son casi siempre eco del dataset de entrenamiento.
    static let hallucinationAudioSecondsThreshold: Double = 2.0

    /// Longitud máxima (caracteres, tras normalizar) del texto transcrito
    /// para que aplique la denylist de frases-fantasma. Mantiene a salvo
    /// dictados reales largos que contienen alguna de estas frases como
    /// substring incidental.
    static let hallucinationTextLengthThreshold: Int = 20

    /// Piso de `noSpeechProb` para que la denylist siquiera se consulte. La
    /// gate primaria (`noSpeechProbThreshold`, -1.0) descarta cuando la
    /// confianza es CLARAMENTE mala; la denylist es la zona GRIS entre "buena"
    /// y "mala". Sin este piso, la denylist descartaba habla real corta y
    /// confiada ("gracias"/"you"/"subscribe" a noSpeech 0.1, logProb -0.3, 1s)
    /// solo por ser corta — el mismísimo falso positivo que el fix debía
    /// evitar. 0.3 deja pasar intacto cualquier segmento con confianza clara
    /// de habla y solo abre la denylist cuando el modelo ya duda algo.
    static let denylistNoSpeechFloor: Float = 0.3

    /// Techo de `avgLogProb` (condición OR con `denylistNoSpeechFloor`) para
    /// abrir la denylist: log-prob por debajo de -0.4 indica que el modelo no
    /// está seguro del texto aunque el `noSpeechProb` sea bajo. Habla clara y
    /// confiada tiene avgLogProb por encima de este valor y nunca toca la
    /// denylist.
    static let denylistLogProbCeiling: Float = -0.4

    /// Frases clásicas que Whisper "alucina" sobre silencio o ruido
    /// ambiente — heredadas de subtítulos de YouTube en su dataset de
    /// entrenamiento (bug público y ampliamente documentado de Whisper).
    /// Defensa de última línea (denylist): solo se consulta cuando (a) la gate
    /// de confianza primaria no disparó, (b) audio y texto son cortos, Y
    /// (c) la confianza es AMBIGUA — no claramente habla real
    /// (`noSpeechProb >= denylistNoSpeechFloor` OR
    /// `avgLogProb <= denylistLogProbCeiling`). La condición (c) es la que
    /// evita descartar un "gracias"/"you"/"subscribe" dicho de verdad, corto
    /// y con confianza alta: sin ella la denylist se dispararía solo por
    /// longitud+duración. Así un "gracias" real (dentro de un dictado largo,
    /// o corto pero confiado) nunca se descarta.
    /// NOTA: "subtítulos realizados por la comunidad de amara.org" excede
    /// `hallucinationTextLengthThreshold`; para ese caso concreto la
    /// detección recae en la gate de confianza, no en esta lista.
    static let knownHallucinationPhrases: Set<String> = [
        "thank you",
        "thanks for watching",
        "gracias",
        "subtítulos realizados por la comunidad de amara.org",
        "subscribe",
        "you",
    ]

    /// Función pura: decide si una transcripción es probablemente una
    /// alucinación de silencio/ruido de Whisper. Combina la gate de
    /// confianza (primaria: `noSpeechProb`/`avgLogProb`) con la denylist de
    /// frases conocidas (secundaria: solo aplica con audio+texto cortos Y
    /// confianza ambigua — ver `knownHallucinationPhrases`).
    /// Extraída como función pura (sin `self`, sin WhisperKit) para poder
    /// testear la lógica de umbrales de forma determinista.
    static func isLikelyHallucination(
        text: String,
        noSpeechProb: Float,
        avgLogProb: Float,
        audioSeconds: Double
    ) -> Bool {
        // Gate primaria: confianza claramente mala → descarta sin más.
        if noSpeechProb >= noSpeechProbThreshold || avgLogProb <= avgLogProbThreshold {
            return true
        }

        // Denylist (secundaria): solo si audio y texto son cortos.
        guard audioSeconds <= hallucinationAudioSecondsThreshold else {
            return false
        }

        // Y solo si la confianza es AMBIGUA. Habla corta pero claramente
        // confiada (noSpeech bajo Y logProb alto) NUNCA toca la denylist.
        let confidenceAmbiguous =
            noSpeechProb >= denylistNoSpeechFloor || avgLogProb <= denylistLogProbCeiling
        guard confidenceAmbiguous else {
            return false
        }

        // Normaliza a lowercase y quita puntuación + espacios de los bordes.
        // Se recorta espacio ANTES y DESPUÉS de la puntuación: "Gracias. "
        // → quita el espacio final → quita el "." → queda "gracias" (sin el
        // orden doble, un espacio tras la puntuación quedaría colgando y la
        // comparación con la denylist fallaría).
        let normalized = text
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?¡¿"))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard normalized.count <= hallucinationTextLengthThreshold else {
            return false
        }

        return knownHallucinationPhrases.contains(normalized)
    }

    /// Función pura: agrega las métricas de confianza por-segmento de una
    /// transcripción a un único par `(noSpeechProb, avgLogProb)` para
    /// alimentar la gate de alucinaciones.
    ///
    /// Agregación ROBUSTA (no promedio): `min(noSpeechProb)` y
    /// `max(avgLogProb)`, es decir, se toma el segmento MÁS parecido a habla
    /// real. Un promedio simple rechazaría por error un dictado real
    /// multi-segmento con una pausa: p. ej. un segmento de habla
    /// (noSpeech 0.3) + un segmento de silencio intermedio (noSpeech 1.0)
    /// promedian 0.65 (> 0.6) y se descartaría todo el dictado. Con el mínimo,
    /// basta con que UN segmento tenga confianza clara de habla para conservar
    /// la transcripción; y el caso de campo (silencio puro → todos los
    /// segmentos con noSpeech alto) sigue disparando porque incluso el mínimo
    /// queda por encima del umbral.
    /// Devuelve `(0, 0)` para una lista vacía (no dispara ninguna gate).
    static func aggregateConfidence(
        noSpeechProbs: [Float],
        avgLogProbs: [Float]
    ) -> (noSpeechProb: Float, avgLogProb: Float) {
        let noSpeech = noSpeechProbs.min() ?? 0
        let logProb = avgLogProbs.max() ?? 0
        return (noSpeech, logProb)
    }

    private var whisperKit: WhisperKit?
    public private(set) var isReady = false
    /// Idioma detectado en la ÚLTIMA transcripción ("es"/"en"), fijado en
    /// `doTranscribe` antes de devolver el texto. Fase: fidelidad de idioma —
    /// evidencia de campo confirmó que Whisper detecta correctamente es/en
    /// pero ese dato se perdía: el refinador (Qwen 3B) solo recibía el texto
    /// + una instrucción en español de "conserva el idioma", que el modelo
    /// pequeño no respeta de forma confiable (mistraducía inglés a español
    /// roto, o alucinaba). Exponer esta propiedad permite que
    /// `DictationController` (vía `LanguageDetecting.detectedLanguage()`)
    /// fije el idioma de salida del refinado explícitamente en vez de
    /// dejarlo a la deriva. Default "es" antes de la primera transcripción.
    public private(set) var lastDetectedLanguage: String = "es"
    /// Enlace de la cadena de serialización, ver doc del tipo.
    private var activeTranscription: Task<String, Error>?
    /// Diccionario personal del usuario (Fase 3, Task 3/4). `weak` porque el
    /// dueño real del ciclo de vida es el store que lo provee (wiring en
    /// `Task 4`), no este actor.
    ///
    /// Contrato de threading: `terms()` se invoca desde el executor de este
    /// actor (un hilo de fondo arbitrario, nunca garantizado que sea el
    /// mismo entre llamadas), NO desde MainActor. El conformer de
    /// `DictionaryProviding` (el adapter de `KikiStore` que vendrá en
    /// Task 4) debe poder responder a `terms()` de forma segura desde
    /// cualquier hilo — p. ej. protegiendo su estado interno con un lock o
    /// usando una estructura de datos inmutable/copiada al leer.
    private weak var dictionaryProvider: DictionaryProviding?

    /// Variante de whisperkit-coreml que carga esta instancia. La app usa
    /// dos: el modelo principal de dictado (default) y el tiny del wake.
    /// `private(set)` (F3 Task 2): `switchModel` la actualiza tras conmutar
    /// con éxito; fuera de este actor solo se lee vía `currentModel`.
    private(set) var modelName: String

    public init(model: String = WhisperTranscriber.preferredModel) {
        self.modelName = model
    }

    /// Modelo whisperkit-coreml actualmente activo (el que sirve
    /// `transcribe`), tras la última carga o conmutación exitosa.
    public var currentModel: String { modelName }

    /// Inyecta (o quita, pasando `nil`) el proveedor del diccionario personal
    /// que se usará como initial prompt de Whisper. Es un método aislado al
    /// actor: los llamadores externos deben hacer `await transcriber.setDictionaryProvider(...)`.
    public func setDictionaryProvider(_ provider: DictionaryProviding?) {
        dictionaryProvider = provider
    }

    /// Conformidad a `LanguageDetecting`: reenvía `lastDetectedLanguage`. No
    /// puede ser esa misma propiedad (un protocolo no puede requerir un
    /// `func` con el nombre base de una propiedad almacenada del conformer —
    /// ver doc de `LanguageDetecting`).
    public func detectedLanguage() -> String {
        lastDetectedLanguage
    }

    /// Peso, dentro del progreso 0...1 de ESTA fase (Whisper), reservado a la
    /// descarga desde Hugging Face — el resto (0.15) se reparte entre
    /// prewarm y load, que WhisperKit no expone con granularidad de bytes o
    /// porcentaje, solo transiciones de `ModelState` (ver `loadModel`).
    /// 0.85 refleja que la descarga (~1GB por red) domina el tiempo total del
    /// primer arranque frente a la compilación ANE/CoreML del prewarm
    /// (segundos a un par de minutos en frío, pero acotado en comparación).
    private static let downloadPhaseWeight: Double = 0.85

    /// Carga (y si hace falta descarga) el modelo. Llamar una vez al arrancar.
    ///
    /// - Parameter progressHandler: reporta progreso 0...1 de ESTA fase
    ///   (Whisper) durante la descarga+prewarm+load. Puede dispararse desde
    ///   cualquier hilo (el callback de descarga de Hugging Face y el
    ///   `modelStateCallback` de WhisperKit no garantizan MainActor) — el
    ///   llamador (`AppDelegate.loadModelInBackground`) es responsable de
    ///   saltar a MainActor antes de tocar UI.
    public func prepare(progressHandler: (@Sendable (Double) -> Void)? = nil) async throws {
        let started = Date()
        do {
            whisperKit = try await loadModel(named: modelName, progressHandler: progressHandler)
            KikiLog.log("kiki stt: modelo cargado (\(modelName)) en \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        } catch {
            KikiLog.log("kiki stt: \(modelName) no disponible (\(error))")
            // F3 Task 2 (ronda de completion) — guard del verificador wake:
            // NI el hop de fallback a base NI el fallback genérico de abajo
            // deben aplicar cuando esta instancia es el verificador tiny del
            // wake (`Self.wakeModel`, ver `AppDelegate.wakeTranscriber`). Si
            // el tiny (~75MB) falla, cargar el base (954MB) o el "recomendado"
            // genérico de WhisperKit AQUÍ significaría mantener un SEGUNDO
            // modelo grande completo en RAM (junto al `transcriber` principal
            // que ya lo tiene) solo para verificar segmentos de ~0.5s de la
            // frase de activación — un desperdicio de memoria además de una
            // descarga pesada e inesperada para lo que se documenta como
            // carga "sin bloquear el arranque ni la UI" (ver
            // `AppDelegate.loadModelInBackground`). El diseño de fallback ya
            // existente en `AppDelegate` (sin verificador tiny →
            // `WakeListener` sigue verificando con el `transcriber` principal,
            // ver `wakeListener.setWakeVerifier`/catch de esa carga) es
            // estrictamente mejor: cero costo extra, mismo resultado
            // funcional. Por eso, para el wake, el error se propaga tal cual
            // sin intentar ningún hop.
            guard modelName != Self.wakeModel else {
                KikiLog.log("kiki stt: modelo wake (\(modelName)) no disponible; sin fallback a base ni al recomendado (evitar 1GB+ extra en RAM solo para el verificador) — AppDelegate sigue verificando con el transcriber principal")
                throw error
            }
            // F3 Task 2: si el modelo preferido (no-base) falló, intentar el
            // base ANTES del fallback genérico de abajo — cubre el caso en
            // que la preferencia SÍ está en catálogo pero su descarga/carga
            // falla en runtime (el resolver de `ModelPreference` ya cae al
            // base cuando la preferencia ni siquiera está en catálogo; este
            // hop cubre el residuo). `preferredModel` es la constante que el
            // assert de consistencia de `AppDelegate` mantiene igual a
            // `ModelCatalog.baseOption(for: .stt).id`, así que comparar
            // contra ella (en vez de importar KikiStore aquí) evita acoplar
            // este target a KikiStore solo por esto.
            if modelName != Self.preferredModel {
                KikiLog.log("kiki stt: intentando modelo base (\(Self.preferredModel))")
                do {
                    whisperKit = try await loadModel(named: Self.preferredModel, progressHandler: progressHandler)
                    modelName = Self.preferredModel
                    KikiLog.log("kiki stt: modelo base cargado en \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
                    isReady = true
                    return
                } catch {
                    KikiLog.log("kiki stt: modelo base \(Self.preferredModel) tampoco disponible (\(error)); usando modelo recomendado")
                }
            } else {
                KikiLog.log("kiki stt: usando modelo recomendado")
            }
            // Camino de fallback (recomendado remoto): WhisperKit no expone
            // progreso granular aquí tampoco (mismo límite de API, ver doc de
            // `loadModel`) y es una rama rara (solo si el variant
            // preferido y el base no resuelven) — se reporta 1.0 directo al
            // terminar para que la fase no quede pegada por debajo de 100%
            // en la UI.
            whisperKit = try await WhisperKit()
            progressHandler?(1.0)
            KikiLog.log("kiki stt: modelo recomendado cargado en \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        }
        isReady = true
    }

    /// F3 Task 2: carga `model` (descargando si hace falta, con prewarm) y
    /// conmuta al terminar. El modelo activo sigue sirviendo transcripciones
    /// mientras tanto (la conmutación es el último paso). Si falla, el
    /// activo queda intacto y el error se propaga al caller (la UI lo
    /// muestra; nada se persiste hasta el éxito). No toca `isReady`: sigue
    /// `true` con el modelo viejo hasta que la conmutación se completa.
    public func switchModel(to model: String, progressHandler: (@Sendable (Double) -> Void)? = nil) async throws {
        guard model != modelName else { return }
        let newKit = try await loadModel(named: model, progressHandler: progressHandler)
        whisperKit = newKit
        modelName = model
        KikiLog.log("kiki stt: modelo conmutado a \(model)")
    }

    /// Descarga (con progreso real de Hugging Face vía `WhisperKit.download`)
    /// y luego prewarm+load `model` (parametrizado — F3 Task 2: extraído de
    /// `prepare` para que también lo reuse `switchModel` y el fallback a
    /// base, no solo el modelo por-instancia), reportando progreso 0...1 de
    /// ESTA fase a `progressHandler`.
    ///
    /// Separado en dos pasos en vez del atajo de un solo
    /// `WhisperKit(WhisperKitConfig(model:prewarm:))` (lo que hacía este
    /// método antes de esta feature) porque `WhisperKitConfig` no expone
    /// ningún `progressCallback`/`modelStateCallback` en su init — verificado
    /// en el checkout, `Sources/WhisperKit/Core/Configurations.swift`. La
    /// única forma de observar progreso es:
    /// 1. Descargar aparte con `WhisperKit.download(variant:progressCallback:)`
    ///    (API estática, sí expone `ProgressCallback`) — nos da el `URL` ya
    ///    descargado.
    /// 2. Construir `WhisperKit` con `modelFolder:` apuntando ahí (salta la
    ///    descarga interna de `setupModels`, ver `WhisperKit.swift:314-316`)
    ///    y `prewarm: false, load: false` para que el init NO dispare
    ///    prewarm/load automáticamente.
    /// 3. Fijar `modelStateCallback` en la instancia YA construida (antes de
    ///    que exista, no hay dónde engancharlo) y solo ENTONCES llamar
    ///    `prewarmModels()`/`loadModels()` manualmente — así el callback
    ///    captura las transiciones `.prewarming → .prewarmed → .loading →
    ///    .loaded` (`ArgmaxCore/ModelState.swift`) de esta carga.
    private func loadModel(
        named model: String,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws -> WhisperKit {
        let modelFolder = try await WhisperKit.download(variant: model) { progress in
            progressHandler?(progress.fractionCompleted * Self.downloadPhaseWeight)
        }

        let kit = try await WhisperKit(WhisperKitConfig(
            model: model,
            modelFolder: modelFolder.path,
            prewarm: false,
            load: false))

        // Sin granularidad de bytes/porcentaje para prewarm+load: solo dos
        // saltos de fase (a mitad al terminar prewarm, a 1.0 al terminar
        // load) en vez de interpolar nada — más honesto que fingir progreso
        // continuo sobre una operación que no lo reporta.
        let prewarmLoadWeight = 1 - Self.downloadPhaseWeight
        kit.modelStateCallback = { _, newState in
            switch newState {
            case .prewarmed:
                progressHandler?(Self.downloadPhaseWeight + prewarmLoadWeight * 0.5)
            case .loaded:
                progressHandler?(1.0)
            default:
                break
            }
        }

        try await kit.prewarmModels()
        try await kit.loadModels()
        return kit
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
        // Snapshot local del kit vigente al ENTRAR a esta transcripción. Se
        // reusa (nunca se relee `self.whisperKit`) para toda la duración de
        // `doTranscribe`, incluida la codificación del prompt del diccionario
        // más abajo: hay un `await` (detectLangauge) entre esta línea y esa
        // codificación, y el actor permite reentrancia en ese punto — si
        // `switchModel` corriera en esa ventana y reemplazara `whisperKit`,
        // leer la propiedad de nuevo tokenizaría el prompt con el tokenizer
        // del modelo NUEVO mientras se decodifica con el kit VIEJO (bug de
        // campo detectado en revisión de Task 2). Pasar el snapshot como
        // parámetro a `dictionaryPromptTokens` elimina esa relectura.
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
        lastDetectedLanguage = language
        KikiLog.log("kiki stt: idioma \(language) (whisper detectó \(detected))")
        var options = DecodingOptions()
        options.task = .transcribe
        options.language = language
        options.detectLanguage = false
        // Fase 3, Task 3: diccionario personal como "initial prompt" de Whisper.
        // API real verificada en el checkout de WhisperKit 1.0
        // (`Sources/WhisperKit/Core/Configurations.swift` +
        // `Core/TextDecoder.swift::prepareDecoderInputs`):
        // `DecodingOptions.promptTokens: [Int]?` se antepone (con el token
        // especial `startOfPreviousToken`) a los tokens de prefill del
        // decoder — es exactamente el mecanismo de "initial prompt" de
        // Whisper (condiciona la decodificación sin generarse a sí mismo en
        // la salida). Requiere tokens ya codificados; se obtienen con
        // `whisperKit.tokenizer?.encode(text:)` (protocolo `WhisperTokenizer`,
        // `Core/Models.swift`).
        if let promptTokens = dictionaryPromptTokens(kit: whisperKit, language: language) {
            options.promptTokens = promptTokens
        }
        KikiLog.log("kiki stt: inferencia iniciada (\(samples.count) muestras) — la primera tras arrancar puede tardar por compilación ANE/CoreML")
        let started = Date()
        let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
        KikiLog.log("kiki stt: inferencia completada en \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        let text = results.map(\.text).joined(separator: " ")

        // Gate de alucinaciones (ver doc de `isLikelyHallucination` y de
        // `aggregateConfidence`): las métricas de confianza por-segmento se
        // agregan con min(noSpeechProb)/max(avgLogProb) — el segmento más
        // parecido a habla real — para que una pausa intermedia en un dictado
        // real multi-segmento no arrastre a rechazar todo el texto.
        let segments = results.flatMap(\.segments)
        let (noSpeechProb, avgLogProb) = Self.aggregateConfidence(
            noSpeechProbs: segments.map(\.noSpeechProb),
            avgLogProbs: segments.map(\.avgLogprob)
        )
        let audioSeconds = Double(samples.count) / Self.sampleRate
        if Self.isLikelyHallucination(
            text: text,
            noSpeechProb: noSpeechProb,
            avgLogProb: avgLogProb,
            audioSeconds: audioSeconds
        ) {
            KikiLog.log("kiki stt: transcripción descartada — probable alucinación (noSpeech \(String(format: "%.2f", noSpeechProb)), avgLogProb \(String(format: "%.2f", avgLogProb))): \"\(text)\"")
            return ""
        }

        return text
    }

    /// Construye los tokens del initial prompt a partir de `dictionaryProvider.terms()`,
    /// truncando la lista de términos (no el texto a mitad de palabra) para que el
    /// prompt tokenizado no supere `maxDictionaryPromptTokens`. Devuelve `nil` si no
    /// hay proveedor, no hay términos, el tokenizer todavía no está disponible, o ni
    /// siquiera el primer término entra en el presupuesto.
    ///
    /// Recibe `kit` como parámetro (snapshot tomado por el caller antes de
    /// cualquier `await`) en vez de releer `self.whisperKit`: ver nota de
    /// reentrancia en `doTranscribe`.
    private func dictionaryPromptTokens(kit: WhisperKit, language: String) -> [Int]? {
        guard let terms = dictionaryProvider?.terms(), !terms.isEmpty else { return nil }
        guard let tokenizer = kit.tokenizer else { return nil }

        let header = language == "en" ? "Dictionary: " : "Glosario: "
        guard let promptText = Self.packTerms(
            terms,
            header: header,
            budget: Self.maxDictionaryPromptTokens,
            encode: { tokenizer.encode(text: $0) }
        ) else {
            return nil
        }
        return tokenizer.encode(text: promptText)
    }

    /// Pure function to pack terms into a prompt text within a token budget.
    /// Packs whole terms (not partial) while staying within the budget; drops
    /// overflowing terms. Header is included in token count.
    /// - Returns: Final prompt text (header + packed terms joined by ", "), or nil
    ///   if no provider, empty terms, or even the first term overflows the budget.
    static func packTerms(
        _ terms: [String],
        header: String,
        budget: Int,
        encode: (String) -> [Int]
    ) -> String? {
        guard !terms.isEmpty else { return nil }

        var included: [String] = []
        for term in terms {
            let candidate = included + [term]
            let candidateText = header + candidate.joined(separator: ", ")
            guard encode(candidateText).count <= budget else {
                break
            }
            included = candidate
        }
        guard !included.isEmpty else { return nil }
        return header + included.joined(separator: ", ")
    }
}
