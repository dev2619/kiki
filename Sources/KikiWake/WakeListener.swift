import AVFoundation
import Foundation
import KikiAudio
import KikiCore

@MainActor
public protocol WakeListenerDelegate: AnyObject {
    /// Frase de activación detectada sin remainder → chime + HUD "Te escucho…".
    func wakeListenerDidArm()
    /// Empezó el dictado manos-libres (silencio→habla mientras está armado).
    func wakeListenerDidStartCapture()
    /// Dictado terminado (silencio sostenido mientras está armado).
    func wakeListenerDidCapture(samples: [Float])
    /// Frase + dictado en el mismo aliento ("escúchame kiki, escribe X").
    func wakeListenerDidCaptureSameBreath(text: String)
    /// Se armó pero no hubo dictado dentro del timeout.
    func wakeListenerDidDisarm()
}

/// Escucha continua de micrófono para el flujo manos-libres: alimenta un
/// `SpeechSegmenter` propio, intenta detectar la frase de activación en cada
/// segmento y arma una ventana de dictado con timeout cuando la encuentra.
///
/// ## Disciplina de concurrencia
/// Todo el estado mutable (`_state`, `segmenter`, la tarea de transcripción en
/// vuelo, la tarea de timeout de desarmado, `session`, `disarmGeneration`,
/// `notificationEpoch`, `hasCapturedInSession`, los contadores de calibración
/// RMS) está confinado a `queue`, una cola serial que es también la cola en
/// la que se despachan los callbacks del tap de audio. `SpeechSegmenter` no
/// es thread-safe, así que mantenerlo en una única cola serial evita
/// cualquier acceso concurrente sin necesitar locks. Los métodos públicos
/// (`start`/`resumeArmed`/`stop`/`cancelCapture`) despachan de forma síncrona
/// sobre `queue` para que el caller observe el efecto (o el throw) antes de
/// retornar. El accessor público `state` también usa `queue.sync`, por lo que
/// el código interno que ya corre sobre `queue` debe usar `_state` para
/// evitar deadlock por reentrancia. Los eventos hacia el delegate —que es
/// `@MainActor`— saltan siempre con `Task { @MainActor in ... }`, y esa Task
/// vuelve a entrar a `queue` (vía `queue.sync`, ver `notify()` y doc de
/// `notificationEpoch`) para verificar que no haya quedado stale por un
/// `stop()` concurrente antes de invocar al delegate — deadlock-free por la
/// misma invariante que ya cubre el accessor `state`: nada que corre sobre
/// `queue` espera síncronamente al MainActor.
/// `@unchecked Sendable`: todo el estado mutable está confinado a `queue`
/// (ver disciplina de concurrencia arriba); no hay acceso concurrente real,
/// solo lo que el checker no puede probar automáticamente por sí solo.
///
/// ## Sesión continua de dictado (ver README §Manos libres)
/// Tras la frase de activación, `arm()` entra en `.armed` con un timeout
/// inicial de `disarmTimeoutSeconds` (8s): si no hay dictado en ese lapso, se
/// desarma. En cuanto se entrega la primera captura completa
/// (`segmentEnded` en `.armed`), el listener SE QUEDA en `.armed` en vez de
/// volver a `.listening` — la sesión sigue abierta para más utterances sin
/// repetir la frase — y todo timeout de desarmado subsiguiente usa
/// `continuousSessionTimeout` (45s). `hasCapturedInSession` es el flag que
/// distingue ambos regímenes; se resetea a `false` en `arm()` y en cualquier
/// transición de vuelta a `.listening`. `cancelCapture()` (Esc) siempre
/// termina la sesión completa, sin importar el régimen. `resumeArmed()`
/// permite a la app relanzar el listener directamente en `.armed` (régimen de
/// 45s) tras la pausa que exige procesar+pegar cada captura sin engines de
/// audio simultáneos — ver `AppDelegate.resumeAsArmed`.
public final class WakeListener: @unchecked Sendable {
    public enum State: Equatable {
        case stopped
        case listening
        case armed
    }

