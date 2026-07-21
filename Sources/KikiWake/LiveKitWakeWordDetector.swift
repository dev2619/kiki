import Foundation
import KikiCore
import LiveKitWakeWord

/// Implementación de `WakeWordDetecting` con el motor abierto LiveKit Wakeword
/// (openWakeWord + cabeza conv-attention, ONNX Runtime / CoreML). Detecta las
/// frases entrenadas AL INSTANTE sin transcribir — Whisper queda solo para el
/// dictado.
///
/// Alimentado por `process(_:)` desde el hilo de audio; bufferea una ventana
/// deslizante (~1.5s) y corre la inferencia en su PROPIA cola serial (una sola
/// `predict` a la vez — la sesión ORT no es reentrante), sin bloquear el hilo
/// de audio. `onTrigger` se dispara en esa cola serial.
public final class LiveKitWakeWordDetector: WakeWordDetecting {
    public var onTrigger: ((WakeTrigger) -> Void)?

    private let model: WakeWordModel
    /// nombre-de-modelo (stem del .onnx) → trigger.
    private let triggers: [String: WakeTrigger]
    private let threshold: Float
    private let sampleRate = 16_000

    /// Ventana de audio que ve el clasificador (el modelo espera ~2s de
    /// contexto; usamos 1.6s para reaccionar un poco antes).
    private let windowSamples: Int
    /// Correr `predict` cada ~160ms de audio nuevo (no en cada chunk) — balance
    /// latencia/CPU.
    private let hopSamples: Int
    /// Tras un disparo, ignorar re-disparos este tiempo (evita repetir).
    private let debounce: TimeInterval

    private let queue = DispatchQueue(label: "com.dev2619.kiki.wakeword")
    private var buffer: [Int16] = []
    private var samplesSinceLastPredict = 0
    private var predicting = false
    private var lastFire: [String: Date] = [:]
    private var stopped = false

    /// - Parameters:
    ///   - models: pares (URL del clasificador `.onnx`, trigger que dispara).
    ///     El stem del archivo es la clave que devuelve `predict`.
    ///   - threshold: umbral de confianza (conv-attention ~0.6-0.7; default 0.6).
    ///   - windowSeconds / hopSeconds / debounce: ver arriba.
    public init(
        models: [(url: URL, trigger: WakeTrigger)],
        threshold: Float = 0.6,
        windowSeconds: Double = 1.6,
        hopSeconds: Double = 0.16,
        debounce: TimeInterval = 1.5
    ) throws {
        var map: [String: WakeTrigger] = [:]
        for m in models {
            map[m.url.deletingPathExtension().lastPathComponent] = m.trigger
        }
        self.triggers = map
        self.threshold = threshold
        self.windowSamples = Int(windowSeconds * 16_000)
        self.hopSamples = Int(hopSeconds * 16_000)
        self.debounce = debounce
        self.model = try WakeWordModel(
            models: models.map(\.url),
            sampleRate: 16_000,
            executionProvider: .coreML)
        KikiLog.log("kiki wake: motor abierto listo (\(map.count) frases, umbral \(threshold))")
    }

    public func process(_ samples16kMono: [Float]) {
        queue.async { [weak self] in self?.ingest(samples16kMono) }
    }

    public func stop() {
        queue.async { [weak self] in self?.stopped = true; self?.buffer = [] }
    }

    // MARK: - Cola serial

    private func ingest(_ chunk: [Float]) {
        guard !stopped else { return }
        // Float → Int16 (clamp).
        buffer.reserveCapacity(buffer.count + chunk.count)
        for f in chunk {
            let clamped = max(-1, min(1, f))
            buffer.append(Int16(clamped * 32767))
        }
        // Mantener solo la ventana deslizante.
        if buffer.count > windowSamples {
            buffer.removeFirst(buffer.count - windowSamples)
        }
        samplesSinceLastPredict += chunk.count
        guard !predicting, samplesSinceLastPredict >= hopSamples, buffer.count >= windowSamples else { return }
        samplesSinceLastPredict = 0
        predicting = true
        let window = buffer
        defer { predicting = false }
        do {
            let scores = try model.predict(window)
            handleScores(scores)
        } catch {
            KikiLog.log("kiki wake: predict falló (\(error))")
        }
    }

    private func handleScores(_ scores: [String: Float]) {
        let now = Date()
        var best: (name: String, score: Float)?
        for (name, score) in scores where score >= threshold {
            if best == nil || score > best!.score { best = (name, score) }
        }
        guard let hit = best, let trigger = triggers[hit.name] else { return }
        // Debounce por frase.
        if let last = lastFire[hit.name], now.timeIntervalSince(last) < debounce { return }
        lastFire[hit.name] = now
        KikiLog.log("kiki wake: trigger \(hit.name) (\(String(format: "%.2f", hit.score))) → \(trigger)")
        onTrigger?(trigger)
    }
}
