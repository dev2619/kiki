import Foundation

/// Coordina transcripción en vivo mientras crece el buffer de audio (`append`).
///
/// ## Streaming (Paso 2, 2026-07-17)
/// Cuando el `transcriber` conforma `StreamingTranscribing` (el caso real —
/// `WhisperTranscriber`), cada pase re-transcribe el buffer COMPLETO pero solo
/// DECODIFICA desde el último segmento confirmado (`clipFromSeconds`), y recibe
/// texto incremental token-a-token durante la decodificación (`onProgress`) →
/// el "aparece mientras hablas". El resultado de cada pase se parte en:
/// - **confirmados**: todos menos los últimos `requiredSegmentsForConfirmation`
///   segmentos; ya no cambian, avanzan `lastConfirmedEnd`.
/// - **no-confirmados**: los últimos, que aún pueden reajustarse con más
///   contexto.
/// La burbuja muestra `confirmados + no-confirmados`. El **idioma se detecta una
/// sola vez** (primer pase con ≥1.5s, o el fijado por el usuario) y se BLOQUEA
/// para todos los pases y el pase final — esto mata el bug de idioma del diseño
/// anterior (que re-detectaba por ventana corta y forzaba es↔en mal).
///
/// El pase FINAL (`finish`) sigue siendo el `transcribe` estricto (con gates
/// anti-alucinación) sobre el buffer completo, con el idioma ya bloqueado — es
/// la única autoridad del texto que se inserta. Como el usuario ya vio el texto
/// en vivo, la espera se siente mínima.
///
/// ## Fallback por-ventana (mocks / transcribers sin streaming)
/// Un `transcriber` que NO conforma `StreamingTranscribing` cae al camino
/// previo: cada pase re-transcribe una ventana (cola) con `transcribeLenient`
/// si está disponible, o `transcribe`. Mantiene compatibles los tests
/// existentes del coordinator (sus mocks no hacen streaming).
///
/// ## Programación de pases
/// Un pase arranca cuando: (1) no hay pase en vuelo, (2) pasó `minPassInterval`
/// desde el arranque del último, y (3) llegó `minNewAudioSeconds` de audio nuevo.
///
/// ## Fence de generación
/// `cancel()` incrementa `generation`. Cada pase (y `finish`) captura el valor
/// antes de su primer `await` y lo re-verifica después — si `cancel()` corrió en
/// el medio, la entrega se descarta.
///
/// Privacidad: los logs nunca incluyen el texto, solo conteos de muestras.
@MainActor
public final class LiveTranscriptionCoordinator {
    private let transcriber: Transcribing
    private var streamingTranscriber: StreamingTranscribing? { transcriber as? StreamingTranscribing }
    private let minPassInterval: TimeInterval
    private let minNewAudioSamples: Int
    private let maxLivePassSamples: Int
    private let sampleRate: Double
    private let now: () -> Date

    /// Idioma fijado por el usuario ("es"/"en"), o `nil` = Auto (detectar una
    /// vez y bloquear). Ver `lockedLanguage`.
    private let forcedLanguage: String?
    /// Idioma BLOQUEADO para toda la sesión, una vez conocido (fijado por el
    /// usuario o detectado en el primer pase con suficiente audio). `nil` hasta
    /// entonces. Se pasa a todos los pases y al pase final.
    private var lockedLanguage: String?

    /// Idioma resuelto de la sesión ("es"/"en"), para que el caller refine el
    /// pase final en el idioma correcto. `nil` si nunca se llegó a fijar.
    public var detectedLanguage: String? { lockedLanguage }
    /// Mínimo de audio (muestras) antes de intentar detectar idioma en Auto —
    /// la detección de Whisper sobre <1.5s es poco fiable (elegía sueco/coreano
    /// para español corto).
    private let detectMinSamples: Int

    private var buffer: [Float] = []

    // Estado de streaming (confirmado / no-confirmado).
    private static let requiredSegmentsForConfirmation = 2
    private var confirmedSegments: [LiveSegment] = []
    private var lastConfirmedEnd: Double = 0

    private var generation = 0
    private var isCancelled = false
    private var isFinished = false
    private var isFinishing = false

