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

    /// Frases clásicas que Whisper "alucina" sobre silencio o ruido
    /// ambiente — heredadas de subtítulos de YouTube en su dataset de
    /// entrenamiento (bug público y ampliamente documentado de Whisper).
    /// Defensa de última línea (denylist): solo se consulta cuando la gate
    /// de confianza no disparó Y tanto el audio como el texto son cortos —
    /// así un "gracias" real dentro de un dictado largo nunca se descarta.
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
    /// frases conocidas (secundaria: solo aplica con audio+texto cortos).
    /// Extraída como función pura (sin `self`, sin WhisperKit) para poder
    /// testear la lógica de umbrales de forma determinista.
    static func isLikelyHallucination(
        text: String,
        noSpeechProb: Float,
        avgLogProb: Float,
        audioSeconds: Double
    ) -> Bool {
        if noSpeechProb >= noSpeechProbThreshold || avgLogProb <= avgLogProbThreshold {
            return true
        }

        let normalized = text
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?¡¿"))

        guard normalized.count <= hallucinationTextLengthThreshold,
              audioSeconds <= hallucinationAudioSecondsThreshold
        else {
            return false
        }

        return knownHallucinationPhrases.contains(normalized)
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

    public init() {}

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
        if let promptTokens = dictionaryPromptTokens(language: language) {
            options.promptTokens = promptTokens
        }
        KikiLog.log("kiki stt: inferencia iniciada (\(samples.count) muestras) — la primera tras arrancar puede tardar por compilación ANE/CoreML")
        let started = Date()
        let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
        KikiLog.log("kiki stt: inferencia completada en \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        let text = results.map(\.text).joined(separator: " ")

        // Gate de alucinaciones (ver doc de `isLikelyHallucination`): se
        // promedian las métricas de confianza de todos los segmentos de
        // todos los resultados (normalmente uno solo por llamada) porque un
        // único segmento de baja confianza dentro de un dictado largo no
        // debe descartar el resto del texto real.
        let segments = results.flatMap(\.segments)
        let avgNoSpeechProb = segments.isEmpty ? 0 : segments.map(\.noSpeechProb).reduce(0, +) / Float(segments.count)
        let avgLogProb = segments.isEmpty ? 0 : segments.map(\.avgLogprob).reduce(0, +) / Float(segments.count)
        let audioSeconds = Double(samples.count) / Self.sampleRate
        if Self.isLikelyHallucination(
            text: text,
            noSpeechProb: avgNoSpeechProb,
            avgLogProb: avgLogProb,
            audioSeconds: audioSeconds
        ) {
            KikiLog.log("kiki stt: transcripción descartada — probable alucinación (noSpeech \(String(format: "%.2f", avgNoSpeechProb)), avgLogProb \(String(format: "%.2f", avgLogProb))): \"\(text)\"")
            return ""
        }

        return text
    }

    /// Construye los tokens del initial prompt a partir de `dictionaryProvider.terms()`,
    /// truncando la lista de términos (no el texto a mitad de palabra) para que el
    /// prompt tokenizado no supere `maxDictionaryPromptTokens`. Devuelve `nil` si no
    /// hay proveedor, no hay términos, el tokenizer todavía no está disponible, o ni
    /// siquiera el primer término entra en el presupuesto.
    private func dictionaryPromptTokens(language: String) -> [Int]? {
        guard let terms = dictionaryProvider?.terms(), !terms.isEmpty else { return nil }
        guard let tokenizer = whisperKit?.tokenizer else { return nil }

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