    // MARK: - Tunables (nombrados, ver task-4-brief.md)
    private static let listeningConfig = SegmenterConfig(endSilence: 0.7, maxSegmentDuration: 6)
    private static let armedConfig = SegmenterConfig(endSilence: 1.5, maxSegmentDuration: 30)
    /// Timeout de desarmado inicial: rige entre `arm()` (frase detectada) y la
    /// primera captura completa. Corto a propósito — una frase dicha sin
    /// dictado detrás debe desarmar rápido.
    private static let disarmTimeoutSeconds: TimeInterval = 8
    /// Timeout de desarmado durante una sesión continua (tras al menos una
    /// captura entregada): más largo que `disarmTimeoutSeconds` porque aquí
    /// ya no hace falta repetir la frase — el usuario puede estar pensando la
    /// siguiente frase entre utterances.
    private static let continuousSessionTimeout: TimeInterval = 45
    private static let tapBufferSize: AVAudioFrameCount = 4_096
    private static let sampleRate: Double = 16_000
    /// Ventana de calibración de RMS: duración de cada ventana y cuántas se
    /// loggean tras cada `start()`/`resumeArmed()` antes de dejar de hacerlo,
    /// para no ensuciar el log indefinidamente.
    private static let calibrationWindowDuration: TimeInterval = 10
    private static let calibrationMaxWindows = 6
    /// Ventana tras armar durante la cual se ignora el audio entrante: el
    /// chime "Glass" reproducido en `wakeListenerDidArm` (delegate, dispara
    /// en el MainActor apenas se detecta la frase) tarda en sonar y su propio
    /// audio puede colarse por el micrófono del Mac, disparando un
    /// `speechStarted` falso en el segmenter o mezclándose con el arranque
    /// real del dictado capturado.
    private static let postArmSuppression: TimeInterval = 0.5

    /// Backing store de `state`, confinado a `queue`. El código interno que ya
    /// corre sobre `queue` DEBE leer/escribir `_state` directamente — nunca el
    /// accessor público `state`, que hace `queue.sync` y produciría deadlock
    /// por reentrancia si se llamara desde dentro de la propia cola.
    private var _state: State = .stopped
    public var state: State { queue.sync { _state } }
    public weak var delegate: WakeListenerDelegate?

    private let transcriber: Transcribing
    private let engine = AVAudioEngine()
    /// Cola serial: confina segmenter + estado, y es la cola destino del tap de audio.
    private let queue = DispatchQueue(label: "com.dev2619.kiki.wake-listener")
    private var segmenter = SpeechSegmenter(config: WakeListener.listeningConfig)

    /// Solo una transcripción en vuelo a la vez; segmentos que llegan mientras
    /// hay una pendiente se descartan (ver `handleListeningSegment`).
    private var isTranscribing = false
    private var transcriptionTask: Task<Void, Never>?
    private var disarmTask: Task<Void, Never>?
    /// Incrementado en cada start()/stop(). Las tareas de transcripción en
    /// vuelo capturan el valor vigente al lanzarse; si al completar el valor
    /// ya no coincide (hubo un stop()+start() de por medio), el resultado se
    /// descarta aunque el `state` haya vuelto a `.listening` por casualidad.
    private var session = 0
    /// Incrementado cada vez que se programa o cancela el timeout de
    /// desarmado. Un `fireDisarmTimeout` solo actúa si su generación capturada
    /// sigue vigente, evitando la carrera entre la expiración natural de 8s y
    /// un cancel() disparado casi al mismo tiempo (p.ej. por speechStarted).
    private var disarmGeneration = 0

