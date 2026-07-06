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

    public init(
        recorder: AudioRecording,
        transcriber: Transcribing,
        inserter: TextInserting,
        minimumDuration: TimeInterval = 0.3,
        sampleRate: Double = 16_000,
        refiner: Refining? = nil,
        context: ContextProviding? = nil,
        refineTimeout: TimeInterval = 5
    ) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.inserter = inserter
        self.minimumSamples = Int(minimumDuration * sampleRate)
        self.refiner = refiner
        self.context = context
        self.refineTimeout = refineTimeout
    }

    public func hotkeyPressed() {
        guard state == .idle else { return }
        do {
            try recorder.start()
            transition(to: .recording)
        } catch {
            delegate?.dictationDidFail(.audioUnavailable(String(describing: error)))
        }
    }

    public func hotkeyReleased() async {
        guard state == .recording else { return }
        let samples = recorder.stop()
        guard samples.count >= minimumSamples else {
            transition(to: .idle) // tap accidental
            return
        }
        transition(to: .processing)
        do {
            KikiLog.log("kiki core: transcribiendo \(samples.count) muestras (\(String(format: "%.1f", Double(samples.count) / 16_000))s de audio)")
            let started = Date()
            let text = try await transcriber.transcribe(samples)
            KikiLog.log("kiki core: transcripción lista en \(String(format: "%.2f", Date().timeIntervalSince(started)))s — \(text.count) chars")
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let final = await refineOrFallback(trimmed)
                try inserter.insert(final)
                KikiLog.log("kiki core: texto insertado")
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
        _ = recorder.stop()
        transition(to: .idle)
    }

    private func transition(to newState: DictationState) {
        state = newState
        KikiLog.log("kiki estado: \(newState)")
        delegate?.dictationStateDidChange(newState)
    }

    private func refineOrFallback(_ text: String) async -> String {
        guard let refiner else { return text }
        let profile = context?.currentProfile() ?? .neutral
        do {
            let started = Date()
            let refined = try await withThrowingTimeout(seconds: refineTimeout) {
                try await refiner.refine(text, profile: profile)
            }
            let trimmedRefined = refined.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedRefined.isEmpty else {
                KikiLog.log("kiki core: refinado vacío — uso texto crudo")
                return text
            }
            // Guardia de robustez: un LLM que devuelve muchísimo más texto
            // del que se le pidió reescribir es señal de un prompt injection
            // (el texto dictado contenía instrucciones que el modelo obedeció
            // en vez de solo limpiar) o de una generación descarrilada. En
            // cualquier caso, insertar eso sería peor que insertar el texto
            // crudo de Whisper.
            guard trimmedRefined.count <= text.count * 2 + 40 else {
                KikiLog.log("kiki core: refinado sospechosamente largo — uso texto crudo")
                return text
            }
            KikiLog.log("kiki core: refinado (\(profile.rawValue)) en \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
            return trimmedRefined
        } catch {
            KikiLog.log("kiki core: refinado falló (\(error)) — uso texto crudo")
            return text
        }
    }
}