    private var currentPassTask: Task<Void, Never>?
    private var lastPassStart: Date = .distantPast
    private var sampleCountAtLastPassStart = 0
    private var lastNonEmptyPartial = ""

    /// Parcial nuevo (texto completo acumulado hasta ahora). Solo con texto no vacío.
    public var onPartial: ((String) -> Void)?

    public init(
        transcriber: Transcribing,
        forcedLanguage: String? = nil,
        minPassInterval: TimeInterval = 0.6,
        minNewAudioSeconds: Double = 0.4,
        maxLivePassSeconds: Double = 8.0,
        sampleRate: Double = 16_000,
        now: @escaping () -> Date = Date.init
    ) {
        self.transcriber = transcriber
        self.forcedLanguage = forcedLanguage
        self.lockedLanguage = forcedLanguage
        self.minPassInterval = minPassInterval
        self.minNewAudioSamples = Int(minNewAudioSeconds * sampleRate)
        self.maxLivePassSamples = maxLivePassSeconds > 0 ? Int(maxLivePassSeconds * sampleRate) : 0
        self.sampleRate = sampleRate
        self.detectMinSamples = Int(1.5 * sampleRate)
        self.now = now
    }

    public func start() {
        KikiLog.log("kiki live: coordinador iniciado (streaming=\(streamingTranscriber != nil), idioma=\(forcedLanguage ?? "auto"))")
    }

    public func append(_ chunk: [Float]) {
        guard !isCancelled, !isFinished else { return }
        buffer.append(contentsOf: chunk)
        maybeStartPass()
    }

    /// Pase final estricto (con gates) sobre el buffer completo, con el idioma
    /// ya bloqueado. Espera el pase en vuelo si hay. Devuelve el texto final (o
    /// el último parcial si el final falla; "" si nada / cancelado).
    public func finish(fullAudio: [Float]? = nil) async -> String {
        guard !isCancelled else { return "" }
        guard !isFinished else { return lastNonEmptyPartial }
        isFinishing = true
        let capturedGeneration = generation
        if let inFlight = currentPassTask {
            await inFlight.value
        }
        guard !isFinished else { return lastNonEmptyPartial }
        guard capturedGeneration == generation else { return "" }
        isFinished = true
        let samples = fullAudio ?? buffer
        KikiLog.log("kiki live: pase final (\(samples.count) muestras, idioma \(lockedLanguage ?? "auto"))")
        do {
            // Idioma bloqueado → omite el pase de detección extra (más rápido) y
            // garantiza que el final use el MISMO idioma que se vio en vivo.
            let text = try await transcriber.transcribe(samples, knownLanguage: lockedLanguage)
            guard capturedGeneration == generation else { return "" }
            if !text.isEmpty { lastNonEmptyPartial = text }
            return text
        } catch {
            KikiLog.log("kiki live: pase final falló (\(type(of: error)))")
            guard capturedGeneration == generation else { return "" }
            return lastNonEmptyPartial
        }
    }