    /// Incrementado únicamente en `stop()`. Fencing de las notificaciones al
    /// delegate (ver `notify()`): una notificación ya despachada a la cola
    /// del delegate (MainActor) antes de que `stop()` invalide la sesión no
    /// debe poder actuar después de ese `stop()`.
    ///
    /// Carrera concreta que motiva esto: un segmento armado termina y
    /// `handle()` ya corrió en `queue`, encolando `notify { $0.wakeListenerDidCapture(...) }`
    /// como una `Task { @MainActor in ... }` — justo cuando el usuario
    /// presiona Fn. El hotkey dispara su propio `Task { @MainActor in ... }`
    /// que transiciona `DictationController` a `.recording`, y
    /// `dictationStateDidChange(.recording)` llama a `wakeListener.stop()`
    /// (síncrono sobre `queue`, invalida `session`). Si esa segunda Task
    /// corre en el MainActor ANTES que la primera (el orden entre dos
    /// `Task { @MainActor }` encoladas por separado no es FIFO garantizado),
    /// la notificación de captura llega STALE: `AppDelegate` fija
    /// `resumeAsArmed = true` y llama a `controller.process(samples:)`, que
    /// descarta las muestras (`state != .idle`) pero deja `resumeAsArmed`
    /// pegado en `true` — al terminar el dictado por hotkey, el resume
    /// rearmaría el micrófono sin frase ni chime (regresión de privacidad).
    /// Con este fence, `notify` captura `notificationEpoch` en el momento del
    /// despacho (sobre `queue`) y la Task en MainActor la vuelve a leer
    /// (`queue.sync`, deadlock-free por la misma invariante que ya usa el
    /// accessor `state`: nada que corre sobre `queue` espera síncronamente al
    /// MainActor) justo antes de invocar la acción — si `stop()` corrió en el
    /// medio, el epoch ya cambió y la notificación se descarta sin efecto.
    private var notificationEpoch = 0

    /// Contador acumulado de muestras entregadas por el tap desde `start()`,
    /// usado para medir la ventana de `postArmSuppression` sin depender de
    /// timers de wall-clock (consistente con que todo lo demás en esta clase
    /// avanza por eventos del propio tap). Confinado a `queue` como el resto.
    private var accumulatedSampleCount = 0
    /// Umbral de `accumulatedSampleCount` a partir del cual deja de
    /// suprimirse el audio entrante tras armar; `nil` cuando no aplica
    /// supresión (no armado, o ventana ya consumida).
    private var suppressUntilSampleCount: Int?

    /// `true` desde que se entregó la primera captura completa dentro del
    /// arme vigente; determina si el próximo timeout de desarmado usa
    /// `disarmTimeoutSeconds` (8s, sin dictado aún) o `continuousSessionTimeout`
    /// (45s, sesión continua ya en marcha). Se resetea a `false` en `arm()` y
    /// en toda transición de `.armed` de vuelta a `.listening`; `resumeArmed()`
    /// lo fija en `true` porque por definición solo se llama tras haber
    /// entregado ya una captura.
    private var hasCapturedInSession = false

    /// Pico de RMS observado en la ventana de calibración vigente (mientras
    /// `_state == .listening` o `.armed`); ver `calibrationWindowsLogged`.
    private var calibrationPeakRMS: Float = 0
    /// Muestras acumuladas dentro de la ventana de calibración vigente,
    /// usado para medir los 10s por conteo de muestras (sin `Date()`).
    private var calibrationWindowSampleCount = 0
    /// Ventanas de calibración ya loggeadas desde el último `start()`/
    /// `resumeArmed()`; deja de loggear al llegar a `calibrationMaxWindows`
    /// para no ensuciar el log indefinidamente.
    private var calibrationWindowsLogged = 0

    public init(transcriber: Transcribing) {
        self.transcriber = transcriber
    }

    // MARK: - Public API

    public func start() throws {
        try queue.sync {
            guard _state == .stopped else {
                KikiLog.log("kiki wake: start() ignorado, ya activo (state=\(_state))")
                return
            }
            resetSessionCounters()
            hasCapturedInSession = false
            segmenter = SpeechSegmenter(config: Self.listeningConfig)
            try installTapAndStartEngine()
            _state = .listening
            KikiLog.log("kiki wake: listening iniciado")
        }
    }

    /// Como `start()`, pero aterriza directo en `.armed` (régimen de sesión
    /// continua, timeout de 45s) en vez de `.listening`. Lo usa la app para
    /// relanzar el listener tras la pausa que exige procesar+pegar cada
    /// captura sin dos engines de audio simultáneos, sin perder la sesión de
    /// dictado abierta ni pedir la frase de nuevo — ver
    /// `AppDelegate.resumeAsArmed`. Semántica de `session` idéntica a
    /// `start()`: cada llamada la incrementa, invalidando cualquier
    /// transcripción en vuelo de una sesión anterior.
    public func resumeArmed() throws {
        try queue.sync {
            guard _state == .stopped else {
                KikiLog.log("kiki wake: resumeArmed() ignorado, ya activo (state=\(_state))")
                return
            }
            resetSessionCounters()
            // Por definición solo se llama tras haber entregado ya una
            // captura en esta sesión, así que el próximo timeout es el de
            // sesión continua (45s), no el inicial (8s).
            hasCapturedInSession = true
            segmenter = SpeechSegmenter(config: Self.armedConfig)
            try installTapAndStartEngine()
            _state = .armed
            KikiLog.log("kiki wake: reanudado armado (sesión continua)")
            scheduleDisarmTimeout()
        }
    }

