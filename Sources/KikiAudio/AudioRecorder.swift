import AVFoundation
import KikiCore

/// Captura del micrófono por defecto con AVAudioEngine.
/// Acumula muestras ya convertidas a 16 kHz mono Float32.
public final class AudioRecorder: AudioRecording {
    private let engine = AVAudioEngine()
    private let collectQueue = DispatchQueue(label: "com.dev2619.kiki.audio-collect")
    private var collected: [Float] = []

    /// Nivel RMS por chunk, para animar el HUD. Se invoca en un hilo de audio en tiempo real — no bloquear.
    public var onLevel: ((Float) -> Void)?

    /// Muestras 16kHz mono del chunk recién resampleado. Se invoca en un hilo de audio en tiempo real — no bloquear.
    public var onChunk: (([Float]) -> Void)?

    public init() {}

    public func start() throws {
        collectQueue.sync { collected = [] }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let chunk = AudioResampler.resampleTo16kMono(buffer)
            self.collectQueue.async { self.collected.append(contentsOf: chunk) }
            self.onLevel?(AudioResampler.rms(chunk))
            self.onChunk?(chunk)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    public func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        return collectQueue.sync { collected }
    }
}
