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
/// vuelo, la tarea de timeout de desarmado, `session`, `disarmGeneration`)
/// está confinado a `queue`, una cola serial que es también la cola en la que
/// se despachan los callbacks del tap de audio. `SpeechSegmenter` no es
/// thread-safe, así que mantenerlo en una única cola serial evita cualquier
/// acceso concurrente sin necesitar locks. Los métodos públicos
/// (`start`/`stop`/`cancelCapture`) despachan de forma síncrona sobre `queue`
/// para que el caller observe el efecto (o el throw de `start()`) antes de
/// retornar. El accessor público `state` también usa `queue.sync`, por lo que
/// el código interno que ya corre sobre `queue` debe usar `_state` para
/// evitar deadlock por reentrancia. Los eventos hacia el delegate —que es
/// `@MainActor`— saltan siempre con `Task { @MainActor in ... }`.
/// `@unchecked Sendable`: todo el estado mutable está confinado a `queue`
/// (ver disciplina de concurrencia arriba); no hay acceso concurrente real,
/// solo lo que el checker no puede probar automáticamente por sí solo.
public final class WakeListener: @unchecked Sendable {
    public enum State: Equatable {
        case stopped
        case listening
        case armed
    }

    // MARK: - Tunables (nombrados, ver task-4-brief.md)
    private static let listeningConfig = SegmenterConfig(endSilence: 0.7, maxSegmentDuration: 6)
    private static let armedConfig = SegmenterConfig(endSilence: 1.5, maxSegmentDuration: 30)
    private static let disarmTimeoutSeconds: TimeInterval = 8
    private static let tapBufferSize: AVAudioFrameCount = 4_096
    private static let sampleRate: Double = 16_000

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
            session += 1
            segmenter = SpeechSegmenter(config: Self.listeningConfig)
            isTranscribing = false
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
            _state = .listening
            KikiLog.log("kiki wake: listening iniciado")
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
            KikiLog.log("kiki wake: captura cancelada, vuelvo a listening")
            notify { $0.wakeListenerDidDisarm() }
        }
    }

    // MARK: - Tap handling (confinado a `queue`)

    private func handle(chunk: [Float], rms: Float) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard _state != .stopped else { return }
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
            // Vuelta a listening tras una captura completa: mismo trade-off
            // de pre-roll que en cancelCapture() (~0.3s de audio inicial
            // potencialmente perdido mientras el nuevo segmenter se rellena).
            segmenter = SpeechSegmenter(config: Self.listeningConfig)
            _state = .listening
            KikiLog.log("kiki wake: captura completa (\(samples.count) muestras), vuelvo a listening")
            notify { $0.wakeListenerDidCapture(samples: samples) }
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
        segmenter = SpeechSegmenter(config: Self.armedConfig)
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

    private func scheduleDisarmTimeout() {
        dispatchPrecondition(condition: .onQueue(queue))
        disarmTask?.cancel()
        disarmGeneration += 1
        let generation = disarmGeneration
        disarmTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.disarmTimeoutSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.queue.async { self.fireDisarmTimeout(generation: generation) }
        }
    }

    private func fireDisarmTimeout(generation: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        // Guarda de generación: una expiración natural de 8s puede llegar a
        // ejecutarse casi al mismo tiempo que un cancel() (p.ej. disparado por
        // speechStarted); si la generación ya avanzó, este disparo es stale.
        guard generation == disarmGeneration, _state == .armed else { return }
        disarmTask = nil
        segmenter = SpeechSegmenter(config: Self.listeningConfig)
        _state = .listening
        KikiLog.log("kiki wake: timeout sin dictado, vuelvo a listening")
        notify { $0.wakeListenerDidDisarm() }
    }

    // MARK: - Delegate hop

    private func notify(_ action: @escaping @MainActor (WakeListenerDelegate) -> Void) {
        guard let delegate else { return }
        Task { @MainActor in
            action(delegate)
        }
    }
}