    /// Contadores comunes a `start()`/`resumeArmed()`: incrementa `session`
    /// (invalidando transcripciones/timeouts en vuelo de la sesión previa) y
    /// resetea los acumuladores de muestras, incluida la calibración de RMS.
    private func resetSessionCounters() {
        dispatchPrecondition(condition: .onQueue(queue))
        session += 1
        isTranscribing = false
        accumulatedSampleCount = 0
        suppressUntilSampleCount = nil
        calibrationPeakRMS = 0
        calibrationWindowSampleCount = 0
        calibrationWindowsLogged = 0
    }

    /// Instala el tap de audio y arranca el engine; usado por `start()` y
    /// `resumeArmed()`, que comparten este plumbing y solo difieren en el
    /// estado final (`.listening` vs `.armed`) y el config de segmenter.
    private func installTapAndStartEngine() throws {
        dispatchPrecondition(condition: .onQueue(queue))
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: Self.tapBufferSize, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let chunk = AudioResampler.resampleTo16kMono(buffer)
            let rms = AudioResampler.rms(chunk)
            self.queue.async { self.handle(chunk: chunk, rms: rms) }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    public func stop() {
        queue.sync {
            guard _state != .stopped else { return }
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            cancelDisarmTimeout()
            transcriptionTask?.cancel()
            transcriptionTask = nil
            isTranscribing = false
            session += 1
            // Ver doc de `notificationEpoch`: invalida cualquier notificación
            // al delegate que ya haya sido despachada (Task@MainActor
            // encolada) pero que todavía no haya corrido.
            notificationEpoch += 1
            segmenter.reset()
            _state = .stopped
            KikiLog.log("kiki wake: detenido")
        }
    }

    public func cancelCapture() {
        queue.sync {
            guard _state == .armed else { return }
            cancelDisarmTimeout()
            // Vuelta a listening tras cancelar: el segmenter nuevo arranca sin
            // el pre-roll que tenía el anterior, así que hay una ventana de
            // ~0.3s donde el primer audio entrante puede perderse antes de
            // que el buffer circular interno se rellene de nuevo.
            segmenter = SpeechSegmenter(config: Self.listeningConfig)
            _state = .listening
            suppressUntilSampleCount = nil
            hasCapturedInSession = false
            KikiLog.log("kiki wake: captura cancelada, vuelvo a listening")
            notify { $0.wakeListenerDidDisarm() }
        }
    }

    // MARK: - Tap handling (confinado a `queue`)

    private func handle(chunk: [Float], rms: Float) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard _state != .stopped else { return }
        accumulatedSampleCount += chunk.count
        trackCalibrationWindow(chunk: chunk, rms: rms)
        if _state == .armed, let suppressUntil = suppressUntilSampleCount {
            guard accumulatedSampleCount >= suppressUntil else {
                // Dentro de la ventana postArmSuppression: se descarta el
                // chunk sin alimentar el segmenter, para que el chime no
                // pueda disparar un speechStarted falso ni colarse al inicio
                // del dictado capturado.
                return
            }
            suppressUntilSampleCount = nil
        }
        switch segmenter.process(chunk: chunk, rms: rms) {
        case .none:
            break
        case .speechStarted:
            handleSpeechStarted()
        case .segmentEnded(let samples):
            handleSegmentEnded(samples)
        case .segmentDiscarded(let reason):
            KikiLog.log("kiki wake: segmento descartado (\(reason))")
            // Si el habla que arrancó la captura resultó descartada (muy
            // corta o excedió el máximo) sin llegar a segmentEnded, el
            // timeout de desarmado ya fue cancelado en handleSpeechStarted.
            // Sin reprogramarlo aquí, el listener quedaría armado
            // indefinidamente sin ninguna vía de salida salvo cancelCapture().
            if _state == .armed {
                scheduleDisarmTimeout()
            }
        }
    }

