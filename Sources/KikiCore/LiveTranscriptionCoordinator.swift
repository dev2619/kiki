import Foundation

/// Coordina transcripción en vivo con pases incrementales sobre un buffer de
/// audio que crece por `append`. Cada pase re-transcribe el buffer COMPLETO
/// acumulado hasta ese momento (no solo el chunk nuevo) — más simple y
/// correcto para Whisper que intentar fusionar transcripciones parciales de
/// ventanas distintas, a costa de más trabajo de CPU por pase a medida que
/// crece el audio (aceptable para las duraciones de dictado típicas de kiki).
///
/// ## Programación de pases
/// Un pase nuevo arranca (en `append`, o encadenado al completar el pase
/// anterior) cuando se cumplen tres condiciones: (1) no hay pase en vuelo,
/// (2) pasó al menos `minPassInterval` desde que arrancó el ÚLTIMO pase (no
/// desde que terminó — el intervalo limita la tasa de ARRANQUES, no la de
/// finalizaciones), y (3) llegó suficiente audio nuevo desde ese último
/// arranque (`minNewAudioSeconds` convertido a muestras vía `sampleRate`).
/// Al completar un pase, `maybeStartPass` se vuelve a evaluar — así una racha
/// de audio entrante nunca deja más de un pase en vuelo, pero tampoco se
/// queda esperando el próximo `append` si ya hay suficiente audio nuevo y el
/// intervalo lo permite.
///
/// ## Fence de generación
/// `cancel()` incrementa `generation` (y fija `isCancelled`). Cada pase (y
/// `finish()`) captura el valor vigente ANTES de su primer `await` y lo
/// vuelve a comparar después — si `cancel()` corrió en el medio, la entrega
/// (`onPartial` o el valor de retorno de `finish()`) se descarta. Mismo
/// patrón que `WakeListener` (`session`/`notificationEpoch`), simplificado a
/// un solo contador: acá no hay una contraparte "captura que siempre se
/// entrega" como `notifyCapture` — todo lo que produce este coordinador es
/// transcripción intermedia/final descartable sin pérdida real, porque el
/// buffer de audio crudo sigue disponible mientras no se cancele.
///
/// ## Alucinaciones vacías
/// Un pase que devuelve `""` (Whisper "alucina" silencio en un buffer que en
/// realidad tiene contenido, típicamente al final de una ventana corta) NO
/// debe pisar un parcial previo no vacío ya mostrado en la burbuja HUD — eso
/// se vería como un parpadeo a vacío y de vuelta. `onPartial` simplemente no
/// se dispara para resultados vacíos; el último texto no vacío entregado
/// sigue siendo lo que el usuario ve hasta el próximo pase con contenido
/// real (o el pase final de `finish()`).
///
/// Privacidad: los logs de esta clase nunca incluyen el contenido
/// transcripto, solo conteos de muestras — igual que el resto del pipeline
/// (`DictationController`, `WakeListener`).
///
/// ## Gates estrictas vs. lenientes (F1 fix 2026-07-12)
/// Los pases INTERMEDIOS (`launchPass`) llaman `transcribeLenient` (sin gates
/// anti-alucinación, ver `LenientTranscribing`) cuando el `transcriber`
/// inyectado la expone — su resultado solo pinta la burbuja HUD y nunca se
/// inserta, así que no necesita la protección anti-alucinación de
/// `WhisperTranscriber`, que en cambio estaba dejando la burbuja en blanco
/// para la mayoría de dictados cortos de campo (buffers <2s, denylist de
/// texto <20 chars). El pase FINAL (`finish()`) sigue llamando siempre al
/// `transcribe` estricto (con gates): su resultado sí puede insertarse. Un
/// `transcriber` que no conforma `LenientTranscribing` (mocks de tests
/// existentes, u otro `Transcribing` futuro) cae siempre al `transcribe`
/// estricto en ambos casos — comportamiento idéntico al de antes de este fix.
@MainActor
public final class LiveTranscriptionCoordinator {
    private let transcriber: Transcribing
    private let minPassInterval: TimeInterval
    private let minNewAudioSamples: Int
    /// Tope de muestras que un pase INTERMEDIO (preview de la nube)
    /// transcribe: solo la cola más reciente del buffer. `0` = sin tope
    /// (buffer completo, comportamiento previo). Motivo (fix 2026-07-16,
    /// dictados largos): re-transcribir el buffer entero en cada pase es
    /// O(n) y en dictados largos cada pase tarda tanto que la nube se
    /// congela y `finish()` espera decenas de segundos al pase en vuelo
    /// (visto en kiki.log: 36s de gap, 44s totales para 19s de audio).
    /// Acotar los pases intermedios a los últimos ~N s los mantiene rápidos
    /// SIEMPRE (preview rodante del final, que es lo que se ve al dictar);
    /// el pase FINAL de `finish()` sigue usando el buffer COMPLETO, así el
    /// texto insertado nunca se recorta. Dictados cortos (< N s) no cambian:
    /// la cola ES todo el buffer.
    private let maxLivePassSamples: Int
    private let now: () -> Date

