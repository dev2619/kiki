import Foundation

func withThrowingTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw DictationError.transcriptionFailed("refinado excedió \(seconds)s")
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

/// Máquina de estados del loop de dictado: idle → recording → processing → idle.
/// Los colaboradores se inyectan por protocolo para poder testear con mocks.
@MainActor
public final class DictationController {
    public private(set) var state: DictationState = .idle
    public weak var delegate: DictationControllerDelegate?

    private let recorder: AudioRecording
    private let transcriber: Transcribing
    private let inserter: TextInserting
    private let minimumSamples: Int
    private let refiner: Refining?
    private let context: ContextProviding?
    private let refineTimeout: TimeInterval
    private let sampleRate: Double
    private let snippets: SnippetExpanding?
    private let history: HistoryRecording?
    private let minRefinableLength: Int
    private let languageProvider: LanguageDetecting?
    private let translateEnabled: () -> Bool
    private let refineEnabled: () -> Bool
    /// F1 Task 3 (modo live): consultado SOLO en `hotkeyPressed` — la
    /// decisión se captura en `activeLiveSession` para ese dictado completo,
    /// ver doc ahí.
    private let liveEnabled: () -> Bool
    /// Factory en vez de un `LiveTranscriptionCoordinator` ya construido: así
    /// el modo batch (el caso común, `liveEnabled` en `false`) nunca paga el
    /// costo de instanciar un coordinator que no va a usar. El controller
    /// invoca la factory una vez por dictado live, al `hotkeyPressed`.
    private let liveCoordinatorFactory: (() -> LiveTranscriptionCoordinator?)?
    /// Coordinator del dictado live EN CURSO, o `nil` en modo batch. Se fija
    /// en `hotkeyPressed` (capturando `liveEnabled()` en ESE instante) y se
    /// limpia a `nil` al terminar (`hotkeyReleased`) o cancelar (`cancel()`).
    /// Consultarlo en vez de releer `liveEnabled()` en `hotkeyReleased`/
    /// `cancel()` es lo que garantiza que un toggle de Ajustes a mitad de un
    /// dictado no le cambie el flujo al dictado ya en curso.
    private var activeLiveSession: LiveTranscriptionCoordinator?

