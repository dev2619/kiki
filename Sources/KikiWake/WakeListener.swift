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
    /// `sessionIsCurrent`: token de frescura — `false` si un `stop()` (o
    /// `stop()`+`start()`/`resumeArmed()`) corrió entre el despacho de esta
    /// notificación y su entrega en el MainActor. El delegate debe procesar
    /// el habla capturada SIEMPRE (nunca se descarta dictado real), pero solo
    /// debe tratar la entrega como parte de la sesión manos-libres vigente
    /// (p.ej. rearmar el mic al terminar de procesar) cuando es `true` — ver
    /// `WakeListener.notifyCapture`.
    func wakeListenerDidCapture(samples: [Float], sessionIsCurrent: Bool)
    /// Frase + dictado en el mismo aliento ("escúchame kiki, escribe X").
    /// `sessionIsCurrent`: mismo token de frescura que `wakeListenerDidCapture`.
    func wakeListenerDidCaptureSameBreath(text: String, sessionIsCurrent: Bool)
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
/// audio simultáneos — ver `AppDelegate.resumeAsArmed`. `armDirectly()` es su
/// gemelo para armes FRESCOS (⌥⌘K, sin frase ni captura previa): mismo
/// plumbing, pero arranca en el régimen inicial de 8s.
public final class WakeListener: @unchecked Sendable {
    public enum State: Equatable {
        case stopped
        case listening
        case armed
    }

    // MARK: - Tunables (nombrados, ver task-4-brief.md)
    /// Silencio de fin de segmento en `.listening` (esperando la frase de
    /// activación): 0.5s en vez de los 0.7s originales — reduce la latencia
    /// percibida frase→chime sin comerse la cola de la frase en microfonos
    /// lentos a levantar la señal (Fase 3.6, task-361).
    private static let listeningEndSilence: TimeInterval = 0.5
    /// Duración mínima de habla para NO descartar un segmento en
    /// `.listening`: bajado de los 0.4s por defecto de `SegmenterConfig` a
    /// 0.25s. Motivo (bug de campo): en señal de mic marginal, la frase de
    /// activación ("es-cú-cha-me") fragmenta en ráfagas <0.4s que cruzan el
    /// umbral RMS de forma intermitente — con 0.4s cada fragmento se
    /// descarta como "corto" y la frase nunca llega a Whisper. 0.25s le da
    /// más chances a esos fragmentos sin tocar la máquina de estados del
    /// segmenter. Solo aplica a `.listening`: `armedConfig` (dictado real,
    /// ya armado) se queda en 0.4s por defecto — ahí un falso positivo corto
    /// no tiene el mismo costo que perder la frase de activación completa.
    private static let listeningMinSpeechDuration: TimeInterval = 0.25
    /// Umbral RMS por defecto usado por ambos configs cuando `init` no
    /// recibe uno explícito. Calibrable en campo sin rebuild vía
    /// `UserDefaults` (`kiki.wakeRMSThreshold`) — ver `AppDelegate`.
    public static let defaultSpeechRMSThreshold: Float = 0.008
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
    /// Umbral RMS efectivo de esta instancia (ver `init`): alimenta tanto
    /// `listeningConfig` como `armedConfig` para que la calibración de campo
    /// (`kiki.wakeRMSThreshold`) afecte ambos regímenes por igual.
    private let speechRMSThreshold: Float
    private let listeningConfig: SegmenterConfig
    private let armedConfig: SegmenterConfig
    private var segmenter: SpeechSegmenter

    /// Último piso de ruido aprendido conocido, persistido a través de las
    /// recreaciones de `segmenter` E incluso a través de `stop()`+`start()`
    /// (el engine se apaga y reenciende entre cada captura de la sesión
    /// continua — ver `AppDelegate.resumeAsArmed` — y el ambiente del cuarto
    /// no cambió en ese medio segundo). Sin esto, el piso aprendido muere
    /// con cada instancia: en el escenario de campo del cuarto ruidoso, el
    /// segmenter de `.listening` converge, la frase por fin matchea, y
    /// `arm()` entregaría un segmenter armado (¡maxSegmentDuration 30s!)
    /// re-bloqueado desde cero — los primeros ~30s de dictado REAL se
    /// descartarían como "máximo" mientras re-converge. Se actualiza en
    /// `makeSegmenter` (recreaciones en vivo) y en `stop()` (antes del
    /// `reset()` que borra el piso de la instancia). Confinado a `queue`
    /// como el resto del estado mutable.
    private var lastKnownNoiseFloor: Float?