    /// Buffer completo de audio acumulado desde `append`. Cada pase captura
    /// una copia (`[Float]` es un value type) al momento de arrancar — los
    /// `append` posteriores no afectan un pase ya en vuelo, solo alimentan
    /// el siguiente.
    private var buffer: [Float] = []

    /// Bumped por `cancel()`; ver doc de clase "Fence de generación".
    private var generation = 0
    /// `true` tras `cancel()`: bloquea permanentemente nuevos pases, nuevas
    /// entregas de `onPartial`, y el pase final de `finish()`.
    private var isCancelled = false
    /// `true` tras el primer `finish()` completado — evita un segundo pase
    /// final si algún llamador invoca `finish()` más de una vez.
    private var isFinished = false
    /// `true` desde el momento en que `finish()` arranca (ANTES de esperar
    /// un pase en vuelo), hasta que termina. Bloquea únicamente el
    /// ENCADENAMIENTO de nuevos pases (`maybeStartPass`, incluido el que
    /// dispara `handlePassCompletion` del pase que `finish()` está
    /// esperando) — `append` sigue acumulando buffer con total normalidad,
    /// así el pase final de `finish()` sigue viendo el buffer COMPLETO.
    ///
    /// Sin esto: si el pase en vuelo que `finish()` espera completa con
    /// suficiente audio nuevo ya acumulado, su propio `handlePassCompletion`
    /// encadenaría un pase nuevo (`maybeStartPass`) ANTES de que `finish()`
    /// alcance a fijar `isFinished` — ese pase nuevo quedaría corriendo en
    /// paralelo con el pase final que `finish()` arranca a continuación
    /// (doble transcripción concurrente), y su completion podría disparar un
    /// `onPartial` DESPUÉS de que `finish()` ya retornó — violando "tras
    /// `finish()`, no vuelve a dispararse `onPartial`".
    private var isFinishing = false

    private var currentPassTask: Task<Void, Never>?
    /// Momento en que arrancó el ÚLTIMO pase lanzado (no el último
    /// completado) — `minPassInterval` limita la tasa de ARRANQUES.
    /// `.distantPast` antes del primer pase, para que la condición de
    /// intervalo se cumpla trivialmente la primera vez.
    private var lastPassStart: Date = .distantPast
    /// Tamaño de `buffer` al momento de arrancar el último pase; la
    /// diferencia contra `buffer.count` actual es el "audio nuevo" que debe
    /// alcanzar `minNewAudioSamples` para poder arrancar el siguiente pase.
    private var sampleCountAtLastPassStart = 0
    /// Último parcial NO VACÍO entregado vía `onPartial` — respaldo de
    /// `finish()` si el pase final lanza, y lo que un resultado vacío
    /// posterior NO debe pisar (ver doc de clase "Alucinaciones vacías").
    private var lastNonEmptyPartial = ""

    /// Parcial nuevo (texto completo acumulado hasta ahora). nil = sin texto aún.
    public var onPartial: ((String) -> Void)?

    public init(
        transcriber: Transcribing,
        minPassInterval: TimeInterval = 0.8,
        minNewAudioSeconds: Double = 0.4,
        maxLivePassSeconds: Double = 8.0,
        sampleRate: Double = 16_000,
        now: @escaping () -> Date = Date.init
    ) {
        self.transcriber = transcriber
        self.minPassInterval = minPassInterval
        self.minNewAudioSamples = Int(minNewAudioSeconds * sampleRate)
        self.maxLivePassSamples = maxLivePassSeconds > 0 ? Int(maxLivePassSeconds * sampleRate) : 0
        self.now = now
    }

    public func start() {
        KikiLog.log("kiki live: coordinador iniciado")
    }

    /// Alimenta un chunk (hop desde el audio thread lo hace el caller).
    public func append(_ chunk: [Float]) {
        guard !isCancelled, !isFinished else { return }
        buffer.append(contentsOf: chunk)
        maybeStartPass()
    }