    public init(
        recorder: AudioRecording,
        transcriber: Transcribing,
        inserter: TextInserting,
        minimumDuration: TimeInterval = 0.3,
        sampleRate: Double = 16_000,
        refiner: Refining? = nil,
        context: ContextProviding? = nil,
        refineTimeout: TimeInterval = 5,
        snippets: SnippetExpanding? = nil,
        history: HistoryRecording? = nil,
        minRefinableLength: Int = 25,
        languageProvider: LanguageDetecting? = nil,
        translateEnabled: @escaping () -> Bool = { false },
        refineEnabled: @escaping () -> Bool = { true },
        liveEnabled: @escaping () -> Bool = { false },
        liveCoordinatorFactory: (() -> LiveTranscriptionCoordinator?)? = nil
    ) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.inserter = inserter
        self.minimumSamples = Int(minimumDuration * sampleRate)
        self.refiner = refiner
        self.context = context
        self.refineTimeout = refineTimeout
        self.sampleRate = sampleRate
        self.snippets = snippets
        self.history = history
        self.minRefinableLength = minRefinableLength
        self.languageProvider = languageProvider
        self.translateEnabled = translateEnabled
        self.refineEnabled = refineEnabled
        self.liveEnabled = liveEnabled
        self.liveCoordinatorFactory = liveCoordinatorFactory
    }

    public func hotkeyPressed() {
        guard state == .idle else { return }
        do {
            try recorder.start()
            // Captura la decisión live PARA ESTE DICTADO — ver doc de
            // `activeLiveSession`. Se evalúa `liveEnabled()` una sola vez
            // acá; `hotkeyReleased`/`cancel()` consultan `activeLiveSession`,
            // nunca vuelven a leer `liveEnabled()`.
            if liveEnabled(), let coordinator = liveCoordinatorFactory?() {
                activeLiveSession = coordinator
                coordinator.onPartial = { [weak self] text in
                    self?.delegate?.dictationLivePartialDidChange(text)
                }
                coordinator.start()
            } else {
                activeLiveSession = nil
            }
            transition(to: .recording)
        } catch {
            delegate?.dictationDidFail(.audioUnavailable(String(describing: error)))
        }
    }

    /// Reenvía un chunk de audio al coordinator live activo (hop a MainActor
    /// lo hace el caller, típicamente `AppDelegate` desde `recorder.onChunk`).
    /// No-op en modo batch (`activeLiveSession == nil`).
    public func liveChunk(_ chunk: [Float]) {
        activeLiveSession?.append(chunk)
    }

    public func hotkeyReleased() async {
        guard state == .recording else { return }
        let samples = recorder.stop()
        if let liveSession = activeLiveSession {
            // Tap accidental (mismo umbral que batch): sin esto, el pase final
            // de Whisper sobre <0.3s de audio es fuente conocida de alucinaciones
            // ("Gracias.") que SE INSERTARÍAN.
            guard samples.count >= minimumSamples else {
                activeLiveSession = nil
                liveSession.cancel()
                delegate?.dictationLivePartialDidChange(nil)
                transition(to: .idle)
                return
            }
            activeLiveSession = nil
            // Limpia la burbuja ANTES de fijar `.processing` — mismo orden
            // que `cancel()`, evita que la última pill quede pegada mientras
            // corre el pase final.
            delegate?.dictationLivePartialDidChange(nil)
            transition(to: .processing)
            // El coordinator YA tiene todos los chunks (via `liveChunk`) — el
            // pase final de `finish()` es la única autoridad de transcripción
            // para un dictado live; las muestras del recorder NO se
            // re-transcriben, solo se usan para `audioSeconds` de historial.
            let final = await liveSession.finish()
            let audioSeconds = Double(samples.count) / sampleRate
            let language = "es" // bypassEnhancement ignora language; se evita el await muerto.
            await processTranscriptContent(final, audioSeconds: audioSeconds, language: language, bypassEnhancement: true)
            return
        }
        guard samples.count >= minimumSamples else {
            transition(to: .idle) // tap accidental
            return
        }
        await transcribeAndProcess(samples)
    }

    public func process(samples: [Float]) async {
        guard state == .idle else { return }
        guard samples.count >= minimumSamples else {
            return // tap accidental
        }
        await transcribeAndProcess(samples)
    }

    /// Entrada live de manos-libres (F1 Task 3): transcribe en batch las
    /// muestras entregadas (idéntico a `process(samples:)`) pero SALTA
    /// refinado/traducción — los parciales de la sesión wake son
    /// display-only y los pinta `AppDelegate` directo con su propio
    /// coordinator (F1 Task 5), este método solo participa en la ENTREGA
    /// final.
    public func processLive(samples: [Float]) async {
        guard state == .idle else { return }
        guard samples.count >= minimumSamples else {
            return // tap accidental
        }
        await transcribeAndProcess(samples, bypassEnhancement: true)
    }

    private func transcribeAndProcess(_ samples: [Float], bypassEnhancement: Bool = false) async {
        transition(to: .processing)
        do {
            let audioSeconds = Double(samples.count) / sampleRate
            KikiLog.log("kiki core: transcribiendo \(samples.count) muestras (\(String(format: "%.1f", audioSeconds))s de audio)")
            let started = Date()
            let text = try await transcriber.transcribe(samples)
            KikiLog.log("kiki core: transcripción lista en \(String(format: "%.2f", Date().timeIntervalSince(started)))s — \(text.count) chars: \"\(text)\"")
            let language = await languageProvider?.detectedLanguage() ?? "es"
            await processTranscriptContent(text, audioSeconds: audioSeconds, language: language, bypassEnhancement: bypassEnhancement)
        } catch let error as DictationError {
            transition(to: .idle)
            delegate?.dictationDidFail(error)
        } catch {
            transition(to: .idle)
            delegate?.dictationDidFail(.transcriptionFailed(String(describing: error)))
        }
    }

    /// - Parameter language: Idioma detectado ("es"/"en") por la transcripción
    ///   que produjo `text`. Cuando el llamador lo conoce (path "mismo aliento"
    ///   de WakeListener, que transcribió el texto él mismo y capturó el
    ///   idioma en la MISMA unidad serializada), DEBE pasarlo — así este método
    ///   NUNCA hace una lectura desconectada del `languageProvider`, que en ese
    ///   path sufría una TOCTOU: el listener sigue `.listening` (tap vivo) por
    ///   varios saltos de Task antes de `stop()`, así que un segmento de cola
    ///   podía re-ejecutar `transcribe()` y sobrescribir `lastDetectedLanguage`
    ///   antes de esta lectura → idioma equivocado. Con `nil` (llamadores
    ///   públicos/otros) cae a la lectura del provider, comportamiento previo.
    /// - Parameter bypassEnhancement: F1 Task 5 (manos-libres, mismo aliento
    ///   con modo live activo). `false` por defecto — comportamiento previo
    ///   sin cambios (refina/traduce como siempre). `true` salta refinado y
    ///   traducción exactamente igual que `processLive`/`hotkeyReleased` en
    ///   modo live: el texto entregado en el mismo aliento por `WakeListener`
    ///   ya es lo que el usuario ve/dijo, sin pase de IA — ver
    ///   `AppDelegate.wakeListenerDidCaptureSameBreath`.
    public func processTranscript(_ text: String, language: String? = nil, bypassEnhancement: Bool = false) async {
        guard state == .idle else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        transition(to: .processing)
        let resolvedLanguage: String
        if let language {
            resolvedLanguage = language
        } else {
            resolvedLanguage = await languageProvider?.detectedLanguage() ?? "es"
        }
        await processTranscriptContent(text, audioSeconds: 0, language: resolvedLanguage, bypassEnhancement: bypassEnhancement)
    }

    private func processTranscriptContent(_ text: String, audioSeconds: Double = 0, language: String = "es", bypassEnhancement: Bool = false) async {
        do {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                // Phase 3: Snippet expansion pre-pass
                if let template = snippets?.expand(trimmed) {
                    try inserter.insert(template)
                    KikiLog.log("kiki core: snippet expandido")
                    delegate?.dictationDidInsert()
                    let profile = context?.currentProfile() ?? .neutral
                    history?.record(HistoryRecord(rawText: trimmed, finalText: template, profile: profile, audioSeconds: audioSeconds))
                    transition(to: .idle)
                    return
                }

                // Phase 2: Refinement
                let final = await refineOrFallback(trimmed, language: language, bypassEnhancement: bypassEnhancement)
                try inserter.insert(final)
                KikiLog.log("kiki core: texto insertado")
                delegate?.dictationDidInsert()

                // History recording
                let profile = context?.currentProfile() ?? .neutral
                history?.record(HistoryRecord(rawText: trimmed, finalText: final, profile: profile, audioSeconds: audioSeconds))
            } else {
                KikiLog.log("kiki core: transcripción vacía, nada que insertar")
            }
            transition(to: .idle)
        } catch let error as DictationError {
            transition(to: .idle)
            delegate?.dictationDidFail(error)
        } catch {
            transition(to: .idle)
            delegate?.dictationDidFail(.transcriptionFailed(String(describing: error)))
        }
    }

    public func cancel() {
        guard state == .recording else { return }
        if let liveSession = activeLiveSession {
            liveSession.cancel()
            activeLiveSession = nil
            delegate?.dictationLivePartialDidChange(nil)
        }
        _ = recorder.stop()
        transition(to: .idle)
    }

    private func transition(to newState: DictationState) {
        state = newState
        KikiLog.log("kiki estado: \(newState)")
        delegate?.dictationStateDidChange(newState)
    }

    private func refineOrFallback(_ text: String, language: String, bypassEnhancement: Bool = false) async -> String {
        // Dictado live (F1 Task 3): el pase final del coordinator YA es el
        // texto entregado — refinado y traducción se saltan por completo,
        // sin mutar `refineEnabled`/`translateEnabled` (evita tocar estado
        // compartido con cualquier otro dictado concurrente/futuro).
        guard !bypassEnhancement else {
            KikiLog.log("kiki core: refinado/traducción salteados (dictado live)")
            return text
        }
        guard let refiner else { return text }
        let translate = translateEnabled()
        // Interruptor "Refinar dictado con IA" (Ajustes → General, default ON).
        // Apagado = el usuario quiere EXACTAMENTE las palabras de Whisper, sin
        // que la IA toque nada. La traducción es un modo aparte y opt-in: si
        // está activa, se traduce aunque el refinado esté apagado.
        guard translate || refineEnabled() else {
            KikiLog.log("kiki core: refinado desactivado — uso texto crudo")
            return text
        }
        // Fragmentos cortos no tienen muletillas que limpiar y el LLM
        // pequeño los daña — evidencia de campo: "Necesito que transcribas"
        // (24 chars) volvió "transcribas"; "¿Qué escuchas?" volvió
        // "¿Qué escucha?". Por debajo del umbral, el refinado hace más daño
        // que bien: se salta directo al texto crudo. NO aplica en modo
        // traducción: traducir "hola" es una operación válida incluso para
        // texto muy corto — el umbral es una heurística de limpieza de
        // muletillas, no de traducción.
        guard translate || text.count >= minRefinableLength else {
            KikiLog.log("kiki core: texto corto — sin refinado")
            return text
        }
        let profile = context?.currentProfile() ?? .neutral
        // Guardias de longitud (ver abajo): traducir cambia legítimamente el
        // largo del texto (es→en / en→es no son 1:1), así que en modo
        // traducción se relajan de 0.33x–2x(+40) a 0.3x–3.5x.
        let minRatio = translate ? 0.3 : (1.0 / 3.0)
        let maxRatio = translate ? 3.5 : 2.0
        let maxSlack = translate ? 0 : 40
        do {
            let started = Date()
            let refined = try await withThrowingTimeout(seconds: refineTimeout) {
                try await refiner.refine(text, profile: profile, language: language, translate: translate)
            }
            let trimmedRefined = refined.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedRefined.isEmpty else {
                KikiLog.log("kiki core: refinado vacío — uso texto crudo")
                return text
            }
            // Guardia de robustez: una limpieza legítima de muletillas acorta
            // el texto un ~10-40%, nunca a una tercera parte o menos. Un
            // refinado que colapsa por debajo de ese umbral es señal de que
            // el LLM respondió/interpretó el dictado en vez de reescribirlo
            // (p. ej. tratarlo como una pregunta y devolver una respuesta
            // corta tipo "Gracias.") — insertar eso sería peor que insertar
            // el texto crudo de Whisper.
            guard Double(trimmedRefined.count) >= Double(text.count) * minRatio else {
                KikiLog.log("kiki core: refinado sospechosamente corto — uso texto crudo")
                return text
            }
            // Guardia de robustez: un LLM que devuelve muchísimo más texto
            // del que se le pidió reescribir es señal de un prompt injection
            // (el texto dictado contenía instrucciones que el modelo obedeció
            // en vez de solo limpiar) o de una generación descarrilada. En
            // cualquier caso, insertar eso sería peor que insertar el texto
            // crudo de Whisper.
            guard Double(trimmedRefined.count) <= Double(text.count) * maxRatio + Double(maxSlack) else {
                KikiLog.log("kiki core: refinado sospechosamente largo — uso texto crudo")
                return text
            }
            // Guardia de fidelidad léxica (bugfix 2026-07-08): si el refinado
            // introduce demasiado vocabulario que el usuario no dijo, es
            // paráfrasis/alucinación (respondió el texto en vez de limpiarlo),
            // no una limpieza — insertar eso cambia las palabras del usuario.
            // No aplica al traducir (cambiar el vocabulario es el objetivo).
            if !translate && !RefineFidelity.isFaithful(original: text, refined: trimmedRefined) {
                KikiLog.log("kiki core: refinado infiel (vocabulario nuevo) — uso texto crudo")
                return text
            }
            KikiLog.log("kiki core: refinado (\(profile.rawValue), idioma \(language), traducir \(translate)) en \(String(format: "%.2f", Date().timeIntervalSince(started)))s: \"\(trimmedRefined)\"")
            return trimmedRefined
        } catch {
            KikiLog.log("kiki core: refinado falló (\(error)) — uso texto crudo")
            return text
        }
    }
}
