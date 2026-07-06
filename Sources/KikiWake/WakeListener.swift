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
/// Todo el estado mutable (`state`, `segmenter`, la tarea de transcripción en
/// vuelo, la tarea de timeout de desarmado) está confinado a `queue`, una
/// cola serial que es también la cola en la que se despachan los callbacks
/// del tap de audio. `SpeechSegmenter` no es thread-safe, así que mantenerlo
/// en una única cola serial evita cualquier acceso concurrente sin necesitar
/// locks. Los métodos públicos (`start`/`stop`/`cancelCapture`) despachan de
/// forma síncrona sobre `queue` para que el caller observe el efecto (o el
/// throw de `start()`) antes de retornar. Los eventos hacia el delegate —que
/// es `@MainActor`— saltan siempre con `Task { @MainActor in ... }`.
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

    public private(set) var state: State = .stopped
    public weak var delegate: WakeListenerDelegate?

    private let transcriber: Transcribing
    private let engine = AVAudioEngine()
    /// Cola serial: confina segmenter + estado, y es la cola destino del tap de audio.
    private let queue = DispatchQueue(label: "com.dev2619.kiki.wake-listener")
    private var segmenter = SpeechSegmenter(config: WakeListener.listeningConfig)

    /// Solo una transcripción en vuelo a la vez; segmentos que llegan mientras
    /// hay una pendiente se descartan (ver `handleListeningSegment`).
    private var isTranscribing = false
    private var disarmTask: Task<Void, Never>?

    public init(transcriber: Transcribing) {
        self.transcriber = transcriber
    }

    // MARK: - Public API

    public func start() throws {
        try queue.sync {
            guard state == .stopped else { return }
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
            state = .listening
            KikiLog.log("kiki wake: listening iniciado")
        }
    }

    public func stop() {
        queue.sync {
            guard state != .stopped else { return }
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            disarmTask?.cancel()
            disarmTask = nil
            isTranscribing = false
            segmenter.reset()
            state = .stopped
            KikiLog.log("kiki wake: detenido")
        }
    }

    public func cancelCapture() {
        queue.sync {
            guard state == .armed else { return }
            disarmTask?.cancel()
            disarmTask = nil
            segmenter = SpeechSegmenter(config: Self.listeningConfig)
            state = .listening
            KikiLog.log("kiki wake: captura cancelada, vuelvo a listening")
            notify { $0.wakeListenerDidDisarm() }
        }
    }

    // MARK: - Tap handling (confinado a `queue`)

    private func handle(chunk: [Float], rms: Float) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard state != .stopped else { return }
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
            if state == .armed {
                scheduleDisarmTimeout()
            }
        }
    }

    private func handleSpeechStarted() {
        guard state == .armed else { return }
        disarmTask?.cancel()
        disarmTask = nil
        notify { $0.wakeListenerDidStartCapture() }
    }

    private func handleSegmentEnded(_ samples: [Float]) {
        switch state {
        case .listening:
            handleListeningSegment(samples)
        case .armed:
            disarmTask?.cancel()
            disarmTask = nil
            segmenter = SpeechSegmenter(config: Self.listeningConfig)
            state = .listening
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
        Task {
            let text: String?
            do {
                text = try await transcriber.transcribe(samples)
            } catch {
                KikiLog.log("kiki wake: transcripción falló (\(error))")
                text = nil
            }
            self.queue.async {
                self.isTranscribing = false
                // El estado pudo cambiar (stop) mientras transcribíamos.
                guard self.state == .listening, let text else { return }
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
        state = .armed
        segmenter = SpeechSegmenter(config: Self.armedConfig)
        KikiLog.log("kiki wake: armado")
        notify { $0.wakeListenerDidArm() }
        scheduleDisarmTimeout()
    }

    private func scheduleDisarmTimeout() {
        dispatchPrecondition(condition: .onQueue(queue))
        disarmTask?.cancel()
        disarmTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.disarmTimeoutSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.queue.async { self.fireDisarmTimeout() }
        }
    }

    private func fireDisarmTimeout() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard state == .armed else { return }
        disarmTask = nil
        segmenter = SpeechSegmenter(config: Self.listeningConfig)
        state = .listening
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