    /// Diagnóstico de calibración: registra el pico de RMS visto en modo
    /// `.listening` o `.armed` (el nivel de mic es igual de útil en ambos —
    /// una sesión armada puede pasar buena parte de sus 45s de timeout en
    /// silencio entre utterances, y esos datos de RMS ambiente también sirven
    /// para calibrar) en ventanas de 10s (medidas por conteo de muestras, no
    /// `Date()`, consistente con `postArmSuppression`), y loggea solo las
    /// primeras `calibrationMaxWindows` (6) ventanas desde el último
    /// `start()`/`resumeArmed()` — evita ensuciar el log indefinidamente
    /// mientras sigue dando visibilidad suficiente para calibrar
    /// `speechRMSThreshold` contra el micrófono real del usuario.
    private func trackCalibrationWindow(chunk: [Float], rms: Float) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard calibrationWindowsLogged < Self.calibrationMaxWindows else { return }
        if _state == .listening || _state == .armed {
            calibrationPeakRMS = max(calibrationPeakRMS, rms)
        }
        calibrationWindowSampleCount += chunk.count
        let windowSamples = Int(Self.calibrationWindowDuration * Self.sampleRate)
        guard calibrationWindowSampleCount >= windowSamples else { return }
        calibrationWindowsLogged += 1
        KikiLog.log("kiki wake: pico RMS últimos 10s: \(String(format: "%.4f", calibrationPeakRMS))")
        calibrationPeakRMS = 0
        calibrationWindowSampleCount = 0
    }

    private func handleSpeechStarted() {
        guard _state == .armed else { return }
        cancelDisarmTimeout()
        notify { $0.wakeListenerDidStartCapture() }
    }

    private func handleSegmentEnded(_ samples: [Float]) {
        switch _state {
        case .listening:
            handleListeningSegment(samples)
        case .armed:
            cancelDisarmTimeout()
            // Sesión continua: se queda en `.armed` en vez de volver a
            // `.listening` — el mismo `segmenter` (config `.armed`) ya quedó
            // reseteado internamente al emitir `segmentEnded`, listo para la
            // siguiente utterance sin recrearlo ni perder su pre-roll. A
            // partir de aquí el timeout de desarmado pasa a
            // `continuousSessionTimeout` (45s) vía `hasCapturedInSession`.
            hasCapturedInSession = true
            KikiLog.log("kiki wake: captura completa (\(samples.count) muestras), sesión continua sigue armada")
            notify { $0.wakeListenerDidCapture(samples: samples) }
            scheduleDisarmTimeout()
        case .stopped:
            break
        }
    }

    private func handleListeningSegment(_ samples: [Float]) {
        guard !isTranscribing else {
            let seconds = Double(samples.count) / Self.sampleRate
            KikiLog.log("kiki wake: segmento descartado (transcripción en curso, \(String(format: "%.1f", seconds))s)")
            return
        }
        isTranscribing = true
        let transcriber = self.transcriber
        // Fence de sesión: si hay un stop()+start() mientras esta tarea está
        // en vuelo, `session` cambia y el resultado se descarta al volver,
        // aunque `state` haya vuelto a `.listening` por el nuevo start().
        let capturedSession = session
        transcriptionTask = Task {
            let text: String?
            do {
                text = try await transcriber.transcribe(samples)
            } catch {
                KikiLog.log("kiki wake: transcripción falló (\(error))")
                text = nil
            }
            self.queue.async {
                // Solo la sesión vigente puede tocar isTranscribing /
                // transcriptionTask: una completion stale (sesión vieja) NO
                // debe resetear nada — el stop() que la invalidó ya hizo la
                // limpieza, y estos campos pueden pertenecer ahora a una
                // transcripción de la sesión nueva todavía en vuelo
                // (clobberearlos permitiría dos transcripciones concurrentes
                // y dejaría esa tarea sin handle cancelable). Dentro de la
                // sesión vigente el reset sí es incondicional: cubre el path
                // feliz y el throw de transcribe().
                guard capturedSession == self.session else { return }
                self.isTranscribing = false
                self.transcriptionTask = nil
                guard self._state == .listening, let text else { return }
                self.applyMatch(text, sampleCount: samples.count)
            }
        }
    }

    private func applyMatch(_ text: String, sampleCount: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let match = WakePhraseMatcher.match(text) else {
            // Regla de privacidad: NO se loggea el contenido de segmentos sin
            // match (conversación ajena a kiki), solo duración.
            let seconds = Double(sampleCount) / Self.sampleRate
            KikiLog.log("kiki wake: segmento descartado (sin frase, \(String(format: "%.1f", seconds))s)")
            return
        }
        // El segmento matcheó: iba dirigido a kiki, sí se loggea el transcript.
        KikiLog.log("kiki wake: frase detectada: \"\(text)\"")
        if match.remainder.isEmpty {
            arm()
        } else {
            notify { $0.wakeListenerDidCaptureSameBreath(text: match.remainder) }
        }
    }

    private func arm() {
        dispatchPrecondition(condition: .onQueue(queue))
        _state = .armed
        // Frase nueva → arme inicial de la sesión: régimen de timeout corto
        // (8s) hasta la primera captura entregada.
        hasCapturedInSession = false
        segmenter = SpeechSegmenter(config: Self.armedConfig)
        // Ver doc de postArmSuppression: el chime que dispara wakeListenerDidArm
        // (más abajo) no debe colarse en el segmenter recién armado.
        suppressUntilSampleCount = accumulatedSampleCount + Int(Self.postArmSuppression * Self.sampleRate)
        KikiLog.log("kiki wake: armado")
        notify { $0.wakeListenerDidArm() }
        scheduleDisarmTimeout()
    }

    /// Cancela el timeout de desarmado en vuelo (si hay uno) y avanza la
    /// generación, invalidando cualquier `fireDisarmTimeout` ya en camino
    /// aunque su `Task.cancel()` no alcance a observarse a tiempo.
    private func cancelDisarmTimeout() {
        dispatchPrecondition(condition: .onQueue(queue))
        disarmTask?.cancel()
        disarmTask = nil
        disarmGeneration += 1
    }

    /// El timeout programado depende de `hasCapturedInSession`: 8s
    /// (`disarmTimeoutSeconds`) antes de la primera captura de la sesión, 45s
    /// (`continuousSessionTimeout`) una vez que ya se entregó al menos una.
    private func scheduleDisarmTimeout() {
        dispatchPrecondition(condition: .onQueue(queue))
        disarmTask?.cancel()
        disarmGeneration += 1
        let generation = disarmGeneration
        let timeout = hasCapturedInSession ? Self.continuousSessionTimeout : Self.disarmTimeoutSeconds
        disarmTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.queue.async { self.fireDisarmTimeout(generation: generation) }
        }
    }

    private func fireDisarmTimeout(generation: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        // Guarda de generación: una expiración natural puede llegar a
        // ejecutarse casi al mismo tiempo que un cancel() (p.ej. disparado por
        // speechStarted); si la generación ya avanzó, este disparo es stale.
        guard generation == disarmGeneration, _state == .armed else { return }
        disarmTask = nil
        segmenter = SpeechSegmenter(config: Self.listeningConfig)
        _state = .listening
        suppressUntilSampleCount = nil
        hasCapturedInSession = false
        KikiLog.log("kiki wake: timeout sin dictado, vuelvo a listening")
        notify { $0.wakeListenerDidDisarm() }
    }

    // MARK: - Delegate hop

    private func notify(_ action: @escaping @MainActor (WakeListenerDelegate) -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let delegate else { return }
        // Fence contra un `stop()` concurrente — ver doc de
        // `notificationEpoch` para la carrera exacta que esto cierra.
        let capturedEpoch = notificationEpoch
        Task { @MainActor in
            let stillValid = self.queue.sync { capturedEpoch == self.notificationEpoch }
            guard stillValid else {
                KikiLog.log("kiki wake: notificación descartada (epoch stale, stop() concurrente)")
                return
            }
            action(delegate)
        }
    }
}