    /// Solo una transcripción en vuelo a la vez; un segmento que llega
    /// mientras hay una pendiente ya NO se descarta (bug de campo: la frase
    /// de activación completa podía llegar justo durante el check en vuelo
    /// de un segmento anterior y perderse — ver `segmento descartado
    /// (transcripción en curso)` en el log). En su lugar se guarda en
    /// `pendingSegment` y se encola para chequeo — ver `handleListeningSegment`.
    private var isTranscribing = false
    /// Segmento en espera mientras `isTranscribing` está en vuelo. Cola de
    /// tamaño MÁXIMO 1: "el más reciente gana" — si llega un segundo
    /// segmento antes de que el primero pendiente alcance a chequearse, el
    /// primero se descarta a favor del segundo (más probable que contenga la
    /// frase completa/reciente) y se loggea el reemplazo. Se chequea en
    /// cuanto termina el check en vuelo (mismo flujo que un segmento
    /// normal, ver el `queue.async` al final de `handleListeningSegment`).
    /// Se limpia en cualquier transición que invalide la sesión de
    /// `.listening` vigente (`arm()`, `stop()`, `resetSessionCounters()` —
    /// bump de `session` en `start()`/`resumeArmed()`) para que un segmento
    /// de un régimen o sesión anteriores nunca se cuele en el siguiente.
    private var pendingSegment: [Float]?
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

    /// Incrementado únicamente en `stop()`. Fencing de las notificaciones de
    /// ESTADO al delegate (ver `notify()`): una notificación ya despachada a
    /// la cola del delegate (MainActor) antes de que `stop()` invalide la
    /// sesión no debe poder actuar después de ese `stop()`.
    ///
    /// Alcance del fence (decisión de diseño): solo cubre
    /// `didArm`/`didStartCapture`/`didDisarm` (vía `notify`). `didCapture`/
    /// `didCaptureSameBreath` NO pasan por este fence — cargan habla real
    /// del usuario, que debe entregarse siempre aunque haya un `stop()`
    /// concurrente; van por `notifyCapture`, que en vez de descartar adjunta
    /// un token de frescura de sesión (`sessionIsCurrent`, derivado de
    /// `session`) para que el delegate gatee solo los efectos de estado. El
    /// fence protege únicamente notificaciones cuyo efecto es visible/de
    /// estado (rearmar el mic, mostrar HUD), donde una entrega stale sí
    /// sería un bug observable.
    ///
    /// Carrera original que motivó este fence (antes de la exención de
    /// captura): un segmento armado termina y `handle()` ya corrió en
    /// `queue`, encolando `notify { $0.wakeListenerDidCapture(...) }` como
    /// una `Task { @MainActor in ... }` — justo cuando el usuario presiona
    /// Fn. El hotkey dispara su propio `Task { @MainActor in ... }` que
    /// transiciona `DictationController` a `.recording`, y
    /// `dictationStateDidChange(.recording)` llama a `wakeListener.stop()`
    /// (síncrono sobre `queue`, invalida `session`). Si esa segunda Task
    /// corre en el MainActor ANTES que la primera (el orden entre dos
    /// `Task { @MainActor }` encoladas por separado no es FIFO garantizado),
    /// la notificación de captura llega STALE: `AppDelegate` fijaba
    /// `resumeAsArmed = true` y llamaba a `controller.process(samples:)`, que
    /// descartaba las muestras (`state != .idle`) pero dejaba `resumeAsArmed`
    /// pegado en `true` — al terminar el dictado por hotkey, el resume
    /// rearmaría el micrófono sin frase ni chime (regresión de privacidad).
    /// Ahora que la captura ya no pasa por el fence (debe entregarse
    /// SIEMPRE — ver arriba), esa carrera se cierra en dos capas: el guard
    /// de `AppDelegate` sobre `controller.state == .idle` (cubre el
    /// ordenamiento donde el hotkey aún ocupa `.recording`/`.processing`) y
    /// el token `sessionIsCurrent` de `notifyCapture` (cubre el caso de una
    /// Task starved que corre DESPUÉS de que el ciclo de hotkey terminó y el
    /// controller volvió a `.idle` — el guard de estado ya no la detecta,
    /// pero el token sí, porque `session` avanzó con el `stop()`).
    ///
    /// Para las notificaciones que sí quedan fenced, `notify` captura
    /// `notificationEpoch` en el momento del despacho (sobre `queue`) y la
    /// Task en MainActor la vuelve a leer (`queue.sync`, deadlock-free por la
    /// misma invariante que ya usa el accessor `state`: nada que corre sobre
    /// `queue` espera síncronamente al MainActor) justo antes de invocar la
    /// acción — si `stop()` corrió en el medio, el epoch ya cambió y la
    /// notificación se descarta sin efecto.
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
    /// (45s, sesión continua ya en marcha). Se resetea a `false` en `arm()`,
    /// en `armDirectly()` (arme fresco sin captura previa — régimen de 8s) y
    /// en toda transición de `.armed` de vuelta a `.listening`; `resumeArmed()`
    /// lo fija en `true` porque continúa una sesión que ya entregó al menos
    /// una captura.
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