    /// Pass final; espera el pass en vuelo si hay.
    /// Devuelve el texto final (o el último parcial si el pass final falla; "" si nada).
    ///
    /// - Parameter fullAudio: buffer autoritativo del recorder — los hops de
    ///   chunks pueden llegar tarde al MainActor y el buffer interno perder
    ///   la cola del dictado. Cuando no es `nil`, el pase final transcribe
    ///   ESTE buffer en vez del `buffer` interno acumulado por `append` — el
    ///   resto del contrato (espera del pase en vuelo, fences de generación/
    ///   `isFinished`, fallback a `lastNonEmptyPartial`) no cambia.
    public func finish(fullAudio: [Float]? = nil) async -> String {
        guard !isCancelled else { return "" }
        guard !isFinished else { return lastNonEmptyPartial }
        isFinishing = true
        let capturedGeneration = generation
        if let inFlight = currentPassTask {
            await inFlight.value
        }
        // Re-check tras la suspensión: dos finish() concurrentes pueden pasar
        // el primer guard; solo el primero corre el pass final.
        guard !isFinished else { return lastNonEmptyPartial }
        // Fence: un cancel() pudo haber corrido mientras esperábamos el pase
        // en vuelo — en ese caso este finish() no entrega nada.
        guard capturedGeneration == generation else { return "" }
        isFinished = true
        let samples = fullAudio ?? buffer
        // El pase final SIEMPRE detecta el idioma sobre el buffer COMPLETO.
        // (Se intentó reutilizar el idioma de los pases intermedios —P1a—
        // para ahorrar una inferencia, pero esos pases corren sobre audio
        // corto/ventaneado donde Whisper detecta basura, p.ej. ko/ms→es, y
        // contaminaba el idioma: dictados en inglés salían forzados a español.
        // La detección sobre el buffer completo es fiable. Ver kiki.log
        // 2026-07-16.)
        KikiLog.log("kiki live: pase final (\(samples.count) muestras)")
        do {
            let text = try await transcriber.transcribe(samples)
            guard capturedGeneration == generation else { return "" }
            if !text.isEmpty {
                lastNonEmptyPartial = text
            }
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

    // MARK: - Pass scheduling

    private func maybeStartPass() {
        guard !isCancelled, !isFinished, !isFinishing, currentPassTask == nil else { return }
        let newAudio = buffer.count - sampleCountAtLastPassStart
        guard newAudio >= minNewAudioSamples else { return }
        guard now().timeIntervalSince(lastPassStart) >= minPassInterval else { return }
        launchPass()
    }

    private func launchPass() {
        // Un pase intermedio (preview) transcribe solo la cola reciente
        // (`maxLivePassSamples`) para no volverse O(n) en dictados largos —
        // ver doc de `maxLivePassSamples`. `sampleCountAtLastPassStart` se
        // fija con el tamaño REAL del buffer (no el de la ventana) para que
        // el gate de "audio nuevo" siga midiendo contra todo lo acumulado.
        sampleCountAtLastPassStart = buffer.count
        let samples: [Float]
        if maxLivePassSamples > 0 && buffer.count > maxLivePassSamples {
            samples = Array(buffer.suffix(maxLivePassSamples))
        } else {
            samples = buffer
        }
        lastPassStart = now()
        let capturedGeneration = generation
        // Capturado como `let` local ANTES de crear la Task — igual que
        // `WakeListener.handleListeningSegment` — para que el cuerpo de la
        // Task no necesite tocar `self` hasta el `await self?...` final de
        // reingreso a MainActor.
        let transcriber = self.transcriber
        KikiLog.log("kiki live: pase iniciado (\(samples.count) muestras)")
        currentPassTask = Task { [weak self] in
            var result: String?
            do {
                // F1 fix 2026-07-12: los pases INTERMEDIOS son solo para
                // pintar la burbuja HUD, nunca se insertan — usan
                // `transcribeLenient` (sin gates anti-alucinación) cuando el
                // transcriber la expone, para que dictados cortos (buffers
                // <2s, la mayoría en campo) muestren texto en vez de que la
                // gate los descarte y la burbuja quede en blanco. El pase
                // FINAL (`finish()`, abajo) sigue en `transcribe` estricto
                // porque su resultado sí puede insertarse. Conformers que no
                // implementan `LenientTranscribing` (p. ej. mocks de tests
                // existentes) caen al `transcribe` estricto de siempre.
                if let lenient = transcriber as? LenientTranscribing {
                    result = try await lenient.transcribeLenient(samples)
                } else {
                    result = try await transcriber.transcribe(samples)
                }
            } catch {
                KikiLog.log("kiki live: pase falló (\(error))")
            }
            await self?.handlePassCompletion(generation: capturedGeneration, result: result)
        }
    }

    private func handlePassCompletion(generation completedGeneration: Int, result: String?) {
        // Fence: una completion de un pase lanzado ANTES del cancel() más
        // reciente no debe tocar estado ni disparar onPartial.
        guard completedGeneration == generation else { return }
        currentPassTask = nil
        if let result, !result.isEmpty {
            lastNonEmptyPartial = result
            onPartial?(result)
        }
        maybeStartPass()
    }
}