    public func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        generation += 1
        currentPassTask?.cancel()
        currentPassTask = nil
        KikiLog.log("kiki live: cancelado")
    }

    // MARK: - Programación

    private func maybeStartPass() {
        guard !isCancelled, !isFinished, !isFinishing, currentPassTask == nil else { return }
        let newAudio = buffer.count - sampleCountAtLastPassStart
        guard newAudio >= minNewAudioSamples else { return }
        guard now().timeIntervalSince(lastPassStart) >= minPassInterval else { return }
        // Streaming en Auto: no arrancar hasta tener suficiente audio para
        // detectar idioma de forma fiable.
        if streamingTranscriber != nil, lockedLanguage == nil, buffer.count < detectMinSamples {
            return
        }
        launchPass()
    }

    private func launchPass() {
        sampleCountAtLastPassStart = buffer.count
        lastPassStart = now()
        let capturedGeneration = generation

        if let streaming = streamingTranscriber {
            launchStreamingPass(streaming, generation: capturedGeneration)
        } else {
            launchWindowPass(generation: capturedGeneration)
        }
    }

    // MARK: - Camino streaming (Whisper real-time)

    private func launchStreamingPass(_ streaming: StreamingTranscribing, generation capturedGeneration: Int) {
        let samples = buffer
        let clipFrom = lastConfirmedEnd
        let language = lockedLanguage
        // Prefijo ya confirmado, para que los parciales token-a-token del tramo
        // en decodificación se muestren precedidos de lo ya asentado.
        let confirmedPrefix = confirmedText
        let onProgress: @Sendable (String) -> Void = { [weak self] partial in
            let trimmed = partial.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let combined = confirmedPrefix.isEmpty ? trimmed : confirmedPrefix + " " + trimmed
            Task { @MainActor in self?.emitPartial(combined, generation: capturedGeneration) }
        }
        KikiLog.log("kiki live: pase streaming (\(samples.count) muestras, desde \(String(format: "%.1f", clipFrom))s)")
        currentPassTask = Task { [weak self] in
            var result: LivePassResult?
            do {
                result = try await streaming.streamingPass(
                    samples, clipFromSeconds: clipFrom, language: language, onProgress: onProgress)
            } catch {
                KikiLog.log("kiki live: pase streaming falló (\(error))")
            }
            await self?.handleStreamingCompletion(generation: capturedGeneration, result: result)
        }
    }

    private func handleStreamingCompletion(generation completedGeneration: Int, result: LivePassResult?) {
        guard completedGeneration == generation else { return }
        currentPassTask = nil
        if let result {
            // Bloquea el idioma la primera vez que se conoce.
            if lockedLanguage == nil {
                lockedLanguage = result.language
                KikiLog.log("kiki live: idioma bloqueado a \(result.language)")
            }
            updateConfirmed(with: result.segments)
            let display = displayText
            if !display.isEmpty {
                lastNonEmptyPartial = display
                onPartial?(display)
            }
        }
        maybeStartPass()
    }

    /// Mueve los segmentos estables a `confirmedSegments` y avanza
    /// `lastConfirmedEnd`; deja los últimos como no-confirmados (mostrados pero
    /// aún ajustables). Mismo criterio que `AudioStreamTranscriber` de WhisperKit.
    private var unconfirmedSegments: [LiveSegment] = []
    private func updateConfirmed(with segments: [LiveSegment]) {
        let required = Self.requiredSegmentsForConfirmation
        if segments.count > required {
            let toConfirm = segments.count - required
            let newlyConfirmed = Array(segments.prefix(toConfirm))
            if let last = newlyConfirmed.last, last.end > lastConfirmedEnd {
                lastConfirmedEnd = last.end
                confirmedSegments.append(contentsOf: newlyConfirmed)
            }
            unconfirmedSegments = Array(segments.suffix(required))
        } else {
            unconfirmedSegments = segments
        }
    }

    private var confirmedText: String {
        joinSegments(confirmedSegments)
    }
    private var displayText: String {
        joinSegments(confirmedSegments + unconfirmedSegments)
    }
    private func joinSegments(_ segments: [LiveSegment]) -> String {
        segments.map(\.text).joined()
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func emitPartial(_ text: String, generation capturedGeneration: Int) {
        guard capturedGeneration == generation, !isCancelled, !isFinished else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lastNonEmptyPartial = trimmed
        onPartial?(trimmed)
    }

    // MARK: - Camino por-ventana (fallback, mocks de test)

    private func launchWindowPass(generation capturedGeneration: Int) {
        let samples: [Float]
        if maxLivePassSamples > 0 && buffer.count > maxLivePassSamples {
            samples = Array(buffer.suffix(maxLivePassSamples))
        } else {
            samples = buffer
        }
        let transcriber = self.transcriber
        KikiLog.log("kiki live: pase ventana (\(samples.count) muestras)")
        currentPassTask = Task { [weak self] in
            var result: String?
            do {
                if let lenient = transcriber as? LenientTranscribing {
                    result = try await lenient.transcribeLenient(samples)
                } else {
                    result = try await transcriber.transcribe(samples)
                }
            } catch {
                KikiLog.log("kiki live: pase ventana falló (\(error))")
            }
            await self?.handleWindowCompletion(generation: capturedGeneration, result: result)
        }
    }

    private func handleWindowCompletion(generation completedGeneration: Int, result: String?) {
        guard completedGeneration == generation else { return }
        currentPassTask = nil
        if let result, !result.isEmpty {
            lastNonEmptyPartial = result
            onPartial?(result)
        }
        maybeStartPass()
    }
}