    /// - Parameter speechRMSThreshold: Umbral RMS de habla, compartido por
    ///   `listeningConfig` y `armedConfig`. Calibrable en campo sin rebuild
    ///   — ver `AppDelegate` (`UserDefaults.kiki.wakeRMSThreshold`) — porque
    ///   un umbral fijo de 0.008 puede quedar por encima del piso de ruido
    ///   real de un mic marginal, fragmentando la señal en ráfagas cortas
    ///   que nunca completan una ventana de calibración.
    public init(transcriber: Transcribing, speechRMSThreshold: Float = WakeListener.defaultSpeechRMSThreshold) {
        self.transcriber = transcriber
        self.speechRMSThreshold = speechRMSThreshold
        // adaptiveThreshold: true — this is the one caller that opts in (see
        // `SegmenterConfig.adaptiveThreshold` doc). Field data showed the
        // fixed threshold failing in both directions for real microphones:
        // a loud room pins every chunk above it forever (segments always hit
        // maxSegmentDuration and get discarded before the wake phrase is
        // ever checked), while a quiet room fragments real speech below it
        // ("corto" discards). Both `listeningConfig` and `armedConfig` opt
        // in so the learned floor carries the same intent across regimes;
        // each keeps its own `SpeechSegmenter` instance (see `segmenter`
        // reassignments below) so each has its own independently-learned
        // floor rather than sharing state across regimes with very
        // different silence/duration tunables.
        self.listeningConfig = SegmenterConfig(
            speechRMSThreshold: speechRMSThreshold,
            endSilence: Self.listeningEndSilence,
            minSpeechDuration: Self.listeningMinSpeechDuration,
            maxSegmentDuration: 6,
            adaptiveThreshold: true)
        self.armedConfig = SegmenterConfig(
            speechRMSThreshold: speechRMSThreshold,
            endSilence: 1.5,
            maxSegmentDuration: 30,
            adaptiveThreshold: true)
        self.segmenter = SpeechSegmenter(config: self.listeningConfig)
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
            segmenter = makeSegmenter(config: listeningConfig)
            try installTapAndStartEngine()
            _state = .listening
            KikiLog.log("kiki wake: listening iniciado")
            KikiLog.log("kiki wake: umbral RMS efectivo \(String(format: "%.3f", speechRMSThreshold))")
        }
    }

    /// Como `start()`, pero aterriza directo en `.armed` CONTINUANDO una
    /// sesión de dictado ya en marcha (régimen de sesión continua, timeout de
    /// 45s) en vez de `.listening`. Lo usa la app para relanzar el listener
    /// tras la pausa que exige procesar+pegar cada captura sin dos engines de
    /// audio simultáneos, sin perder la sesión de dictado abierta ni pedir la
    /// frase de nuevo — ver `AppDelegate.resumeAsArmed`. Se llama tras haber
    /// entregado ya una captura en la sesión, por eso fija
    /// `hasCapturedInSession = true` (régimen de 45s); para un arme FRESCO
    /// sin captura previa (⌥⌘K, sin frase) usar `armDirectly()`, que arranca
    /// en el régimen inicial de 8s. Semántica de `session` idéntica a
    /// `start()`: cada llamada la incrementa, invalidando cualquier
    /// transcripción en vuelo de una sesión anterior.
    public func resumeArmed() throws {
        try startArmed(
            continuingSession: true,
            logLabel: "reanudado armado (sesión continua)")
    }

    /// Arme FRESCO directo en `.armed`, sin frase de activación ni captura
    /// previa — el entry point del atajo ⌥⌘K (ver
    /// `AppDelegate.armViaShortcut`). Mismo plumbing que `resumeArmed()`
    /// (config `armedConfig`, bump de `session`, engine), con una sola
    /// diferencia: `hasCapturedInSession` queda en `false`, así que el primer
    /// timeout de desarmado es el INICIAL de 8s (`disarmTimeoutSeconds`) —
    /// un arme sin dictado detrás debe desarmar rápido, igual que un arme
    /// por frase. La primera captura entregada lo asciende al régimen de
    /// sesión continua (45s) por el camino normal (`handleSegmentEnded`).
    public func armDirectly() throws {
        try startArmed(
            continuingSession: false,
            logLabel: "armado directo (sin frase)")
    }

    /// Plumbing común de `resumeArmed()`/`armDirectly()`: ambos aterrizan en
    /// `.armed` y solo difieren en el régimen del primer timeout de desarmado
    /// (`continuingSession` → `hasCapturedInSession`: 45s vs 8s — ver docs de
    /// cada entry point).
    private func startArmed(continuingSession: Bool, logLabel: String) throws {
        try queue.sync {
            guard _state == .stopped else {
                KikiLog.log("kiki wake: arranque armado ignorado, ya activo (state=\(_state))")
                return
            }
            resetSessionCounters()
            hasCapturedInSession = continuingSession
            segmenter = makeSegmenter(config: armedConfig)
            try installTapAndStartEngine()
            _state = .armed
            KikiLog.log("kiki wake: \(logLabel)")
            KikiLog.log("kiki wake: umbral RMS efectivo \(String(format: "%.3f", speechRMSThreshold))")
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
        pendingSegment = nil
        accumulatedSampleCount = 0
        suppressUntilSampleCount = nil
        calibrationPeakRMS = 0
        calibrationWindowSampleCount = 0
        calibrationWindowsLogged = 0
    }

    /// Único constructor de segmenters de reemplazo: preserva el piso de
    /// ruido aprendido a través de la recreación (ver `lastKnownNoiseFloor`
    /// para el bug de interacción que esto cierra). Captura el piso del
    /// segmenter saliente si tiene uno (las recreaciones en vivo — `arm()`,
    /// `cancelCapture()`, `fireDisarmTimeout()` — llegan aquí con el
    /// segmenter aún cargado); si no (tras `stop()`, que ya hizo `reset()`
    /// sobre la instancia), usa el último piso capturado en `stop()`.
    private func makeSegmenter(config: SegmenterConfig) -> SpeechSegmenter {
        dispatchPrecondition(condition: .onQueue(queue))
        if let learned = segmenter.noiseFloor {
            lastKnownNoiseFloor = learned
        }
        return SpeechSegmenter(config: config, seedNoiseFloor: lastKnownNoiseFloor)
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
            pendingSegment = nil
            session += 1
            // Ver doc de `notificationEpoch`: invalida cualquier notificación
            // al delegate que ya haya sido despachada (Task@MainActor
            // encolada) pero que todavía no haya corrido.
            notificationEpoch += 1
            flushPartialCalibrationWindow()
            // Capturar el piso aprendido ANTES del reset() que lo borra de
            // la instancia: el próximo start()/resumeArmed() lo re-siembra
            // vía makeSegmenter (ver lastKnownNoiseFloor).
            if let learned = segmenter.noiseFloor {
                lastKnownNoiseFloor = learned
            }
            segmenter.reset()
            _state = .stopped
            KikiLog.log("kiki wake: detenido")
        }
    }

    /// Vuelca el pico de RMS acumulado en la ventana de calibración vigente
    /// aunque no haya alcanzado los 10s completos (`calibrationWindowDuration`).
    /// Bug de campo: sesiones cortas (p.ej. una prueba de 3s) nunca llegaban a
    /// completar una ventana en `trackCalibrationWindow`, así que `stop()` no
    /// dejaba NINGÚN dato de RMS en el log — sin esto, calibrar
    /// `speechRMSThreshold` contra el mic real requería mantener el listener
    /// activo al menos 10s, algo que el usuario no sabía y no siempre podía
    /// cumplir en una prueba rápida.
    private func flushPartialCalibrationWindow() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard calibrationWindowsLogged < Self.calibrationMaxWindows,
              calibrationWindowSampleCount > 0 else { return }
        let seconds = Double(calibrationWindowSampleCount) / Self.sampleRate
        KikiLog.log("kiki wake: pico RMS ventana parcial (\(String(format: "%.1f", seconds))s): \(String(format: "%.4f", calibrationPeakRMS)) (umbral efectivo \(String(format: "%.4f", segmenter.effectiveThreshold)))")
        calibrationPeakRMS = 0
        calibrationWindowSampleCount = 0
    }

    public func cancelCapture() {
        queue.sync {
            guard _state == .armed else { return }
            cancelDisarmTimeout()
            // Vuelta a listening tras cancelar: el segmenter nuevo arranca sin
            // el pre-roll que tenía el anterior, así que hay una ventana de
            // ~0.3s donde el primer audio entrante puede perderse antes de
            // que el buffer circular interno se rellene de nuevo.
            segmenter = makeSegmenter(config: listeningConfig)
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
        // `segmenter.effectiveThreshold` (ver `SpeechSegmenter`, adaptativo
        // desde este `WakeListener` — ver `init`): con umbral fijo esto
        // habría sido siempre el mismo número que `speechRMSThreshold`, sin
        // valor diagnóstico. Con el umbral adaptativo, ver cuánto se movió
        // respecto al pico de RMS es exactamente lo que permite confirmar en
        // campo que el aprendizaje del piso de ruido está funcionando.
        KikiLog.log("kiki wake: pico RMS últimos 10s: \(String(format: "%.4f", calibrationPeakRMS)) (umbral efectivo \(String(format: "%.4f", segmenter.effectiveThreshold)))")
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
            // notifyCapture (sin fence de descarte) — decisión de diseño:
            // una captura lleva habla real del usuario y debe entregarse
            // SIEMPRE, aunque un stop() concurrente corra antes de que la
            // Task llegue al MainActor. En vez del fence (que descartaría la
            // entrega completa), viaja un token de frescura de sesión que el
            // delegate usa para decidir los efectos de ESTADO (rearmar el
            // mic) sin perder el dictado — ver doc de `notifyCapture`.
            notifyCapture { $0.wakeListenerDidCapture(samples: samples, sessionIsCurrent: $1) }
            scheduleDisarmTimeout()
        case .stopped:
            break
        }
    }

    private func handleListeningSegment(_ samples: [Float]) {
        guard !isTranscribing else {
            // Ya no se descarta (bug de campo: la frase de activación podía
            // llegar completa justo durante el check en vuelo de un
            // segmento anterior y perderse sin más). Se guarda como
            // `pendingSegment` — cola de tamaño máximo 1, el más reciente
            // gana — y se chequea en cuanto termine el check en vuelo (ver
            // el bloque `queue.async` de la Task de abajo).
            let seconds = Double(samples.count) / Self.sampleRate
            if pendingSegment != nil {
                KikiLog.log("kiki wake: segmento pendiente reemplazado")
            } else {
                KikiLog.log("kiki wake: segmento encolado (transcripción en curso, \(String(format: "%.1f", seconds))s)")
            }
            pendingSegment = samples
            return
        }
        isTranscribing = true
        let transcriber = self.transcriber
        let segmentSeconds = Double(samples.count) / Self.sampleRate
        // Fence de sesión: si hay un stop()+start() mientras esta tarea está
        // en vuelo, `session` cambia y el resultado se descarta al volver,
        // aunque `state` haya vuelto a `.listening` por el nuevo start().
        let capturedSession = session
        transcriptionTask = Task {
            let text: String?
            // `Date()` es diagnóstico puro aquí (desglose de latencia en el
            // log), no gobierna ninguna lógica testeable — está bien no
            // medirlo por conteo de muestras como el resto de la clase.
            let transcribeStarted = Date()
            do {
                text = try await transcriber.transcribe(samples)
            } catch {
                KikiLog.log("kiki wake: transcripción falló (\(error))")
                text = nil
            }
            let transcribeSeconds = Date().timeIntervalSince(transcribeStarted)
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
                // Desglose por etapa de cada wake-check: nunca incluye el
                // contenido del transcript (regla de privacidad — ver
                // `applyMatch`), solo duraciones y si matcheó o no.
                let matched = text.flatMap(WakePhraseMatcher.match) != nil
                KikiLog.log("kiki wake: check — segmento \(String(format: "%.1f", segmentSeconds))s, transcripción \(String(format: "%.1f", transcribeSeconds))s, match \(matched ? "sí" : "no")")
                if self._state == .listening, let text {
                    self.applyMatch(text, sampleCount: samples.count)
                }
                // Un segmento pudo haber quedado pendiente (ver
                // `handleListeningSegment`) mientras este check estaba en
                // vuelo. `applyMatch` puede haber armado (`arm()`), que ya
                // limpia `pendingSegment` por no aplicar al régimen armado —
                // así que llegar aquí con uno todavía presente implica que
                // seguimos en `.listening` y corresponde chequearlo a
                // continuación, mismo flujo que un segmento recién llegado
                // (mismo log de desglose de arriba en su propia iteración).
                if let pending = self.pendingSegment {
                    self.pendingSegment = nil
                    self.handleListeningSegment(pending)
                }
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
            // notifyCapture — mismo razonamiento que en handleSegmentEnded:
            // el remainder es dictado real dicho en el mismo aliento que la
            // frase, no una notificación de estado. Debe entregarse aunque
            // haya un stop() concurrente; el token de frescura le permite al
            // delegate no rearmar el mic si la sesión ya no es la vigente.
            notifyCapture { $0.wakeListenerDidCaptureSameBreath(text: match.remainder, sessionIsCurrent: $1) }
        }
    }

    private func arm() {
        dispatchPrecondition(condition: .onQueue(queue))
        _state = .armed
        // Frase nueva → arme inicial de la sesión: régimen de timeout corto
        // (8s) hasta la primera captura entregada.
        hasCapturedInSession = false
        // Cualquier segmento de `.listening` que siguiera pendiente de
        // chequeo ya no aplica: el régimen armado usa `armedConfig`/otro
        // segmenter y ese audio no es dictado dirigido a kiki.
        pendingSegment = nil
        // makeSegmenter (no SpeechSegmenter directo): el piso de ruido que
        // el segmenter de `.listening` acaba de aprender es EXACTAMENTE el
        // que el segmenter armado necesita — es el mismo cuarto un instante
        // después. Sin el carry-over, un cuarto ruidoso re-bloquearía el
        // segmenter armado (maxSegmentDuration 30s) y los primeros ~30s del
        // dictado real se descartarían como "máximo" mientras re-converge.
        segmenter = makeSegmenter(config: armedConfig)
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
        segmenter = makeSegmenter(config: listeningConfig)
        _state = .listening
        suppressUntilSampleCount = nil
        hasCapturedInSession = false
        KikiLog.log("kiki wake: timeout sin dictado, vuelvo a listening")
        notify { $0.wakeListenerDidDisarm() }
    }

    // MARK: - Delegate hop

    /// Notificaciones de ESTADO (`didArm`/`didStartCapture`/`didDisarm`),
    /// SIEMPRE fenced por `notificationEpoch`: una entrega stale tras un
    /// `stop()` concurrente produciría un efecto visible incorrecto, así que
    /// se descarta completa. Las notificaciones de CAPTURA no usan este
    /// método — van por `notifyCapture`, que nunca descarta (cargan habla
    /// real del usuario) y en su lugar adjunta un token de frescura.
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

    /// Entrega de CAPTURA al delegate: nunca se descarta (el payload es habla
    /// real del usuario, grabada mientras el listener estaba habilitado), pero
    /// viaja acompañada de un token de frescura `sessionIsCurrent`.
    ///
    /// Por qué no basta con entregar sin fence y ya: una Task de captura
    /// starved en el MainActor puede correr DESPUÉS de que un ciclo completo
    /// de hotkey ajeno terminara (controller de vuelta en `.idle`,
    /// `wakeEnabled` aún `true`) — en ese instante ningún guard de estado en
    /// `AppDelegate` la distingue de una captura fresca, y fijaría
    /// `resumeAsArmed = true` → rearme del mic sin frase ni chime (regresión
    /// de privacidad). El token cierra ese agujero: `capturedSession` se
    /// toma sobre `queue` en el momento del despacho, y la Task en MainActor
    /// vuelve a leer `session` (`queue.sync`, deadlock-free por la misma
    /// invariante del accessor `state`) justo antes de invocar al delegate.
    /// `session` avanza en cada `stop()`/`start()`/`resumeArmed()`, así que
    /// cualquier interrupción del listener entre despacho y entrega marca la
    /// captura como stale. El delegate procesa el habla igual, pero solo
    /// trata la entrega como parte de la sesión vigente (rearme) si
    /// `sessionIsCurrent == true`.
    private func notifyCapture(_ action: @escaping @MainActor (WakeListenerDelegate, _ sessionIsCurrent: Bool) -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let delegate else { return }
        let capturedSession = session
        Task { @MainActor in
            let sessionIsCurrent = self.queue.sync { capturedSession == self.session }
            action(delegate, sessionIsCurrent)
        }
    }
}
